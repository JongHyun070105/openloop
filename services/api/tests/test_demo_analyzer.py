import unittest
from datetime import date

from app.demo_analyzer import analyze_demo
from app.models import AnalyzeRequest, LoopStatus


class DemoAnalyzerTests(unittest.TestCase):
    def test_resolves_final_agreement(self) -> None:
        result = analyze_demo(
            AnalyzeRequest(text="내일 오전 6시? 난 알바가 6시까지야. 그럼 오후 7시 난포에서 예약했음"),
            reference_date=date(2026, 8, 16),
        )
        self.assertEqual(result.status, LoopStatus.OPEN)
        self.assertEqual(result.event.start_time.hour, 19)
        self.assertGreater(result.event.confidence.time, 0.95)

    def test_asks_only_for_missing_time(self) -> None:
        result = analyze_demo(
            AnalyzeRequest(text="토요일 저녁 성수에서 만나자"),
            reference_date=date(2026, 8, 16),
        )
        self.assertEqual(result.status, LoopStatus.NEEDS_INPUT)
        self.assertEqual(result.event.missing_fields, ["start_time"])
        self.assertIsNotNone(result.suggested_question)

    def test_extracts_deadline(self) -> None:
        result = analyze_demo(
            AnalyzeRequest(text="AI 공모전 접수 마감 8월 22일 23:59. 제출물: 작품 파일, 포트폴리오"),
            reference_date=date(2026, 8, 16),
        )
        self.assertEqual(result.event.type.value, "deadline")
        self.assertEqual(len(result.event.reminders), 3)
        self.assertEqual([item.title for item in result.event.checklist], ["작품 파일", "포트폴리오"])
        self.assertIn("공모전 마감", result.event.summary or "")
        self.assertIn("2026", result.event.summary or "")

    def test_never_substitutes_demo_appointment_for_arbitrary_input(self) -> None:
        result = analyze_demo(
            AnalyzeRequest(text="내일 오후 3시에 홍대입구역에서 민수와 프로젝트 회의"),
            reference_date=date(2026, 8, 16),
        )
        self.assertEqual(result.status, LoopStatus.OPEN)
        self.assertNotEqual(result.event.title, "성수 저녁 약속")
        self.assertEqual(result.event.start_time.hour, 15)
        self.assertEqual(result.event.place.name if result.event.place else None, "홍대입구역")
        self.assertEqual(result.event.participants, ["민수"])

    def test_relative_date_can_cross_year_and_next_week_is_calendar_grounded(self) -> None:
        tomorrow = analyze_demo(
            AnalyzeRequest(text="내일 오후 3시 강남역에서 약속"),
            reference_date=date(2026, 12, 31),
        )
        next_week = analyze_demo(
            AnalyzeRequest(text="담주 화요일 오후 3시 강남역에서 약속"),
            reference_date=date(2026, 8, 16),
        )

        self.assertEqual(tomorrow.event.date, date(2027, 1, 1))
        self.assertEqual(next_week.event.date, date(2026, 8, 25))


if __name__ == "__main__":
    unittest.main()
