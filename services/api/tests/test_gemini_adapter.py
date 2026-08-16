import json
import unittest
from datetime import date
from types import SimpleNamespace
from unittest.mock import patch

from app.analyzer import GeminiAnalysisAdapter, ImageInput
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


class GeminiAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.captured = {}

        def generate_content(**kwargs):  # type: ignore[no-untyped-def]
            self.captured.update(kwargs)
            return SimpleNamespace(parsed=_response_payload(), text=None)

        client = SimpleNamespace(models=SimpleNamespace(generate_content=generate_content))
        types_module = SimpleNamespace(Part=_Part, GenerateContentConfig=_Config, ThinkingConfig=_Thinking)
        self.adapter = GeminiAnalysisAdapter("server-key", client=client, types_module=types_module)

    def test_uses_stable_model_strict_schema_and_redacted_text(self) -> None:
        result = self.adapter.analyze(AnalyzeRequest(text="전화 010-1234-5678 성수에서 만나자"))

        self.assertEqual(result.status.value, "needs_input")
        self.assertEqual(self.captured["model"], "gemini-3.5-flash-lite")
        self.assertNotIn("010-1234-5678", self.captured["contents"])
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
        self.assertEqual(part, {"data": b"image-bytes", "mime_type": "image/png"})

    def test_multiple_images_are_sent_as_one_multimodal_context(self) -> None:
        self.adapter.analyze_images(
            [
                ImageInput("one.png", "image/png", b"one"),
                ImageInput("two.png", "image/png", b"two"),
            ],
            "마감 공지",
            "screenshot",
        )

        prompt, first, second = self.captured["contents"]
        self.assertIn("all user-shared images", prompt)
        self.assertEqual(first, {"data": b"one", "mime_type": "image/png"})
        self.assertEqual(second, {"data": b"two", "mime_type": "image/png"})

    def test_rejects_schema_extra_fields(self) -> None:
        invalid = _response_payload()
        invalid["event"]["raw_text"] = "must not be accepted"
        self.adapter.client.models.generate_content = lambda **_kwargs: SimpleNamespace(
            parsed=invalid, text=None
        )

        with self.assertLogs("app.analyzer", level="WARNING") as logs:
            with self.assertRaisesRegex(ExternalIntegrationError, "Gemini analysis failed"):
                self.adapter.analyze(AnalyzeRequest(text="성수 약속"))

        self.assertIn("gemini_generation_failed", logs.output[0])
        self.assertNotIn("성수 약속", logs.output[0])
        self.assertNotIn("server-key", logs.output[0])

    def test_normalizes_complete_new_loop_status_and_yearless_korean_time(self) -> None:
        complete = _response_payload()
        complete["status"] = "closed"
        complete["event"].update(
            {
                "date": "2024-08-20",
                "start_time": "15:00:00Z",
                "missing_fields": [],
            }
        )
        self.adapter.client.models.generate_content = lambda **_kwargs: SimpleNamespace(
            parsed=complete, text=None
        )

        with patch("app.analyzer._today_in_kst", return_value=date(2026, 8, 16)):
            result = self.adapter.analyze(
                AnalyzeRequest(text="8월 20일 오후 3시 서울시청역 2번 출구에서 프로젝트 회의")
            )

        self.assertEqual(result.status, LoopStatus.OPEN)
        self.assertEqual(str(result.event.date), "2026-08-20")
        self.assertEqual(str(result.event.start_time), "15:00:00")


if __name__ == "__main__":
    unittest.main()
