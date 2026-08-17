import os
import re
from datetime import UTC, datetime, time, timedelta
from uuid import uuid4
from zoneinfo import ZoneInfo

from .models import (
    AmbiguityUpdate,
    Checkpoint,
    ChecklistItem,
    CreateLoopRequest,
    Intent,
    LoopAction,
    LoopStatus,
    OpenLoop,
    Place,
    RetentionPolicy,
    StructuredEvent,
)
from .repository import LoopRepository


def _id() -> str:
    return str(uuid4())


def _checkpoint_templates(event: StructuredEvent) -> list[tuple[str, str]]:
    """Return the product's default event-driven follow-up cadence.

    Deadlines get the review cadence called out in the product spec. Appointments
    get the practical before/during/after checks. A model-supplied checkpoint
    reminder remains authoritative so an explicit user request is never lost.
    """

    explicit = [
        _canonical_checkpoint_offset(event, reminder.offset)
        for reminder in event.reminders
        if reminder.type == "checkpoint"
    ]
    if explicit:
        return [(offset, f"{event.title} {offset} 확인") for offset in explicit]
    if event.type == Intent.DEADLINE:
        return [
            ("D-7", f"{event.title} D-7 준비 확인"),
            ("D-3", f"{event.title} D-3 제출물 점검"),
            ("D-1", f"{event.title} D-1 최종 확인"),
        ]
    return [
        ("T-24h", f"{event.title} 하루 전 확인"),
        ("T-2h", f"{event.title} 출발·준비 확인"),
        ("T-1h", f"{event.title} 한 시간 전 준비 확인"),
        ("T+1d", f"{event.title} 후속 확인"),
    ]


def _canonical_checkpoint_offset(event: StructuredEvent, offset: str) -> str:
    """Use the product labels even when a provider emits equivalent shorthand."""

    normalized = offset.strip()
    if event.type == Intent.DEADLINE:
        return {
            "-7d": "D-7",
            "T-7d": "D-7",
            "-3d": "D-3",
            "T-3d": "D-3",
            "-1d": "D-1",
            "T-1d": "D-1",
        }.get(normalized, normalized)
    return {
        "-24h": "T-24h",
        "-2h": "T-2h",
        "-1h": "T-1h",
        "+1d": "T+1d",
    }.get(normalized, normalized)


def _offset_to_duration(offset: str) -> timedelta | None:
    """Parse supported product labels as well as model-supplied ISO-like offsets."""

    named = {
        "D-7": timedelta(days=-7),
        "D-3": timedelta(days=-3),
        "D-1": timedelta(days=-1),
        "T-24h": timedelta(hours=-24),
        "T-2h": timedelta(hours=-2),
        "T-1h": timedelta(hours=-1),
        "T+1d": timedelta(days=1),
    }
    if offset in named:
        return named[offset]
    match = re.fullmatch(r"(?:T)?([+-])(\d+)([dhm])", offset, re.IGNORECASE)
    if not match:
        return None
    sign, amount_text, unit = match.groups()
    amount = int(amount_text) * (-1 if sign == "-" else 1)
    return {
        "d": timedelta(days=amount),
        "h": timedelta(hours=amount),
        "m": timedelta(minutes=amount),
    }[unit.lower()]


def _default_graph(event: StructuredEvent) -> tuple[list[LoopAction], list[ChecklistItem], list[Checkpoint]]:
    actions = [LoopAction(id=_id(), type="calendar", title=f"{event.title} 일정 추가")]
    if event.place:
        actions.append(LoopAction(id=_id(), type="place", title=event.place.name))
    if event.reminders or event.date or event.start_time:
        actions.append(LoopAction(id=_id(), type="reminder", title="알림 설정"))
    checklist: list[ChecklistItem] = []
    if event.type == Intent.DEADLINE:
        checklist = (
            [
                ChecklistItem(id=_id(), title=suggestion.title, required=suggestion.required)
                for suggestion in event.checklist
            ]
            if event.checklist
            else [
                ChecklistItem(id=_id(), title="제출물 확인"),
                ChecklistItem(id=_id(), title="최종 제출"),
            ]
        )
        actions.append(LoopAction(id=_id(), type="checklist", title="마감 체크리스트"))
    checkpoints = [
        Checkpoint(
            id=_id(),
            offset=offset,
            title=title,
            due_at=_checkpoint_due_at(event, offset),
        )
        for offset, title in _checkpoint_templates(event)
    ]
    return actions, checklist, checkpoints


def _checkpoint_due_at(event: StructuredEvent, offset: str) -> datetime | None:
    if not event.date:
        return None
    delta = _offset_to_duration(offset)
    if delta is None:
        return None
    timezone = ZoneInfo(os.getenv("OPENLOOP_TIMEZONE", "Asia/Seoul"))
    event_at = datetime.combine(event.date, event.start_time or time(9), tzinfo=timezone)
    return (event_at + delta).astimezone(UTC)


def _refresh_graph(loop: OpenLoop) -> None:
    """Fill actions/checkpoints that become actionable after ambiguity resolution.

    An incomplete capture is persisted immediately. Once its missing date, time,
    or place is answered, update default items in place rather than replacing
    IDs, so DynamoDB checkpoint rows and a user's completion state remain stable.
    """

    actions, checklist, checkpoints = _default_graph(loop.event)
    actions_by_type = {item.type: item for item in loop.actions}
    loop.actions = [
        actions_by_type.get(item.type, item)
        for item in actions
    ]
    if loop.event.type == Intent.DEADLINE and not loop.checklist:
        loop.checklist = checklist
    elif loop.event.type != Intent.DEADLINE:
        loop.checklist = []

    existing_by_offset = {item.offset: item for item in loop.checkpoints}
    refreshed: list[Checkpoint] = []
    for generated in checkpoints:
        existing = existing_by_offset.get(generated.offset)
        if existing is None:
            refreshed.append(generated)
            continue
        existing.title = generated.title
        existing.due_at = generated.due_at
        refreshed.append(existing)
    loop.checkpoints = refreshed


def _final_summary(event: StructuredEvent) -> str:
    """Keep the review summary truthful after the user supplies a missing fact."""

    kind = "마감" if event.type == Intent.DEADLINE else "일정"
    facts = [event.title, kind]
    if event.date:
        facts.append(event.date.isoformat())
    if event.start_time:
        facts.append(event.start_time.strftime("%H:%M"))
    if event.place:
        facts.append(event.place.name)
    return f"{' · '.join(facts)}로 정리했습니다."


class LoopService:
    def __init__(self, repository: LoopRepository) -> None:
        self.repository = repository

    def create(self, request: CreateLoopRequest, owner_id: str = "dev-local") -> OpenLoop:
        now = datetime.now(UTC)
        generated_actions, generated_checklist, generated_checkpoints = _default_graph(request.event)
        loop = OpenLoop(
            id=_id(),
            owner_id=owner_id,
            status=request.status or LoopStatus.OPEN,
            event=request.event,
            suggested_question=request.suggested_question,
            actions=request.actions or generated_actions,
            checklist=request.checklist or generated_checklist,
            checkpoints=request.checkpoints or generated_checkpoints,
            retention=request.retention,
            created_at=now,
            updated_at=now,
        )
        return self.repository.save(loop)

    def require(self, loop_id: str) -> OpenLoop:
        loop = self.repository.get(loop_id)
        if not loop:
            raise KeyError(loop_id)
        return loop

    def resolve_ambiguity(self, loop_id: str, update: AmbiguityUpdate) -> OpenLoop:
        loop = self.require(loop_id)
        event_data = loop.event.model_dump(mode="json")
        value = update.value
        if update.field == "place" and isinstance(value, str):
            value = Place(name=value).model_dump(mode="json")
        event_data[update.field] = value
        event_data["missing_fields"] = [field for field in loop.event.missing_fields if field != update.field]
        loop.event = StructuredEvent.model_validate(event_data)
        loop.status = LoopStatus.NEEDS_INPUT if loop.event.missing_fields else LoopStatus.OPEN
        if not loop.event.missing_fields:
            loop.suggested_question = None
            loop.event.summary = _final_summary(loop.event)
        _refresh_graph(loop)
        loop.updated_at = datetime.now(UTC)
        return self.repository.save(loop)

    def complete(self, loop_id: str, retention: RetentionPolicy | None = None) -> OpenLoop:
        loop = self.require(loop_id)
        now = datetime.now(UTC)
        loop.status = LoopStatus.CLOSED
        loop.completed_at = now
        loop.updated_at = now
        loop.retention = retention or loop.retention
        loop.delete_at = retention_deadline(loop.retention, now)
        for checkpoint in loop.checkpoints:
            checkpoint.completed = True
        return self.repository.save(loop)

    def set_retention(self, loop_id: str, retention: RetentionPolicy) -> OpenLoop:
        loop = self.require(loop_id)
        loop.retention = retention
        loop.updated_at = datetime.now(UTC)
        loop.delete_at = retention_deadline(retention, loop.completed_at)
        return self.repository.save(loop)

    def set_item_completion(self, loop_id: str, collection: str, item_id: str, completed: bool) -> OpenLoop:
        loop = self.require(loop_id)
        item = next((candidate for candidate in getattr(loop, collection) if candidate.id == item_id), None)
        if not item:
            raise KeyError(item_id)
        item.completed = completed
        loop.updated_at = datetime.now(UTC)
        return self.repository.save(loop)


def retention_deadline(policy: RetentionPolicy, completed_at: datetime | None) -> datetime | None:
    if completed_at is None or policy == RetentionPolicy.KEEP:
        return None
    if policy == RetentionPolicy.IMMEDIATELY:
        return completed_at
    days = 7 if policy == RetentionPolicy.SEVEN_DAYS else 30
    return completed_at + timedelta(days=days)
