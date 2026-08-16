"""A deliberately conservative, credential-free analysis fallback.

The real product path is Gemini structured output. This parser exists only so a
missing or temporarily unavailable provider never turns a user's input into a
fictional demo appointment. It extracts values it can establish from the text
and explicitly asks for every important value it cannot.
"""

from datetime import date, time, timedelta
import re

from .models import (
    AnalyzeRequest,
    AnalyzeResponse,
    ChecklistSuggestion,
    Confidence,
    Intent,
    LoopStatus,
    Place,
    Reminder,
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
    for keyword in ("회의", "미팅", "약속", "예약"):
        if keyword in text:
            return keyword
    return "새 일정"


def _extract_checklist(text: str) -> list[ChecklistSuggestion]:
    match = re.search(r"(?:제출물|준비물|체크리스트)\s*[:：]\s*([^\n]+)", text)
    if not match:
        return []
    values = [value.strip(" .") for value in re.split(r"[,/·]|\s+및\s+", match.group(1))]
    return [ChecklistSuggestion(title=value, required=True) for value in values if value][:10]


def _suggested_question(missing_fields: list[str]) -> str | None:
    if not missing_fields:
        return None
    questions = {
        "date": "언제로 등록할까요?",
        "start_time": "몇 시로 등록할까요?",
        "place": "어디에서 진행할까요?",
    }
    return questions[missing_fields[0]]


def analyze_demo(request: AnalyzeRequest) -> AnalyzeResponse:
    """Extract only explicit values when no remote model credential is configured."""
    text = request.text
    intent = Intent.DEADLINE if any(term in text for term in _DEADLINE_TERMS) else Intent.APPOINTMENT
    event_date = _extract_date(text)
    event_time = _extract_time(text)
    place_name = _extract_place(text)

    missing_fields = [
        field
        for field, value in (("date", event_date), ("start_time", event_time))
        if value is None
    ]
    if intent == Intent.APPOINTMENT and place_name is None:
        missing_fields.append("place")

    reminders = []
    if intent == Intent.DEADLINE and event_date:
        reminders = [
            Reminder(type="checkpoint", offset="-7d"),
            Reminder(type="checkpoint", offset="-3d"),
            Reminder(type="checkpoint", offset="-1d"),
        ]
    elif intent == Intent.APPOINTMENT and event_time:
        reminders = [Reminder(offset="-1h")]

    event = StructuredEvent(
        type=intent,
        title=_event_title(text, intent),
        date=event_date,
        start_time=event_time,
        place=Place(name=place_name) if place_name else None,
        participants=_extract_participants(text),
        reminders=reminders,
        checklist=_extract_checklist(text) if intent == Intent.DEADLINE else [],
        source=request.source,
        confidence=Confidence(
            date=0.96 if event_date else 0.0,
            time=0.97 if event_time else 0.0,
            location=0.9 if place_name else 0.0,
            title=0.7,
        ),
        missing_fields=missing_fields,
        resolution_note=(
            "API 연결 전에는 텍스트에 명시된 값만 추출합니다. 저장 전에 빈 항목을 확인하세요."
        ),
    )
    status = LoopStatus.NEEDS_INPUT if missing_fields else LoopStatus.OPEN
    return AnalyzeResponse(status=status, event=event, suggested_question=_suggested_question(missing_fields))
