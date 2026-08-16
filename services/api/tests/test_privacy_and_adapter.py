import json
import unittest
from unittest.mock import patch

from app.analyzer import JsonHttpAnalysisAdapter
from app.models import AnalyzeRequest
from app.privacy import redact_pii


class _Response:
    def __init__(self, payload: bytes) -> None:
        self.payload = payload

    def __enter__(self) -> "_Response":
        return self

    def __exit__(self, *_args: object) -> None:
        return None

    def read(self) -> bytes:
        return self.payload


class PrivacyAndAdapterTests(unittest.TestCase):
    def test_redacts_high_risk_pii(self) -> None:
        source = "메일 a.person@example.com 전화 010-1234-5678 주민번호 900101-1234567"
        redacted = redact_pii(source)
        self.assertNotIn("a.person@example.com", redacted)
        self.assertNotIn("010-1234-5678", redacted)
        self.assertNotIn("900101-1234567", redacted)
        self.assertIn("[REDACTED_EMAIL]", redacted)

    def test_remote_adapter_sends_only_redacted_text(self) -> None:
        response = {
            "status": "needs_input",
            "event": {
                "type": "appointment",
                "title": "성수 저녁 약속",
                "date": "2026-08-15",
                "start_time": None,
                "place": {"name": "성수"},
                "participants": [],
                "purpose": "저녁 약속",
                "reminders": [],
                "source": "text",
                "confidence": {"date": 0.9, "time": 0.4, "location": 0.9, "title": 0.8},
                "missing_fields": ["start_time"],
                "resolution_note": None,
            },
            "suggested_question": "몇 시인가요?",
        }
        captured = {}

        def fake_open(request, timeout):  # type: ignore[no-untyped-def]
            captured["body"] = json.loads(request.data)
            captured["timeout"] = timeout
            return _Response(json.dumps(response).encode())

        adapter = JsonHttpAnalysisAdapter("https://agent.example/analyze", "secret")
        with patch("app.analyzer.urlopen", fake_open):
            result = adapter.analyze(AnalyzeRequest(text="연락처 010-1234-5678 성수 약속"))

        self.assertEqual(result.status.value, "needs_input")
        self.assertNotIn("010-1234-5678", captured["body"]["text"])
        self.assertIn("[REDACTED_PHONE]", captured["body"]["text"])


if __name__ == "__main__":
    unittest.main()
