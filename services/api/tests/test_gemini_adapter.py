import json
import unittest
from datetime import date, datetime
from types import SimpleNamespace
from zoneinfo import ZoneInfo

from app.analyzer import GeminiAnalysisAdapter
from app.errors import ExternalIntegrationError
from app.models import AnalyzeRequest, LoopStatus


def _response_payload() -> dict:
    return {
        "status": "needs_input",
        "event": {
            "type": "appointment",
            "title": "성수 저녁 약속",
            "date": "2026-08-16",
            "start_time": None,
            "place": {"name": "성수"},
            "participants": [],
            "purpose": "저녁 약속",
            "reminders": [],
            "source": "text",
            "confidence": {"date": 0.9, "time": 0.4, "location": 0.9, "title": 0.8},
            "missing_fields": ["start_time"],
            "resolution_note": "시간만 누락",
        },
        "suggested_question": "몇 시인가요?",
    }


class _Part:
    @staticmethod
    def from_bytes(**kwargs):  # type: ignore[no-untyped-def]
        return kwargs


class _Config:
    def __init__(self, **kwargs):  # type: ignore[no-untyped-def]
        self.values = kwargs


class _Thinking:
    def __init__(self, **kwargs):  # type: ignore[no-untyped-def]
        self.values = kwargs


class _RetryableGeminiError(Exception):
    status = "DEADLINE_EXCEEDED"
    code = 504


class GeminiAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.captured = {}

        def generate_content(**kwargs):  # type: ignore[no-untyped-def]
            self.captured.update(kwargs)
            return SimpleNamespace(parsed=_response_payload(), text=None)

        client = SimpleNamespace(models=SimpleNamespace(generate_content=generate_content))
        types_module = SimpleNamespace(Part=_Part, GenerateContentConfig=_Config, ThinkingConfig=_Thinking)
        self.adapter = GeminiAnalysisAdapter(
            "server-key",
            client=client,
            types_module=types_module,
            reference_clock=lambda: datetime(
                2026, 8, 16, 11, 1, tzinfo=ZoneInfo("Asia/Seoul")
            ),
        )

    def test_uses_stable_model_strict_schema_and_redacted_text(self) -> None:
        result = self.adapter.analyze(AnalyzeRequest(text="전화 010-1234-5678 성수에서 만나자"))

        self.assertEqual(result.status.value, "needs_input")
        self.assertEqual(self.captured["model"], "gemini-3.5-flash-lite")
        self.assertNotIn("010-1234-5678", self.captured["contents"])
        self.assertIn("2026-08-16T11:01:00+09:00", self.captured["contents"])
        self.assertIn("오늘=reference date", self.captured["contents"])
        config = self.captured["config"].values
        self.assertEqual(config["response_mime_type"], "application/json")
        self.assertEqual(config["response_schema"]["type"], "object")
        schema_json = json.dumps(config["response_schema"])
        self.assertIn('"summary"', schema_json)
        self.assertNotIn("additionalProperties", schema_json)
        self.assertNotIn("additional_properties", schema_json)
        self.assertEqual(config["thinking_config"].values["thinking_level"], "MINIMAL")
        self.assertNotIn("temperature", config)
        self.assertNotIn("top_p", config)
        self.assertNotIn("top_k", config)

    def test_image_bytes_go_only_to_multimodal_part(self) -> None:
        self.adapter.analyze_image(
            filename="private-name.png",
            content_type="image/png",
            content=b"image-bytes",
            companion_text="010-1234-5678",
            source="screenshot",
        )

        prompt, part = self.captured["contents"]
        self.assertNotIn("private-name", prompt)
        self.assertNotIn("010-1234-5678", prompt)
        self.assertIn("2026-08-16T11:01:00+09:00", prompt)
        self.assertIn("this one user-shared image", prompt)
        self.assertEqual(part, {"data": b"image-bytes", "mime_type": "image/png"})
        self.assertEqual(
            self.captured["config"].values["thinking_config"].values["thinking_level"],
            "LOW",
        )

    def test_retries_one_transient_gemini_error_without_logging_input(self) -> None:
        attempts = 0

        def generate_content(**_kwargs):  # type: ignore[no-untyped-def]
            nonlocal attempts
            attempts += 1
            if attempts == 1:
                raise _RetryableGeminiError()
            return SimpleNamespace(parsed=_response_payload(), text=None)

        self.adapter.client.models.generate_content = generate_content
        with self.assertLogs("app.analyzer", level="WARNING") as logs:
            result = self.adapter.analyze(AnalyzeRequest(text="성수 비공개 약속"))

        self.assertEqual(attempts, 2)
        self.assertEqual(result.status.value, "needs_input")
        joined = "\n".join(logs.output)
        self.assertIn("gemini_generation_retry", joined)
        self.assertNotIn("성수 비공개 약속", joined)

    def test_rejects_schema_extra_fields(self) -> None:
        invalid = _response_payload()
        invalid["event"]["raw_text"] = "must not be accepted"
        self.adapter.client.models.generate_content = lambda **_kwargs: SimpleNamespace(
            parsed=invalid, text=None
        )

        with self.assertLogs("app.analyzer", level="WARNING") as logs:
            with self.assertRaisesRegex(ExternalIntegrationError, "Gemini analysis failed"):
                self.adapter.analyze(AnalyzeRequest(text="성수 약속"))

        joined = "\n".join(logs.output)
        self.assertIn("gemini_generation_failed", joined)
        self.assertIn("gemini_payload_validation_failed", joined)
        self.assertIn("event.raw_text", joined)
        self.assertIn("extra_forbidden", joined)
        self.assertNotIn("성수 약속", joined)
        self.assertNotIn("server-key", joined)

    def test_normalizes_complete_new_loop_status_and_yearless_korean_time(self) -> None:
        complete = _response_payload()
        complete["status"] = "closed"
        complete["event"].update(
            {
                "date": "2024-08-20",
                "start_time": "15:00:00Z",
                "missing_fields": [],
                "confidence": {"date": 0.9, "time": 0.95, "location": 0.9, "title": 0.8},
            }
        )
        def generate_content(**kwargs):  # type: ignore[no-untyped-def]
            self.captured.update(kwargs)
            return SimpleNamespace(parsed=complete, text=None)

        self.adapter.client.models.generate_content = generate_content

        result = self.adapter.analyze(
            AnalyzeRequest(text="8월 20일 오후 3시 서울시청역 2번 출구에서 프로젝트 회의")
        )

        self.assertEqual(result.status, LoopStatus.OPEN)
        self.assertEqual(str(result.event.date), "2026-08-20")
        self.assertEqual(str(result.event.start_time), "15:00:00")

    def test_today_is_grounded_to_injected_kst_reference(self) -> None:
        complete = _response_payload()
        complete["status"] = "open"
        complete["event"].update(
            {
                "title": "향수 거래",
                "date": "2027-01-01",
                "start_time": "16:00:00",
                "place": {"name": "종로5가역 12번 출구"},
                "purpose": "향수 거래",
                "missing_fields": [],
                "confidence": {"date": 0.99, "time": 0.99, "location": 0.99, "title": 0.9},
            }
        )
        self.adapter.client.models.generate_content = lambda **_kwargs: SimpleNamespace(
            parsed=complete, text=None
        )

        result = self.adapter.analyze(
            AnalyzeRequest(text="오늘 오후 4시 종로5가역 12번 출구에서 향수 거래")
        )

        self.assertEqual(result.status, LoopStatus.OPEN)
        self.assertEqual(result.event.title, "향수 거래")
        self.assertEqual(result.event.date, date(2026, 8, 16))
        self.assertEqual(str(result.event.start_time), "16:00:00")
        self.assertEqual(
            result.event.place.name if result.event.place else None,
            "종로5가역 12번 출구",
        )
        self.assertEqual(result.event.missing_fields, [])

    def test_request_reference_overrides_server_clock_for_text_and_image(self) -> None:
        self.adapter.reference_clock = lambda: datetime(
            2026, 8, 17, 9, 0, tzinfo=ZoneInfo("Asia/Seoul")
        )
        complete = _response_payload()
        complete["event"].update(
            {
                "date": "2027-01-01",
                "start_time": "16:00:00",
                "place": {"name": "종로5가역 12번 출구"},
                "missing_fields": [],
                "confidence": {"date": 0.99, "time": 0.99, "location": 0.99, "title": 0.9},
            }
        )
        def generate_content(**kwargs):  # type: ignore[no-untyped-def]
            self.captured.update(kwargs)
            return SimpleNamespace(parsed=complete, text=None)

        self.adapter.client.models.generate_content = generate_content
        reference = datetime(2026, 8, 16, 11, 1, tzinfo=ZoneInfo("Asia/Seoul"))

        text = self.adapter.analyze(
            AnalyzeRequest(
                text="오늘 오후 4시 종로5가역 12번 출구에서 향수 거래",
                reference_at=reference,
            )
        )
        self.assertEqual(text.event.date, date(2026, 8, 16))
        self.assertIn("2026-08-16T11:01:00+09:00", self.captured["contents"])

        image = self.adapter.analyze_image(
            filename="capture.png",
            content_type="image/png",
            content=b"image-bytes",
            companion_text="오늘 오후 4시 종로5가역 12번 출구에서 향수 거래",
            source="screenshot",
            reference_at=reference,
        )
        self.assertEqual(image.event.date, date(2026, 8, 16))
        self.assertIn("2026-08-16T11:01:00+09:00", self.captured["contents"][0])

    def test_omitted_year_stays_in_reference_year_even_when_date_has_passed(self) -> None:
        complete = _response_payload()
        complete["event"].update(
            {
                "date": "2027-08-10",
                "start_time": "16:00:00",
                "missing_fields": [],
                "confidence": {"date": 0.99, "time": 0.99, "location": 0.99, "title": 0.9},
            }
        )
        self.adapter.client.models.generate_content = lambda **_kwargs: SimpleNamespace(
            parsed=complete, text=None
        )

        result = self.adapter.analyze(
            AnalyzeRequest(text="8월 10일 오후 4시 성수에서 약속")
        )

        self.assertEqual(result.event.date, date(2026, 8, 10))

    def test_relative_expression_crosses_year_boundary(self) -> None:
        self.adapter.reference_clock = lambda: datetime(
            2026, 12, 31, 23, 30, tzinfo=ZoneInfo("Asia/Seoul")
        )
        complete = _response_payload()
        complete["event"].update(
            {
                "date": "2026-01-01",
                "start_time": "16:00:00",
                "missing_fields": [],
                "confidence": {"date": 0.99, "time": 0.99, "location": 0.99, "title": 0.9},
            }
        )
        self.adapter.client.models.generate_content = lambda **_kwargs: SimpleNamespace(
            parsed=complete, text=None
        )

        result = self.adapter.analyze(AnalyzeRequest(text="내일 오후 4시 성수에서 약속"))

        self.assertEqual(result.event.date, date(2027, 1, 1))

    def test_text_reconciliation_uses_final_explicit_time_and_does_not_invent_date(self) -> None:
        complete = _response_payload()
        complete["event"].update(
            {
                "date": "2026-08-22",
                "start_time": "18:00:00",
                "place": {"name": "합정역"},
                "missing_fields": [],
                "confidence": {"date": 0.9, "time": 0.9, "location": 0.9, "title": 0.9},
            }
        )
        self.adapter.client.models.generate_content = lambda **_kwargs: SimpleNamespace(
            parsed=complete, text=None
        )

        corrected = self.adapter.analyze(
            AnalyzeRequest(text="8월 22일 합정역 스터디는 오후 6시에서 오후 7시 30분으로 변경.")
        )
        self.assertEqual(corrected.event.date, date(2026, 8, 22))
        self.assertEqual(str(corrected.event.start_time), "19:30:00")
        self.assertEqual(corrected.event.missing_fields, [])

        complete["event"].update(
            {
                "date": "2026-08-16",
                "start_time": "15:00:00",
                "place": {"name": "잠실역"},
                "missing_fields": [],
                "confidence": {"date": 0.99, "time": 0.99, "location": 0.99, "title": 0.9},
            }
        )
        missing_date = self.adapter.analyze(
            AnalyzeRequest(text="오후 3시에 잠실역에서 디자인 리뷰.")
        )
        self.assertIsNone(missing_date.event.date)
        self.assertEqual(missing_date.event.missing_fields, ["date"])
        self.assertEqual(missing_date.status, LoopStatus.NEEDS_INPUT)

    def test_place_ignores_provider_temporal_questions(self) -> None:
        payload = _response_payload()
        payload["event"].update(
            {
                "type": "place",
                "title": "난포 성수",
                "date": "2026-08-20",
                "start_time": "19:00:00",
                "place": {"name": "난포 성수"},
                "missing_fields": ["date", "start_time"],
                "confidence": {"date": 0.2, "time": 0.2, "location": 0.98, "title": 0.95},
            }
        )
        self.adapter.client.models.generate_content = lambda **_kwargs: SimpleNamespace(
            parsed=payload, text=None
        )

        result = self.adapter.analyze(AnalyzeRequest(text="난포 성수 맛집 저장"))

        self.assertEqual(result.status, LoopStatus.OPEN)
        self.assertEqual(result.event.missing_fields, [])
        self.assertIsNone(result.event.date)
        self.assertIsNone(result.event.start_time)

    def test_coupon_moves_provider_date_to_expiry_without_time_question(self) -> None:
        payload = _response_payload()
        payload["event"].update(
            {
                "type": "coupon",
                "title": "커피 쿠폰",
                "date": "2026-08-31",
                "start_time": "23:59:00",
                "place": None,
                "missing_fields": ["start_time"],
                "confidence": {"date": 0.98, "time": 0.3, "location": 0.0, "title": 0.95},
            }
        )
        self.adapter.client.models.generate_content = lambda **_kwargs: SimpleNamespace(
            parsed=payload, text=None
        )

        result = self.adapter.analyze(AnalyzeRequest(text="커피 쿠폰 저장"))

        self.assertEqual(result.status, LoopStatus.OPEN)
        self.assertEqual(result.event.expires_on, date(2026, 8, 31))
        self.assertIsNone(result.event.date)
        self.assertIsNone(result.event.start_time)
        self.assertEqual(result.event.missing_fields, [])

    def test_recovers_provider_status_and_omitted_default_fields(self) -> None:
        payload = {
            "status": "closed",
            "event": {
                "type": "appointment",
                "title": "향수 거래",
                "date": "2026-08-16",
                "start_time": "16:00:00",
                "place": {"name": "종로5가역 12번 출구"},
                "confidence": {"date": 0.99, "time": 0.99, "location": 0.99, "title": 0.9},
                "source": "image",
            },
        }
        self.adapter.client.models.generate_content = lambda **_kwargs: SimpleNamespace(
            parsed=payload, text=None
        )

        result = self.adapter.analyze(AnalyzeRequest(text="오늘 오후 4시 향수 거래"))

        self.assertEqual(result.status, LoopStatus.OPEN)
        self.assertEqual(result.event.participants, [])
        self.assertEqual(result.event.reminders, [])
        self.assertEqual(result.event.missing_fields, [])
        self.assertEqual(result.event.source, "text")

    def test_recovers_missing_field_and_status_inconsistency(self) -> None:
        payload = _response_payload()
        payload["status"] = "closed"
        payload["event"].update(
            {
                "date": None,
                "start_time": "16:00:00",
                "missing_fields": None,
                "confidence": {"date": 0.0, "time": 0.99, "location": 0.99, "title": 0.9},
            }
        )
        self.adapter.client.models.generate_content = lambda **_kwargs: SimpleNamespace(
            parsed=payload, text=None
        )

        result = self.adapter.analyze(AnalyzeRequest(text="오후 4시 성수에서 약속"))

        self.assertEqual(result.status, LoopStatus.NEEDS_INPUT)
        self.assertEqual(result.event.missing_fields, ["date"])
        self.assertEqual(result.suggested_question, "언제로 등록할까요?")

    def test_low_confidence_required_field_is_focused_for_confirmation(self) -> None:
        complete = _response_payload()
        complete["event"].update(
            {
                "start_time": "16:00:00",
                "missing_fields": [],
                "confidence": {"date": 0.5, "time": 0.99, "location": 0.99, "title": 0.9},
            }
        )
        complete["suggested_question"] = None
        self.adapter.client.models.generate_content = lambda **_kwargs: SimpleNamespace(
            parsed=complete, text=None
        )

        result = self.adapter.analyze(AnalyzeRequest(text="오늘 오후 4시 성수에서 약속"))

        self.assertEqual(result.status, LoopStatus.NEEDS_INPUT)
        self.assertEqual(result.event.missing_fields, ["date"])
        self.assertEqual(result.suggested_question, "언제로 등록할까요?")


if __name__ == "__main__":
    unittest.main()
