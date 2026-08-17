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


def _explicit_checkpoint_offsets(event: StructuredEvent) -> list[str]:
    return [
        _canonical_checkpoint_offset(event, reminder.offset)
        for reminder in event.reminders
        if reminder.type == "checkpoint"
    ]


def _checkpoint_templates(event: StructuredEvent) -> list[tuple[str, str]]:
    """Return the single useful default alert for this capture kind.

    A model-supplied checkpoint remains authoritative, but the product never
    turns a saved place into a schedule or adds generic post-event chores.
    """

    explicit = _explicit_checkpoint_offsets(event)
    if explicit:
        return [(offset, f"{event.title} {offset} 확인") for offset in explicit]
    if event.type == Intent.DEADLINE:
        return [("D-1", f"{event.title} 전날 확인")]
    if event.type == Intent.COUPON:
        return [("D-1", f"{event.title} 기한 전날 확인")]
    if event.type == Intent.APPOINTMENT:
        return [("T-1h", f"{event.title} 출발·준비 확인")]
    return []


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
        "T-15m": timedelta(minutes=-15),
        "T-5m": timedelta(minutes=-5),
        "T+1d": timedelta(days=1),
        "D-day": timedelta(),
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


def _event_at(event: StructuredEvent) -> datetime | None:
    if not event.date or not event.start_time:
        return None
    timezone = ZoneInfo(os.getenv("OPENLOOP_TIMEZONE", "Asia/Seoul"))
    return datetime.combine(event.date, event.start_time, tzinfo=timezone)


def _checkpoint_anchor(event: StructuredEvent) -> datetime | None:
    """Choose an honest reminder anchor without asking a fake time question.

    Deadline and coupon captures commonly state only a date. Their single
    expiry alert is intentionally scheduled for 10:00 local time on that date,
    while the visible fact remains a date-only deadline/expiry.
    """

    if event.type == Intent.APPOINTMENT:
        return _event_at(event)
    if event.type not in (Intent.DEADLINE, Intent.COUPON):
        return None
    target_date = event.date if event.type == Intent.DEADLINE else event.expires_on
    if target_date is None:
        return None
    timezone = ZoneInfo(os.getenv("OPENLOOP_TIMEZONE", "Asia/Seoul"))
    anchor_time = event.start_time if event.type == Intent.DEADLINE else None
    anchor_time = anchor_time or time(hour=10)
    return datetime.combine(target_date, anchor_time, tzinfo=timezone)


def _checkpoint_candidates(
    event: StructuredEvent, reference_at: datetime
) -> list[tuple[str, str, datetime]]:
    """Build only future, useful checkpoint prompts for this exact event time."""

    anchor = _checkpoint_anchor(event)
    if anchor is None or event.type == Intent.PLACE:
        return []
    now = reference_at.astimezone(UTC)
    candidates = [
        (offset, title, due_at)
        for offset, title in _checkpoint_templates(event)
        if (due_at := _checkpoint_due_at(event, offset)) is not None and due_at > now
    ]
    # A provider-requested offset is intentional; do not replace it with a
    # product default when it has already passed.
    if _explicit_checkpoint_offsets(event):
        return candidates

    has_upcoming_preparation = any(due_at < anchor for _, _, due_at in candidates)
    if not has_upcoming_preparation and anchor > now:
        short_leads = (
            [
                ("T-15m", f"{event.title} 출발 15분 전 확인"),
                ("T-5m", f"{event.title} 출발 직전 확인"),
            ]
            if event.type == Intent.APPOINTMENT
            else [("D-day", f"{event.title} 기한 당일 확인")]
        )
        for offset, title in short_leads:
            due_at = _checkpoint_due_at(event, offset)
            if due_at is not None and due_at > now:
                candidates.append((offset, title, due_at))
                break
    return sorted(candidates, key=lambda item: item[2])


def _default_graph(
    event: StructuredEvent, *, reference_at: datetime | None = None
) -> tuple[list[LoopAction], list[ChecklistItem], list[Checkpoint]]:
    now = reference_at or datetime.now(UTC)
    actions: list[LoopAction] = []
    checklist: list[ChecklistItem] = []
    if event.type == Intent.APPOINTMENT:
        actions.append(LoopAction(id=_id(), type="calendar", title=f"{event.title} 일정 추가"))
        if event.place:
            actions.append(LoopAction(id=_id(), type="place", title=event.place.name))
        if _checkpoint_anchor(event):
            actions.append(LoopAction(id=_id(), type="reminder", title="일정 알림 자동 예약"))
    elif event.type == Intent.DEADLINE:
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
        if _checkpoint_anchor(event):
            actions.append(LoopAction(id=_id(), type="reminder", title="마감 알림 자동 예약"))
    elif event.type == Intent.COUPON:
        actions.append(LoopAction(id=_id(), type="coupon", title="쿠폰 사용하기"))
        if event.place:
            actions.append(LoopAction(id=_id(), type="place", title=event.place.name))
        if _checkpoint_anchor(event):
            actions.append(LoopAction(id=_id(), type="reminder", title="기한 알림 자동 예약"))
    elif event.type == Intent.PLACE and event.place:
        actions.append(LoopAction(id=_id(), type="place", title=f"{event.place.name} 지도 열기"))
    checkpoints = [
        Checkpoint(
            id=_id(),
            offset=offset,
            title=title,
            due_at=due_at,
        )
        for offset, title, due_at in _checkpoint_candidates(event, now)
    ]
    return actions, checklist, checkpoints


def _checkpoint_due_at(event: StructuredEvent, offset: str) -> datetime | None:
    delta = _offset_to_duration(offset)
    anchor = _checkpoint_anchor(event)
    if delta is None or anchor is None:
        return None
    return (anchor + delta).astimezone(UTC)


def _refresh_graph(loop: OpenLoop) -> None:
    """Fill actions/checkpoints that become actionable after ambiguity resolution.

    An incomplete capture is persisted immediately. Once its missing date, time,
    or place is answered, update default items in place rather than replacing
    IDs, so DynamoDB checkpoint rows and a user's completion state remain stable.
    """

    actions, checklist, checkpoints = _default_graph(
        loop.event,
        reference_at=datetime.now(UTC),
    )
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

    kind = {
        Intent.APPOINTMENT: "일정",
        Intent.DEADLINE: "마감",
        Intent.PLACE: "장소 저장",
        Intent.COUPON: "쿠폰",
    }[event.type]
    facts = [event.title, kind]
    if event.date:
        facts.append(event.date.isoformat())
    if event.start_time:
        facts.append(event.start_time.strftime("%H:%M"))
    if event.expires_on:
        facts.append(f"기한 {event.expires_on.isoformat()}")
    if event.place:
        facts.append(event.place.name)
    return f"{' · '.join(facts)}로 정리했습니다."


def _context_place_key(event: StructuredEvent) -> str | None:
    """Return a conservative, stable key for cross-Loop context links."""

    if not event.place or not event.place.name.strip():
        return None
    key = re.sub(r"[^0-9a-z가-힣]+", "", event.place.name.casefold())
    return key or None


def _related_loops(
    event: StructuredEvent,
    owner_id: str,
    existing: list[OpenLoop],
    requested_ids: list[str],
    *,
    excluded_id: str | None = None,
) -> list[OpenLoop]:
    """Link only same-owner captures that share an explicit place value.

    This intentionally avoids fuzzy title matching: a user can understand why a
    saved restaurant and a reservation at that restaurant are connected.
    """

    key = _context_place_key(event)
    requested = set(requested_ids)
    return [
        candidate
        for candidate in existing
        if candidate.owner_id == owner_id
        and candidate.id != excluded_id
        and (candidate.id in requested or (key and _context_place_key(candidate.event) == key))
    ]


class LoopService:
    def __init__(self, repository: LoopRepository) -> None:
        self.repository = repository

    def create(self, request: CreateLoopRequest, owner_id: str = "dev-local") -> OpenLoop:
        now = datetime.now(UTC)
        generated_actions, generated_checklist, generated_checkpoints = _default_graph(
            request.event,
            reference_at=now,
        )
        requested_checkpoints: list[Checkpoint] = []
        for checkpoint in request.checkpoints:
            if checkpoint.due_at is None:
                continue
            due_at = (
                checkpoint.due_at.replace(tzinfo=UTC)
                if checkpoint.due_at.tzinfo is None
                else checkpoint.due_at.astimezone(UTC)
            )
            if due_at > now:
                requested_checkpoints.append(checkpoint.model_copy(update={"due_at": due_at}))
        peers = _related_loops(
            request.event,
            owner_id,
            self.repository.list(),
            request.related_loop_ids,
        )
        loop = OpenLoop(
            id=_id(),
            owner_id=owner_id,
            status=request.status or LoopStatus.OPEN,
            event=request.event,
            suggested_question=request.suggested_question,
            actions=request.actions or generated_actions,
            checklist=request.checklist or generated_checklist,
            checkpoints=requested_checkpoints or generated_checkpoints,
            related_loop_ids=sorted({peer.id for peer in peers}),
            retention=request.retention,
            created_at=now,
            updated_at=now,
        )
        saved = self.repository.save(loop)
        for peer in peers:
            if saved.id in peer.related_loop_ids:
                continue
            peer.related_loop_ids = sorted({*peer.related_loop_ids, saved.id})
            peer.updated_at = now
            self.repository.save(peer)
        return saved

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
        peers = _related_loops(
            loop.event,
            loop.owner_id,
            self.repository.list(),
            loop.related_loop_ids,
            excluded_id=loop.id,
        )
        loop.related_loop_ids = sorted({*loop.related_loop_ids, *(peer.id for peer in peers)})
        saved = self.repository.save(loop)
        for peer in peers:
            if saved.id in peer.related_loop_ids:
                continue
            peer.related_loop_ids = sorted({*peer.related_loop_ids, saved.id})
            peer.updated_at = loop.updated_at
            self.repository.save(peer)
        return saved

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

    def delete(self, loop_id: str) -> bool:
        loop = self.require(loop_id)
        now = datetime.now(UTC)
        for peer in self.repository.list():
            if peer.owner_id != loop.owner_id or loop.id not in peer.related_loop_ids:
                continue
            peer.related_loop_ids = [item for item in peer.related_loop_ids if item != loop.id]
            peer.updated_at = now
            self.repository.save(peer)
        return self.repository.delete(loop_id)

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
