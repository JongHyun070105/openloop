import tempfile
import unittest
from datetime import UTC, date, datetime, time
from pathlib import Path

from app.demo_analyzer import analyze_demo
from app.models import (
    AmbiguityUpdate,
    AnalyzeRequest,
    Confidence,
    CreateLoopRequest,
    Intent,
    LoopStatus,
    RetentionPolicy,
    StructuredEvent,
)
from app.repository import LoopRepository
from app.service import LoopService, _default_graph


class LoopServiceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.repository = LoopRepository(Path(self.temp_dir.name) / "loops.sqlite3")
        self.service = LoopService(self.repository)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def test_persists_and_resolves_ambiguous_loop(self) -> None:
        analysis = analyze_demo(AnalyzeRequest(text="토요일 저녁 성수에서 만나자"))
        created = self.service.create(CreateLoopRequest(**analysis.model_dump()))

        self.assertEqual(created.status, LoopStatus.NEEDS_INPUT)
        self.assertEqual(len(self.repository.list()), 1)
        self.assertTrue(created.actions)

        resolved = self.service.resolve_ambiguity(
            created.id, AmbiguityUpdate(field="start_time", value="19:30:00")
        )
        self.assertEqual(resolved.status, LoopStatus.OPEN)
        self.assertEqual(resolved.event.start_time.hour, 19)
        self.assertEqual(resolved.event.missing_fields, [])
        self.assertIsNone(resolved.suggested_question)
        self.assertTrue(resolved.event.summary)
        self.assertTrue(resolved.checkpoints)
        self.assertTrue(
            all(
                checkpoint.due_at and checkpoint.due_at > resolved.updated_at
                for checkpoint in resolved.checkpoints
            )
        )

    def test_resolving_place_adds_the_place_action_without_replacing_calendar(self) -> None:
        analysis = analyze_demo(AnalyzeRequest(text="내일 오후 7시 약속"))
        created = self.service.create(CreateLoopRequest(**analysis.model_dump()))
        calendar = next(item for item in created.actions if item.type == "calendar")

        resolved = self.service.resolve_ambiguity(
            created.id, AmbiguityUpdate(field="place", value="성수")
        )

        refreshed_calendar = next(item for item in resolved.actions if item.type == "calendar")
        self.assertEqual(refreshed_calendar.id, calendar.id)
        self.assertTrue(any(item.type == "place" and item.title == "성수" for item in resolved.actions))

    def test_deadline_generates_checklist_and_checkpoints(self) -> None:
        analysis = analyze_demo(
            AnalyzeRequest(text="AI 공모전 접수 마감 8월 22일 23:59. 제출물: 작품 파일, 포트폴리오")
        )
        created = self.service.create(CreateLoopRequest(**analysis.model_dump()))

        self.assertEqual(len(created.checklist), 2)
        self.assertEqual(created.checklist[0].title, "작품 파일")
        self.assertTrue(created.checklist[0].required)
        self.assertEqual(created.checklist[1].title, "포트폴리오")
        self.assertTrue(created.checklist[1].required)
        self.assertTrue(created.checkpoints)
        self.assertTrue(
            all(checkpoint.due_at and checkpoint.due_at > created.created_at for checkpoint in created.checkpoints)
        )
        updated = self.service.set_item_completion(created.id, "checklist", created.checklist[0].id, True)
        self.assertTrue(updated.checklist[0].completed)

    def test_same_day_appointment_omits_a_stale_day_before_checkpoint(self) -> None:
        event = StructuredEvent(
            type=Intent.APPOINTMENT,
            title="저녁 약속",
            date=date(2026, 8, 17),
            start_time=time(19),
            place={"name": "성수"},
            source="text",
            confidence=Confidence(date=1, time=1, location=1, title=1),
        )
        reference = datetime(2026, 8, 17, 2, tzinfo=UTC)  # 11:00 Asia/Seoul

        _, _, checkpoints = _default_graph(event, reference_at=reference)

        self.assertEqual([checkpoint.offset for checkpoint in checkpoints], ["T-1h"])
        self.assertTrue(all(checkpoint.due_at and checkpoint.due_at > reference for checkpoint in checkpoints))

    def test_nearby_deadline_uses_one_same_day_alert_instead_of_stale_cadence(self) -> None:
        event = StructuredEvent(
            type=Intent.DEADLINE,
            title="공모전 마감",
            date=date(2026, 8, 17),
            start_time=time(19),
            source="text",
            confidence=Confidence(date=1, time=1, location=1, title=1),
        )
        reference = datetime(2026, 8, 17, 2, tzinfo=UTC)  # 11:00 Asia/Seoul

        _, _, checkpoints = _default_graph(event, reference_at=reference)

        self.assertEqual([checkpoint.offset for checkpoint in checkpoints], ["D-day"])
        self.assertEqual(checkpoints[0].due_at, datetime(2026, 8, 17, 10, tzinfo=UTC))

    def test_place_has_only_a_map_action_and_links_by_exact_normalized_place(self) -> None:
        first_event = StructuredEvent(
            type=Intent.PLACE,
            title="난포",
            place={"name": "난포 성수"},
            source="text",
            confidence=Confidence(date=0, time=0, location=1, title=1),
        )
        first = self.service.create(CreateLoopRequest(event=first_event))
        second_event = StructuredEvent(
            type=Intent.APPOINTMENT,
            title="저녁 약속",
            date=date(2026, 8, 20),
            start_time=time(19),
            place={"name": "난포성수"},
            source="text",
            confidence=Confidence(date=1, time=1, location=1, title=1),
        )
        second = self.service.create(CreateLoopRequest(event=second_event))

        self.assertEqual([item.type for item in first.actions], ["place"])
        self.assertEqual(first.checkpoints, [])
        self.assertEqual(second.related_loop_ids, [first.id])
        self.assertEqual(self.repository.get(first.id).related_loop_ids, [second.id])

        self.assertTrue(self.service.delete(second.id))
        self.assertEqual(self.repository.get(first.id).related_loop_ids, [])

    def test_coupon_has_one_use_action_and_no_time_requirement(self) -> None:
        event = StructuredEvent(
            type=Intent.COUPON,
            title="커피 쿠폰",
            expires_on=date(2026, 8, 20),
            source="text",
            confidence=Confidence(date=1, time=0, location=0, title=1),
        )
        actions, checklist, checkpoints = _default_graph(
            event,
            reference_at=datetime(2026, 8, 17, 0, tzinfo=UTC),
        )

        self.assertEqual([item.type for item in actions], ["coupon", "reminder"])
        self.assertEqual(checklist, [])
        self.assertEqual([item.offset for item in checkpoints], ["D-1"])

    def test_close_and_forget_immediately_removes_loop_on_next_read(self) -> None:
        analysis = analyze_demo(AnalyzeRequest(text="6시 말고 7시 난포 예약했음"))
        created = self.service.create(CreateLoopRequest(**analysis.model_dump()))
        completed = self.service.complete(created.id, RetentionPolicy.IMMEDIATELY)

        self.assertEqual(completed.status, LoopStatus.CLOSED)
        self.assertIsNotNone(completed.delete_at)
        self.assertIsNone(self.repository.get(created.id))

    def test_delete_is_scoped_to_one_loop(self) -> None:
        result = analyze_demo(AnalyzeRequest(text="토요일 저녁 성수에서 만나자"))
        first = self.service.create(CreateLoopRequest(**result.model_dump()))
        second = self.service.create(CreateLoopRequest(**result.model_dump()))

        self.assertTrue(self.repository.delete(first.id))
        self.assertIsNone(self.repository.get(first.id))
        self.assertIsNotNone(self.repository.get(second.id))

    def test_purchase_has_purchase_action_and_d1_checkpoint(self) -> None:
        event = StructuredEvent(
            type=Intent.PURCHASE,
            title="무선 이어폰",
            expires_on=date(2026, 8, 25),
            place={"name": "쿠팡"},
            source="text",
            confidence=Confidence(date=1, time=0, location=1, title=1),
        )
        actions, checklist, checkpoints = _default_graph(
            event,
            reference_at=datetime(2026, 8, 17, 0, tzinfo=UTC),
        )

        self.assertEqual([item.type for item in actions], ["purchase", "place", "reminder"])
        self.assertEqual(checklist, [])
        self.assertEqual([item.offset for item in checkpoints], ["D-1"])

    def test_reservation_has_calendar_and_t2h_checkpoint(self) -> None:
        event = StructuredEvent(
            type=Intent.RESERVATION,
            title="제주 항공권",
            date=date(2026, 8, 20),
            start_time=time(14, 30),
            place={"name": "김포공항"},
            source="text",
            confidence=Confidence(date=1, time=1, location=1, title=1),
        )
        actions, checklist, checkpoints = _default_graph(
            event,
            reference_at=datetime(2026, 8, 17, 0, tzinfo=UTC),
        )

        self.assertEqual([item.type for item in actions], ["reservation", "calendar", "place", "reminder"])
        self.assertEqual(checklist, [])
        self.assertEqual([item.offset for item in checkpoints], ["T-2h"])


if __name__ == "__main__":
    unittest.main()
