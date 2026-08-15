from datetime import date, time

from .models import AnalyzeRequest, AnalyzeResponse, Confidence, Intent, LoopStatus, Place, Reminder, StructuredEvent


def analyze_demo(request: AnalyzeRequest) -> AnalyzeResponse:
    """Deterministic placeholder preserving the real AI boundary for the MVP."""
    text = request.text

    if any(word in text for word in ("공모전", "접수", "제출")):
        event = StructuredEvent(
            type=Intent.DEADLINE, title="AI 공모전 제출", date=date(2026, 8, 22), start_time=time(23, 59),
            place=Place(name="온라인 제출"), purpose="공모전 접수 마감",
            reminders=[Reminder(type="checkpoint", offset="-7d"), Reminder(type="checkpoint", offset="-3d"), Reminder(type="checkpoint", offset="-1d")],
            source=request.source, confidence=Confidence(date=0.99, time=0.99, location=0.82, title=0.94),
            resolution_note="마감 일시와 필수 제출물을 함께 추출했습니다.",
        )
        return AnalyzeResponse(status=LoopStatus.OPEN, event=event)

    if "7시" in text and any(word in text for word in ("예약", "ㄱㄱ", "좋아")):
        event = StructuredEvent(
            type=Intent.APPOINTMENT, title="난포 저녁 약속", date=date(2026, 8, 15), start_time=time(19, 0),
            place=Place(name="난포 성수"), participants=["친구"], purpose="저녁 약속", reminders=[Reminder(offset="-1h")],
            source=request.source, confidence=Confidence(date=0.98, time=0.99, location=0.96, title=0.91),
            resolution_note="18:00 제안은 충돌 후 폐기되고 19:00 예약이 최종 합의입니다.",
        )
        return AnalyzeResponse(status=LoopStatus.OPEN, event=event)

    event = StructuredEvent(
        type=Intent.APPOINTMENT, title="성수 저녁 약속", date=date(2026, 8, 15), place=Place(name="성수"), purpose="저녁 약속",
        source=request.source, confidence=Confidence(date=0.91, time=0.42, location=0.97, title=0.86),
        missing_fields=["start_time"], resolution_note="날짜와 장소는 확인됐지만 정확한 시간이 없습니다.",
    )
    return AnalyzeResponse(status=LoopStatus.NEEDS_INPUT, event=event, suggested_question="몇 시로 등록할까요?")
