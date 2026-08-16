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


def _default_graph(event: StructuredEvent) -> tuple[list[LoopAction], list[ChecklistItem], list[Checkpoint]]:
    actions = [LoopAction(id=_id(), type="calendar", title=f"{event.title} 일정 추가")]
    if event.place:
        actions.append(LoopAction(id=_id(), type="place", title=event.place.name))
    if event.reminders:
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
            offset=reminder.offset,
            title=f"{event.title} {reminder.offset} 확인",
            due_at=_checkpoint_due_at(event, reminder.offset),
        )
        for reminder in event.reminders
        if reminder.type == "checkpoint"
    ]
    return actions, checklist, checkpoints


def _checkpoint_due_at(event: StructuredEvent, offset: str) -> datetime | None:
    if not event.date:
        return None
    match = re.fullmatch(r"(?:T)?([+-])(\d+)([dhm])", offset, re.IGNORECASE)
    if not match:
        return None
    sign, amount_text, unit = match.groups()
    amount = int(amount_text) * (-1 if sign == "-" else 1)
    delta = {
        "d": timedelta(days=amount),
        "h": timedelta(hours=amount),
        "m": timedelta(minutes=amount),
    }[unit.lower()]
    timezone = ZoneInfo(os.getenv("OPENLOOP_TIMEZONE", "Asia/Seoul"))
    event_at = datetime.combine(event.date, event.start_time or time(9), tzinfo=timezone)
    return (event_at + delta).astimezone(UTC)


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
