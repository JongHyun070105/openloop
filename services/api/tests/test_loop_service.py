import tempfile
import unittest
from pathlib import Path

from app.demo_analyzer import analyze_demo
from app.models import (
    AmbiguityUpdate,
    AnalyzeRequest,
    CreateLoopRequest,
    LoopStatus,
    RetentionPolicy,
)
from app.repository import LoopRepository
from app.service import LoopService


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
        self.assertEqual(len(created.checkpoints), 3)
        updated = self.service.set_item_completion(created.id, "checklist", created.checklist[0].id, True)
        self.assertTrue(updated.checklist[0].completed)

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


if __name__ == "__main__":
    unittest.main()
