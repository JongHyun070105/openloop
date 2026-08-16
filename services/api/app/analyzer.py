import json
import logging
import os
import re
from base64 import b64encode
from dataclasses import dataclass
from datetime import date as Date
from datetime import datetime
from pathlib import Path
from typing import Any, Literal, Protocol
from urllib.request import Request, urlopen
from urllib.error import URLError
from zoneinfo import ZoneInfo

from .demo_analyzer import analyze_demo
from .errors import ExternalIntegrationError, ExternalIntegrationTimeout
from .models import AnalyzeRequest, AnalyzeResponse, LoopStatus
from .privacy import redact_pii


_SYSTEM_INSTRUCTION = """You extract only the final agreed appointment or deadline from user-shared input.
Return exactly the provided schema. Do not guess missing values. Put uncertain absent fields in missing_fields,
set status to needs_input, and ask one focused suggested_question. Resolve corrections, rejections, and the
latest final agreement. Confidence values must be between 0 and 1. Never include information not needed for
the event. For deadlines, extract each explicitly named submission as checklist with required true or false,
and preserve requested reminder offsets. For a complete new event, status must be open; never return closed.
Dates must be YYYY-MM-DD and times must be local Korean time in HH:MM:SS without a timezone suffix. When the
user omits a year, use the next matching date in Korean local context unless they explicitly describe a past event.
Write summary in Korean as one or two concise sentences using only extracted facts. If a required field is still
missing, say that it needs confirmation rather than inventing a value. Do not include raw source text or private
identifiers in summary."""

KST = ZoneInfo("Asia/Seoul")
_EXPLICIT_YEAR = re.compile(r"(?:19|20)\d{2}\s*(?:년|[-./])")
_PAST_DATE_MARKERS = ("작년", "지난해", "지난 ", "지난주", "어제", "이전")
logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class ImageInput:
    """An in-memory, validated capture passed to an analysis adapter.

    The API creates this only after enforcing content type and size limits. It is
    deliberately not a persisted model, which keeps shared screenshots out of
    both SQLite and DynamoDB.
    """

    filename: str
    content_type: str
    content: bytes


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


def _today_in_kst() -> Date:
    return datetime.now(KST).date()


def _resolve_yearless_future_date(
    extracted: Date | None, source_text: str | None, today: Date | None = None
) -> Date | None:
    """Correct a model's arbitrary year when the user supplied month/day without a year."""

    if (
        extracted is None
        or not source_text
        or _EXPLICIT_YEAR.search(source_text)
        or any(marker in source_text for marker in _PAST_DATE_MARKERS)
    ):
        return extracted
    today = today or _today_in_kst()
    desired_year = (
        today.year
        if (extracted.month, extracted.day) >= (today.month, today.day)
        else today.year + 1
    )
    try:
        return extracted.replace(year=desired_year)
    except ValueError:
        # Preserve an explicit leap-day value if the inferred target year is not a leap year.
        return extracted


def _normalize_new_loop_result(
    result: AnalyzeResponse,
    source: Literal["screenshot", "image", "text"],
    source_text: str | None,
) -> AnalyzeResponse:
    event = result.event
    local_time = (
        event.start_time.replace(tzinfo=None)
        if event.start_time and event.start_time.tzinfo
        else event.start_time
    )
    normalized_event = event.model_copy(
        update={
            "source": source,
            "date": _resolve_yearless_future_date(event.date, source_text),
            "start_time": local_time,
        }
    )
    return result.model_copy(
        update={
            "event": normalized_event,
            "status": LoopStatus.NEEDS_INPUT if normalized_event.missing_fields else LoopStatus.OPEN,
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
    ) -> AnalyzeResponse: ...

    def analyze_images(
        self,
        images: list[ImageInput],
        companion_text: str | None,
        source: Literal["screenshot", "image"],
    ) -> AnalyzeResponse: ...


class DeterministicAnalysisAdapter:
    """Credential-free adapter used in development, tests, and safe fallback."""

    provider = "deterministic"

    def analyze(self, request: AnalyzeRequest) -> AnalyzeResponse:
        return analyze_demo(request.model_copy(update={"text": redact_pii(request.text)}))

    def analyze_image(
        self,
        filename: str,
        content_type: str,
        content: bytes,
        companion_text: str | None,
        source: Literal["screenshot", "image"],
    ) -> AnalyzeResponse:
        del content_type, content
        # A temporary filename can itself contain personal information. The
        # no-provider path has no pixel OCR, so use only explicit companion text
        # or a neutral label instead of turning a filename into stored content.
        fallback_text = companion_text or "이미지 일정"
        return self.analyze(AnalyzeRequest(text=fallback_text, source=source))

    def analyze_images(
        self,
        images: list[ImageInput],
        companion_text: str | None,
        source: Literal["screenshot", "image"],
    ) -> AnalyzeResponse:
        if not images:
            raise ValueError("At least one image is required")
        # The credential-free path never pretends to OCR pixels. It can only
        # safely use a user-provided companion text or a neutral filename hint.
        first = images[0]
        return self.analyze_image(
            first.filename,
            first.content_type,
            first.content,
            companion_text,
            source,
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
    ) -> AnalyzeResponse:
        safe_filename = f"capture{Path(filename).suffix.lower()}"
        return self._post(
            {
                "filename": safe_filename,
                "content_type": content_type,
                "image_base64": b64encode(content).decode("ascii"),
                "companion_text": redact_pii(companion_text) if companion_text else None,
                "source": source,
            }
        )

    def analyze_images(
        self,
        images: list[ImageInput],
        companion_text: str | None,
        source: Literal["screenshot", "image"],
    ) -> AnalyzeResponse:
        if not images:
            raise ValueError("At least one image is required")
        if len(images) == 1:
            image = images[0]
            return self.analyze_image(
                image.filename,
                image.content_type,
                image.content,
                companion_text,
                source,
            )
        return self._post(
            {
                "images": [
                    {
                        "filename": f"capture-{index + 1}{Path(image.filename).suffix.lower()}",
                        "content_type": image.content_type,
                        "image_base64": b64encode(image.content).decode("ascii"),
                    }
                    for index, image in enumerate(images)
                ],
                "companion_text": redact_pii(companion_text) if companion_text else None,
                "source": source,
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

    def analyze(self, request: AnalyzeRequest) -> AnalyzeResponse:
        safe_text = redact_pii(request.text)
        prompt = f"Source type: {request.source}\nShared text:\n{safe_text}"
        return self._generate(prompt, request.source, safe_text)

    def analyze_image(
        self,
        filename: str,
        content_type: str,
        content: bytes,
        companion_text: str | None,
        source: Literal["screenshot", "image"],
    ) -> AnalyzeResponse:
        return self.analyze_images(
            [ImageInput(filename=filename, content_type=content_type, content=content)],
            companion_text,
            source,
        )

    def analyze_images(
        self,
        images: list[ImageInput],
        companion_text: str | None,
        source: Literal["screenshot", "image"],
    ) -> AnalyzeResponse:
        if not images:
            raise ValueError("At least one image is required")
        prompt = (
            f"Source type: {source}. Extract the actionable event from all user-shared images. "
            "Treat them as one context, resolve the latest final agreement when they conflict, "
            "and do not infer a fact that is absent from every image."
        )
        if companion_text:
            prompt += f"\nCompanion text:\n{redact_pii(companion_text)}"
        image_parts = [
            self.types.Part.from_bytes(data=image.content, mime_type=image.content_type)
            for image in images
        ]
        return self._generate([prompt, *image_parts], source, companion_text)

    def _generate(
        self,
        contents: str | list[object],
        source: Literal["screenshot", "image", "text"],
        source_text: str | None,
    ) -> AnalyzeResponse:
        try:
            response = self.client.models.generate_content(
                model=self.model,
                contents=contents,
                config=self.types.GenerateContentConfig(
                    response_mime_type="application/json",
                    response_schema=_gemini_response_schema(),
                    system_instruction=_SYSTEM_INSTRUCTION,
                    thinking_config=self.types.ThinkingConfig(thinking_level="MINIMAL"),
                ),
            )
            parsed = getattr(response, "parsed", None)
            if isinstance(parsed, AnalyzeResponse):
                result = parsed
            elif parsed is not None:
                result = AnalyzeResponse.model_validate(parsed)
            else:
                result = AnalyzeResponse.model_validate_json(response.text)
            return _normalize_new_loop_result(result, source, source_text)
        except (TimeoutError, ConnectionError) as error:
            raise ExternalIntegrationTimeout("Gemini analysis timed out") from error
        except ExternalIntegrationError:
            raise
        except Exception as error:
            # Preserve enough operational context to diagnose provider setup without
            # recording prompts, image bytes, response bodies, endpoints, or credentials.
            logger.warning(
                "gemini_generation_failed error_type=%s status=%s code=%s",
                type(error).__name__,
                getattr(error, "status", None),
                getattr(error, "code", None),
            )
            raise ExternalIntegrationError("Gemini analysis failed") from error


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
