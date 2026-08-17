"""A deliberately conservative, credential-free analysis fallback.

The real product path is Gemini structured output. This parser exists only so a
missing or temporarily unavailable provider never turns a user's input into a
fictional demo appointment. It extracts values it can establish from the text
and explicitly asks for every important value it cannot.
"""

from datetime import date, datetime, time, timedelta
import re
from zoneinfo import ZoneInfo

from .models import (
    AnalyzeRequest,
    AnalyzeResponse,
    ChecklistSuggestion,
    Confidence,
    Intent,
    LoopStatus,
    Place,
    StructuredEvent,
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
_DEADLINE_TERMS = ("마감", "제출", "접수", "신청 기한", "데드라인")
_COUPON_TERMS = ("쿠폰", "할인", "혜택", "바우처", "기프티콘", "프로모션")
_PURCHASE_TERMS = ("구매", "주문", "결제", "배송", "반품", "영수증", "쇼핑", "주문번호", "송장")
_RESERVATION_TERMS = ("예약", "체크인", "항공권", "호텔", "숙소", "티켓", "탑승", "진료", "예매")
_APPOINTMENT_TERMS = ("회의", "미팅", "약속", "만나", "만남", "방문")
_KST = ZoneInfo("Asia/Seoul")


def _extract_date(text: str, today: date | None = None) -> date | None:
    today = today or date.today()
    for pattern in (
        r"\b(20\d{2})[-./](\d{1,2})[-./](\d{1,2})\b",
        r"\b(20\d{2})년\s*(\d{1,2})월\s*(\d{1,2})일",
    ):
        match = re.search(pattern, text)
        if match:
            try:
                return date(*(int(value) for value in match.groups()))
            except ValueError:
                return None

    match = re.search(r"\b(\d{1,2})월\s*(\d{1,2})일", text)
    if match:
        try:
            return date(today.year, int(match.group(1)), int(match.group(2)))
        except ValueError:
            return None

    if "모레" in text:
        return today + timedelta(days=2)
    if "내일" in text:
        return today + timedelta(days=1)
    if "오늘" in text:
        return today

    if "담주" in text or re.search(r"다음\s*주", text):
        for weekday_name, weekday in _WEEKDAYS.items():
            if weekday_name in text:
                days_until_next_sunday = 7 - ((today.weekday() + 1) % 7)
                next_sunday = today + timedelta(days=days_until_next_sunday)
                return next_sunday + timedelta(days=weekday + 1)

    for weekday_name, weekday in _WEEKDAYS.items():
        if weekday_name in text:
            delta = (weekday - today.weekday()) % 7
            return today + timedelta(days=delta or 7)
    return None


def _extract_time(text: str) -> time | None:
    candidates: list[tuple[int, time]] = []
    for match in re.finditer(r"(?<!\d)([01]?\d|2[0-3]):([0-5]\d)(?!\d)", text):
        candidates.append((match.start(), time(int(match.group(1)), int(match.group(2)))))
    for match in re.finditer(
        r"(?:(오전|오후)\s*)?(1[0-2]|0?\d)\s*시(?:\s*([0-5]?\d)\s*분?)?",
        text,
    ):
        meridiem, hour_text, minute_text = match.groups()
        hour = int(hour_text)
        minute = int(minute_text or 0)
        if meridiem == "오후" and hour < 12:
            hour += 12
        elif meridiem == "오전" and hour == 12:
            hour = 0
        candidates.append((match.start(), time(hour, minute)))
    return max(candidates, key=lambda candidate: candidate[0])[1] if candidates else None


def _extract_place(text: str) -> str | None:
    for marker in ("에서", "으로"):
        if marker not in text:
            continue
        prefix = text.split(marker, 1)[0].strip()
        if not prefix:
            continue
        candidate = prefix.rsplit("에", 1)[-1].strip() if "에" in prefix else prefix.split()[-1]
        candidate = candidate.strip(" ,.!?…")
        if re.fullmatch(r"[가-힣A-Za-z0-9][가-힣A-Za-z0-9 .'-]{0,39}", candidate):
            return candidate
    match = re.search(
        r"([가-힣A-Za-z0-9][가-힣A-Za-z0-9 .'’-]{1,39})\s*(?:맛집|카페|식당|레스토랑|매장|호텔|전시)",
        text,
    )
    if match:
        return match.group(1).strip()
    return None


def _extract_participants(text: str) -> list[str]:
    names = re.findall(r"(?:^|[\s,])([가-힣A-Za-z][가-힣A-Za-z0-9]{1,15})\s*(?:와|하고|랑)", text)
    return list(dict.fromkeys(names))


def _event_title(text: str, intent: Intent) -> str:
    if intent == Intent.DEADLINE:
        if "공모전" in text:
            return "공모전 마감"
        if "접수" in text:
            return "접수 마감"
        return "마감 일정"
    if intent == Intent.COUPON:
        return _reference_title(text, fallback="쿠폰")
    if intent == Intent.PURCHASE:
        return _reference_title(text, fallback="구매 내역")
    if intent == Intent.RESERVATION:
        return _reference_title(text, fallback="예약")
    if intent == Intent.PLACE:
        return _reference_title(text, fallback="저장한 장소")
    for keyword in ("회의", "미팅", "약속"):
        if keyword in text:
            return keyword
    return "새 일정"


def _reference_title(text: str, *, fallback: str) -> str:
    """Keep a compact saved-reference title without retaining request wording."""

    compact = re.sub(r"\s+", " ", text).strip()
    compact = re.sub(
        r"\s*(?:저장(?:해줘|할게|해)?|추천(?:해줘)?|기억(?:해줘)?|보관(?:해줘)?)\s*[.!?…]*$",
        "",
        compact,
    )
    return compact[:80].strip(" .,!?") or fallback


def _classify_intent(text: str) -> Intent:
    if any(term in text for term in _DEADLINE_TERMS):
        return Intent.DEADLINE
    if any(term in text for term in _COUPON_TERMS):
        return Intent.COUPON
    if any(term in text for term in _PURCHASE_TERMS):
        return Intent.PURCHASE
    if any(term in text for term in _RESERVATION_TERMS):
        return Intent.RESERVATION
    if any(term in text for term in _APPOINTMENT_TERMS):
        return Intent.APPOINTMENT
    if _extract_time(text) is not None and re.search(
        r"오늘|내일|모레|담주|다음\s*주|(?:20\d{2}[-./년]\s*)?\d{1,2}월?\s*\d{1,2}일?|월요일|화요일|수요일|목요일|금요일|토요일|일요일",
        text,
    ):
        return Intent.APPOINTMENT
    # The no-provider path prefers a quiet saved reference over fabricating an
    # appointment from ordinary chat text. Gemini remains the production
    # semantic classifier for ambiguous screenshots.
    return Intent.PLACE


def _extract_checklist(text: str) -> list[ChecklistSuggestion]:
    match = re.search(r"(?:제출물|준비물|체크리스트)\s*[:：]\s*([^\n]+)", text)
    if not match:
        return []
    values = [value.strip(" .") for value in re.split(r"[,/·]|\s+및\s+", match.group(1))]
    return [ChecklistSuggestion(title=value, required=True) for value in values if value][:10]


def _summary(
    title: str,
    intent: Intent,
    event_date: date | None,
    event_time: time | None,
    expires_on: date | None,
    place_name: str | None,
    missing_fields: list[str],
) -> str:
    """Produce a small, factual local summary when no AI provider is configured.

    This fallback intentionally mirrors the remote contract without filling in a
    value that was not in the shared text.  It is useful in review UI and makes
    the privacy-safe degraded path legible instead of looking like a blank AI
    result.
    """

    kind = {
        Intent.APPOINTMENT: "일정",
        Intent.DEADLINE: "마감",
        Intent.PLACE: "장소 저장",
        Intent.COUPON: "쿠폰",
        Intent.PURCHASE: "구매",
        Intent.RESERVATION: "예약",
    }[intent]
    facts = [title, kind]
    if event_date:
        facts.append(event_date.isoformat())
    if event_time:
        facts.append(event_time.strftime("%H:%M"))
    if expires_on:
        facts.append(f"기한 {expires_on.isoformat()}")
    if place_name:
        facts.append(place_name)
    text = " · ".join(facts)
    if missing_fields:
        labels = {
            "date": "날짜",
            "start_time": "시간",
            "expires_on": "쿠폰 기한",
            "place": "장소",
        }
        unresolved = ", ".join(labels.get(field, field) for field in missing_fields)
        return f"{text}. {unresolved} 확인이 필요합니다."
    return f"{text}로 정리했습니다."


def _suggested_question(missing_fields: list[str]) -> str | None:
    if not missing_fields:
        return None
    questions = {
        "date": "언제로 등록할까요?",
        "start_time": "몇 시로 등록할까요?",
        "expires_on": "쿠폰 기한을 언제로 정리할까요?",
        "place": "어디에서 진행할까요?",
    }
    return questions[missing_fields[0]]


def analyze_demo(request: AnalyzeRequest, reference_date: date | None = None) -> AnalyzeResponse:
    """Extract only explicit values when no remote model credential is configured."""
    text = request.text
    intent = _classify_intent(text)
    extracted_date = _extract_date(text, reference_date or datetime.now(_KST).date())
    event_date = extracted_date if intent not in (Intent.COUPON, Intent.PLACE) else None
    expires_on = extracted_date if intent in (Intent.COUPON, Intent.PURCHASE) else None
    event_time = _extract_time(text) if intent in (Intent.APPOINTMENT, Intent.DEADLINE, Intent.RESERVATION) else None
    place_name = _extract_place(text)
    title = _event_title(text, intent)
    if intent == Intent.PLACE:
        place_name = place_name or title

    missing_fields: list[str] = []
    if intent == Intent.APPOINTMENT:
        missing_fields = [
            field
            for field, value in (("date", event_date), ("start_time", event_time), ("place", place_name))
            if value is None
        ]
    elif intent == Intent.RESERVATION:
        missing_fields = [
            field
            for field, value in (("date", event_date), ("start_time", event_time))
            if value is None
        ]
    elif intent == Intent.DEADLINE and event_date is None:
        missing_fields.append("date")

    event = StructuredEvent(
        type=intent,
        title=title,
        date=event_date,
        start_time=event_time,
        expires_on=expires_on,
        place=Place(name=place_name) if place_name else None,
        participants=_extract_participants(text),
        reminders=[],
        checklist=_extract_checklist(text) if intent == Intent.DEADLINE else [],
        source=request.source,
        confidence=Confidence(
            date=0.96 if (event_date or expires_on) else 0.0,
            time=0.97 if event_time else 0.0,
            location=0.9 if place_name else 0.0,
            title=0.7,
        ),
        missing_fields=missing_fields,
        summary=_summary(
            title,
            intent,
            event_date,
            event_time,
            expires_on,
            place_name,
            missing_fields,
        ),
        resolution_note=(
            "API 연결 전에는 텍스트에 명시된 값만 추출합니다. 저장 전에 빈 항목을 확인하세요."
        ),
    )
    status = LoopStatus.NEEDS_INPUT if missing_fields else LoopStatus.OPEN
    return AnalyzeResponse(status=status, event=event, suggested_question=_suggested_question(missing_fields))
