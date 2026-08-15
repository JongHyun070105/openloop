import unittest

from app.demo_analyzer import analyze_demo
from app.models import AnalyzeRequest, LoopStatus


class DemoAnalyzerTests(unittest.TestCase):
    def test_resolves_final_agreement(self) -> None:
        result = analyze_demo(AnalyzeRequest(text="6시? 난 알바가 6시까지야. 그럼 7시 난포 예약했음"))
        self.assertEqual(result.status, LoopStatus.OPEN)
        self.assertEqual(result.event.start_time.hour, 19)
        self.assertGreater(result.event.confidence.time, 0.95)

    def test_asks_only_for_missing_time(self) -> None:
        result = analyze_demo(AnalyzeRequest(text="토요일 저녁 성수에서 만나자"))
        self.assertEqual(result.status, LoopStatus.NEEDS_INPUT)
        self.assertEqual(result.event.missing_fields, ["start_time"])
        self.assertIsNotNone(result.suggested_question)

    def test_extracts_deadline(self) -> None:
        result = analyze_demo(AnalyzeRequest(text="AI 공모전 접수 마감 8월 22일 23:59"))
        self.assertEqual(result.event.type.value, "deadline")
        self.assertEqual(len(result.event.reminders), 3)


if __name__ == "__main__":
    unittest.main()
