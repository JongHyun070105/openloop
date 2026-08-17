import json
import logging
import os
import re
from base64 import b64encode
from datetime import date as Date
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Literal, Mapping, Protocol
from urllib.request import Request, urlopen
from urllib.error import URLError
from zoneinfo import ZoneInfo

from .demo_analyzer import _extract_time, analyze_demo
from .errors import ExternalIntegrationError, ExternalIntegrationTimeout
from pydantic import ValidationError

from .models import AnalyzeRequest, AnalyzeResponse, Intent, LoopStatus
from .privacy import redact_pii


_SYSTEM_INSTRUCTION = """You classify and extract exactly one useful personal context from user-shared input.
Return exactly the provided schema. Do not guess missing values. Put uncertain absent fields in missing_fields,
set status to needs_input, and ask one focused suggested_question. Resolve corrections, rejections, and the
latest final agreement. Confidence values must be between 0 and 1. Never include information not needed for
the event. When the reason or activity is evident, put that concise action in purpose; do not leave purpose empty
merely because the same meaning is also used in the title. For deadlines, extract each explicitly named submission as checklist with required true or false,
and preserve only explicitly requested reminder offsets. Classify a real meeting, booking, or visit with a required
date/time as appointment. Classify a submission or due date as deadline: its date matters, but absent time is not a
missing field. Classify a restaurant, cafe, store, venue, or place the user wants to keep as place: never request a
date or time for it. Classify a coupon, voucher, discount, or benefit as coupon: use expires_on only when an expiry
date is visible, never put an expiry in date, and never request a time. For place and coupon captures, a confident
title is enough to return open. For a complete new event, status must be open; never return closed.
Dates must be YYYY-MM-DD and times must be local Korean time in HH:MM:SS without a timezone suffix. Resolve Korean
relative dates against the reference instant included in the user prompt: 오늘 is the reference date, 내일 is +1 day,
모레 is +2 days, and 담주/다음 주 means the following Korean calendar week (Sunday through Saturday). When month/day is present but the year is
omitted, use the reference year even if that date has already passed. Only cross into another year when the relative
expression itself crosses the year boundary or the user explicitly supplies another year.
Write summary in Korean as one or two concise sentences using only extracted facts. If a required field is still
missing, say that it needs confirmation rather than inventing a value. Do not include raw source text or private
identifiers in summary."""

KST = ZoneInfo("Asia/Seoul")
_EXPLICIT_YEAR = re.compile(r"(?:19|20)\d{2}\s*(?:년|[-./])")
_RELATIVE_DATE = re.compile(r"오늘|내일|모레")
_NEXT_WEEK = re.compile(r"담주|다음\s*주")
_EXPLICIT_DATE_EVIDENCE = re.compile(
    r"(?:"
    r"(?:19|20)\d{2}\s*(?:년|[-./])\s*\d{1,2}(?:월|[-./])\s*\d{1,2}(?:일)?"
    r"|\d{1,2}\s*월\s*\d{1,2}\s*일"
    r"|오늘|내일|모레|담주|다음\s*주"
    r"|월요일|화요일|수요일|목요일|금요일|토요일|일요일"
    r")"
)
_WEEKDAYS = {
    "월요일": 0,
    "화요일": 1,
    "수요일": 2,
    "목요일": 3,
    "금요일": 4,
    "토요일": 5,
    "일요일": 6,
}
_CONFIDENCE_THRESHOLD = 0.65
_RETRYABLE_GEMINI_STATUS_CODES = frozenset({429, 500, 502, 503, 504})
logger = logging.getLogger(__name__)


def _gemini_response_schema() -> dict[str, Any]:
    """Build a Gemini-compatible schema while keeping local response validation strict.

    Gemini's response-schema endpoint rejects JSON Schema's `additionalProperties`
    keyword. Pydantic emits that keyword for our `extra=forbid` models, so it is
    removed only from the provider-facing copy. The returned model output is still
    validated against `AnalyzeResponse`, including its strict extra-field policy.
    """

    def strip_unsupported_fields(value: Any) -> Any:
        if isinstance(value, dict):
            return {
                key: strip_unsupported_fields(child)
                for key, child in value.items()
                if key not in {"additionalProperties", "additional_properties"}
            }
        if isinstance(value, list):
            return [strip_unsupported_fields(child) for child in value]
        return value

    return strip_unsupported_fields(AnalyzeResponse.model_json_schema())


def _now_in_kst() -> datetime:
    return datetime.now(KST)


def _is_retryable_gemini_error(error: Exception) -> bool:
    """Return whether one immediate replay can safely recover a provider failure."""

    return getattr(error, "code", None) in _RETRYABLE_GEMINI_STATUS_CODES


def _resolve_contextual_date(
    extracted: Date | None, source_text: str | None, reference_date: Date
) -> Date | None:
    """Apply the product's deterministic KST relative-date and omitted-year rules."""

    if extracted is None or not source_text or _EXPLICIT_YEAR.search(source_text):
        return extracted

    relative_matches = list(_RELATIVE_DATE.finditer(source_text))
    if relative_matches:
        relative = relative_matches[-1].group(0)
        offset = {"오늘": 0, "내일": 1, "모레": 2}[relative]
        return Date.fromordinal(reference_date.toordinal() + offset)

    if _NEXT_WEEK.search(source_text):
        weekday_matches = [
            (source_text.rfind(name), weekday) for name, weekday in _WEEKDAYS.items()
        ]
        _, weekday = max(weekday_matches, default=(-1, -1))
        if weekday >= 0:
            # Korean consumer calendars conventionally start on Sunday. On a
            # Sunday, "다음 주 화요일" therefore means the Tuesday after the
            # upcoming Sunday, not two days later in the same Sunday-starting
            # week.
            days_until_next_sunday = 7 - ((reference_date.weekday() + 1) % 7)
            next_sunday = reference_date.toordinal() + days_until_next_sunday
            return Date.fromordinal(next_sunday + weekday + 1)

    try:
        return extracted.replace(year=reference_date.year)
    except ValueError:
        # Preserve a provider's leap-day value when the reference year cannot represent it.
        return extracted


def _focused_question(missing_fields: list[str]) -> str | None:
    questions = {
        "title": "일정 제목을 어떻게 정리할까요?",
        "date": "언제로 등록할까요?",
        "start_time": "몇 시로 등록할까요?",
        "expires_on": "쿠폰 기한을 언제로 정리할까요?",
        "place": "어디에서 진행할까요?",
    }
    return questions.get(missing_fields[0]) if missing_fields else None


def _confidence_aware_missing_fields(event: Any) -> list[str]:
    """Gate required product fields without inventing facts from model confidence."""

    required = [("title", bool(event.title.strip()), event.confidence.title)]
    if event.type == Intent.APPOINTMENT:
        required.extend(
            [
                ("date", event.date is not None, event.confidence.date),
                ("start_time", event.start_time is not None, event.confidence.time),
                ("place", event.place is not None, event.confidence.location),
            ]
        )
    elif event.type == Intent.DEADLINE:
        required.append(("date", event.date is not None, event.confidence.date))

    required_fields = {field for field, _, _ in required}
    inferred = [field for field in event.missing_fields if field in required_fields]
    for field, present, confidence in required:
        if (not present or confidence < _CONFIDENCE_THRESHOLD) and field not in inferred:
            inferred.append(field)
    return inferred


def _reconcile_explicit_text_facts(
    event: Any,
    source_text: str | None,
    source: Literal["screenshot", "image", "text"],
    reference_date: Date,
) -> Any:
    """Prefer unambiguous literal date/time facts over a model's stale proposal.

    The model resolves the broad event semantics. For text only, a small local
    parser is more reliable for a later, explicit correction such as
    ``오후 6시에서 오후 7시 30분으로 변경`` and also prevents it from inventing
    today's date when the shared text never names a date. Images deliberately
    do not enter this path because their pixels are not available locally.
    """

    if source != "text" or not source_text:
        return event
    literal = analyze_demo(
        AnalyzeRequest(text=source_text, source=source), reference_date=reference_date
    ).event
    updates: dict[str, Any] = {}
    confidence = event.confidence.model_dump()
    missing_fields = list(event.missing_fields)

    if event.type == Intent.COUPON:
        updates["date"] = None
        updates["start_time"] = None
        if _EXPLICIT_DATE_EVIDENCE.search(source_text) and literal.expires_on is not None:
            updates["expires_on"] = literal.expires_on
            confidence["date"] = max(float(confidence["date"]), 0.98)
            missing_fields = [field for field in missing_fields if field != "expires_on"]
    elif event.type == Intent.PLACE:
        updates.update({"date": None, "start_time": None, "expires_on": None})
    elif _EXPLICIT_DATE_EVIDENCE.search(source_text):
        if literal.date is not None:
            updates["date"] = literal.date
            if event.date is None or "date" in event.missing_fields:
                confidence["date"] = max(float(confidence["date"]), 0.98)
            missing_fields = [field for field in missing_fields if field != "date"]
    else:
        # Without a literal date signal, a text-only model result is not enough
        # evidence to create a date. The confidence gate will ask one focused
        # question instead of silently using the reference day.
        updates["date"] = None
        confidence["date"] = 0.0

    literal_time = _extract_time(source_text)
    if event.type not in (Intent.COUPON, Intent.PLACE) and literal_time is not None:
        updates["start_time"] = literal_time
        if event.start_time is None or "start_time" in event.missing_fields:
            confidence["time"] = max(float(confidence["time"]), 0.98)
        missing_fields = [field for field in missing_fields if field != "start_time"]

    updates["confidence"] = event.confidence.model_copy(update=confidence)
    updates["missing_fields"] = missing_fields
    return event.model_copy(update=updates)


def _normalize_provider_payload(payload: object, source: str) -> dict[str, Any]:
    """Repair only provider-state/default omissions before strict Pydantic validation."""

    if isinstance(payload, AnalyzeResponse):
        data = payload.model_dump(mode="json")
    elif isinstance(payload, Mapping):
        data = dict(payload)
    else:
        raise TypeError("provider payload must be an object")
    event_value = data.get("event")
    if not isinstance(event_value, Mapping):
        return data

    event = dict(event_value)
    for field in ("participants", "reminders", "checklist", "missing_fields"):
        if event.get(field) is None:
            event[field] = []
    for field in ("purpose", "summary", "resolution_note", "expires_on"):
        event.setdefault(field, None)
    event["source"] = source
    data["event"] = event
    data.setdefault("suggested_question", None)
    # Status is derived after domain validation. This neutral value avoids a
    # provider status/missing mismatch bypassing strict validation altogether.
    data["status"] = "needs_input" if event.get("missing_fields") else "open"
    return data


def _validation_diagnostics(error: ValidationError) -> tuple[list[str], list[str]]:
    fields: list[str] = []
    types: list[str] = []
    for item in error.errors(include_input=False, include_url=False):
        field = ".".join(str(part) for part in item.get("loc", ())) or "root"
        error_type = str(item.get("type", "validation_error"))
        if field not in fields:
            fields.append(field)
        if error_type not in types:
            types.append(error_type)
    return fields[:12], types[:12]


def _normalize_new_loop_result(
    result: AnalyzeResponse,
    source: Literal["screenshot", "image", "text"],
    source_text: str | None,
    reference_date: Date,
) -> AnalyzeResponse:
    event = result.event
    local_time = (
        event.start_time.replace(tzinfo=None)
        if event.start_time and event.start_time.tzinfo
        else event.start_time
    )
    normalized_date = _resolve_contextual_date(event.date, source_text, reference_date)
    normalized_expiry = _resolve_contextual_date(
        event.expires_on, source_text, reference_date
    )
    if event.type == Intent.COUPON:
        normalized_expiry = normalized_expiry or normalized_date
        normalized_date = None
        local_time = None
    elif event.type == Intent.PLACE:
        normalized_date = None
        normalized_expiry = None
        local_time = None
    normalized_event = event.model_copy(
        update={
            "source": source,
            "date": normalized_date,
            "start_time": local_time,
            "expires_on": normalized_expiry,
        }
    )
    normalized_event = _reconcile_explicit_text_facts(
        normalized_event,
        source_text,
        source,
        reference_date,
    )
    missing_fields = _confidence_aware_missing_fields(normalized_event)
    normalized_event = normalized_event.model_copy(update={"missing_fields": missing_fields})
    provider_question = (
        result.suggested_question
        if event.missing_fields
        and missing_fields
        and event.missing_fields[0] == missing_fields[0]
        else None
    )
    return result.model_copy(
        update={
            "event": normalized_event,
            "status": LoopStatus.NEEDS_INPUT if missing_fields else LoopStatus.OPEN,
            "suggested_question": provider_question or _focused_question(missing_fields),
        }
    )


class AnalysisAdapter(Protocol):
    provider: str

    def analyze(self, request: AnalyzeRequest) -> AnalyzeResponse: ...

    def analyze_image(
        self,
        filename: str,
        content_type: str,
        content: bytes,
        companion_text: str | None,
        source: Literal["screenshot", "image"],
        reference_at: datetime | None = None,
    ) -> AnalyzeResponse: ...


class DeterministicAnalysisAdapter:
    """Credential-free adapter used in development, tests, and safe fallback."""

    provider = "deterministic"

    def analyze(self, request: AnalyzeRequest) -> AnalyzeResponse:
        reference_date = (
            request.reference_at.astimezone(KST).date()
            if request.reference_at is not None
            else None
        )
        return analyze_demo(
            request.model_copy(update={"text": redact_pii(request.text)}),
            reference_date=reference_date,
        )

    def analyze_image(
        self,
        filename: str,
        content_type: str,
        content: bytes,
        companion_text: str | None,
        source: Literal["screenshot", "image"],
        reference_at: datetime | None = None,
    ) -> AnalyzeResponse:
        del content_type, content
        # A temporary filename can itself contain personal information. The
        # no-provider path has no pixel OCR, so use only explicit companion text
        # or a neutral label instead of turning a filename into stored content.
        fallback_text = companion_text or "이미지 일정"
        return self.analyze(
            AnalyzeRequest(text=fallback_text, source=source, reference_at=reference_at)
        )


class JsonHttpAnalysisAdapter:
    """Provider-neutral adapter for a future AWS-hosted structured JSON agent."""

    provider = "json_http"

    def __init__(self, endpoint: str, api_key: str, timeout_seconds: float = 20.0) -> None:
        self.endpoint = endpoint
        self.api_key = api_key
        self.timeout_seconds = timeout_seconds

    def analyze(self, request: AnalyzeRequest) -> AnalyzeResponse:
        payload = request.model_dump(mode="json")
        payload["text"] = redact_pii(request.text)
        return self._post(payload)

    def analyze_image(
        self,
        filename: str,
        content_type: str,
        content: bytes,
        companion_text: str | None,
        source: Literal["screenshot", "image"],
        reference_at: datetime | None = None,
    ) -> AnalyzeResponse:
        safe_filename = f"capture{Path(filename).suffix.lower()}"
        return self._post(
            {
                "filename": safe_filename,
                "content_type": content_type,
                "image_base64": b64encode(content).decode("ascii"),
                "companion_text": redact_pii(companion_text) if companion_text else None,
                "source": source,
                "reference_at": reference_at.isoformat() if reference_at else None,
            }
        )

    def _post(self, payload: dict[str, object]) -> AnalyzeResponse:
        http_request = Request(
            self.endpoint,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urlopen(http_request, timeout=self.timeout_seconds) as response:  # noqa: S310
                return AnalyzeResponse.model_validate_json(response.read())
        except TimeoutError as error:
            raise ExternalIntegrationTimeout("Analysis provider timed out") from error
        except (URLError, ValueError) as error:
            raise ExternalIntegrationError("Analysis provider failed") from error


class GeminiAnalysisAdapter:
    """Official Google Gen AI multimodal adapter with Pydantic structured output."""

    provider = "gemini"

    def __init__(
        self,
        api_key: str,
        model: str = "gemini-3.5-flash-lite",
        timeout_seconds: float = 20.0,
        client: object | None = None,
        types_module: object | None = None,
        reference_clock: Callable[[], datetime] | None = None,
    ) -> None:
        if client is None or types_module is None:
            from google import genai
            from google.genai import types

            types_module = types
            client = client or genai.Client(
                api_key=api_key,
                http_options=types.HttpOptions(timeout=int(timeout_seconds * 1000)),
            )
        self.client = client
        self.types = types_module
        self.model = model
        self.reference_clock = reference_clock or _now_in_kst

    def _reference_instant(self, requested: datetime | None = None) -> datetime:
        instant = requested or self.reference_clock()
        if instant.tzinfo is None:
            instant = instant.replace(tzinfo=KST)
        return instant.astimezone(KST)

    @staticmethod
    def _temporal_context(reference: datetime) -> str:
        return (
            "Korean temporal reference (authoritative): "
            f"{reference.isoformat(timespec='seconds')} (Asia/Seoul). "
            "오늘=reference date, 내일=+1 day, 모레=+2 days, 담주/다음 주=following calendar week. "
            "For a month/day without a year, use the reference year even if that date already passed; "
            "cross years only when the relative expression itself crosses the boundary or a year is explicit."
        )

    def analyze(self, request: AnalyzeRequest) -> AnalyzeResponse:
        reference = self._reference_instant(request.reference_at)
        safe_text = redact_pii(request.text)
        prompt = (
            f"{self._temporal_context(reference)}\n"
            f"Source type: {request.source}\nShared text:\n{safe_text}"
        )
        return self._generate(
            prompt,
            request.source,
            safe_text,
            reference.date(),
            thinking_level="MINIMAL",
        )

    def analyze_image(
        self,
        filename: str,
        content_type: str,
        content: bytes,
        companion_text: str | None,
        source: Literal["screenshot", "image"],
        reference_at: datetime | None = None,
    ) -> AnalyzeResponse:
        del filename
        reference = self._reference_instant(reference_at)
        prompt = (
            f"{self._temporal_context(reference)}\n"
            f"Source type: {source}. Extract the actionable event from this one user-shared image. "
            "Resolve corrections and the latest final agreement visible in the image, and do not infer absent facts."
        )
        if companion_text:
            prompt += f"\nCompanion text:\n{redact_pii(companion_text)}"
        image_part = self.types.Part.from_bytes(data=content, mime_type=content_type)
        return self._generate(
            [prompt, image_part],
            source,
            companion_text,
            reference.date(),
            thinking_level="LOW",
        )

    def _generate(
        self,
        contents: str | list[object],
        source: Literal["screenshot", "image", "text"],
        source_text: str | None,
        reference_date: Date,
        thinking_level: Literal["MINIMAL", "LOW"],
    ) -> AnalyzeResponse:
        config = self.types.GenerateContentConfig(
            response_mime_type="application/json",
            response_schema=_gemini_response_schema(),
            system_instruction=_SYSTEM_INSTRUCTION,
            thinking_config=self.types.ThinkingConfig(thinking_level=thinking_level),
        )
        for attempt in range(2):
            try:
                response = self.client.models.generate_content(
                    model=self.model,
                    contents=contents,
                    config=config,
                )
                parsed = getattr(response, "parsed", None)
                raw_payload = parsed if parsed is not None else json.loads(response.text)
                normalized_payload = _normalize_provider_payload(raw_payload, source)
                try:
                    result = AnalyzeResponse.model_validate(normalized_payload)
                except ValidationError as error:
                    fields, error_types = _validation_diagnostics(error)
                    logger.warning(
                        "gemini_payload_validation_failed fields=%s types=%s",
                        fields,
                        error_types,
                    )
                    raise
                return _normalize_new_loop_result(result, source, source_text, reference_date)
            except (TimeoutError, ConnectionError) as error:
                if attempt == 0:
                    logger.warning("gemini_generation_retry attempt=1 error_type=%s", type(error).__name__)
                    continue
                raise ExternalIntegrationTimeout("Gemini analysis timed out") from error
            except ExternalIntegrationError:
                raise
            except Exception as error:
                if attempt == 0 and _is_retryable_gemini_error(error):
                    logger.warning(
                        "gemini_generation_retry attempt=1 error_type=%s status=%s code=%s",
                        type(error).__name__,
                        getattr(error, "status", None),
                        getattr(error, "code", None),
                    )
                    continue
                # Preserve enough operational context to diagnose provider setup without
                # recording prompts, image bytes, response bodies, endpoints, or credentials.
                logger.warning(
                    "gemini_generation_failed error_type=%s status=%s code=%s",
                    type(error).__name__,
                    getattr(error, "status", None),
                    getattr(error, "code", None),
                )
                raise ExternalIntegrationError("Gemini analysis failed") from error

        raise AssertionError("unreachable")


def analysis_adapter_from_env() -> AnalysisAdapter:
    gemini_key = os.getenv("GEMINI_API_KEY")
    if gemini_key:
        return GeminiAnalysisAdapter(
            api_key=gemini_key,
            model=os.getenv("GEMINI_MODEL") or "gemini-3.5-flash-lite",
            timeout_seconds=float(os.getenv("GEMINI_TIMEOUT_SECONDS", "20")),
        )
    endpoint = os.getenv("OPENLOOP_ANALYSIS_URL")
    api_key = os.getenv("OPENLOOP_ANALYSIS_API_KEY")
    if endpoint and api_key:
        return JsonHttpAnalysisAdapter(endpoint=endpoint, api_key=api_key)
    return DeterministicAnalysisAdapter()
