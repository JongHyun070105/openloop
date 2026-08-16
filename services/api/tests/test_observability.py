import json
import os
import unittest
from unittest.mock import patch

from app.observability import PrivacySafePostHog, analytics_from_env, scrub_sentry_event


class _Response:
    def __enter__(self):  # type: ignore[no-untyped-def]
        return self

    def __exit__(self, *_args):  # type: ignore[no-untyped-def]
        return None

    def read(self, _limit: int = -1) -> bytes:
        return b"1"


class ObservabilityTests(unittest.TestCase):
    def test_posthog_allows_only_non_content_properties(self) -> None:
        captured = {}

        def opener(request, timeout):  # type: ignore[no-untyped-def]
            captured["payload"] = json.loads(request.data)
            captured["timeout"] = timeout
            return _Response()

        analytics = PrivacySafePostHog("project-key", opener=opener)
        analytics.capture(
            "analysis_completed",
            {
                "source": "text",
                "status": "open",
                "raw_text": "private appointment text",
                "token": "private-token",
            },
        )

        properties = captured["payload"]["properties"]
        self.assertEqual(properties["source"], "text")
        self.assertNotIn("raw_text", properties)
        self.assertNotIn("token", properties)
        self.assertFalse(properties["$process_person_profile"])

    def test_posthog_is_fail_open(self) -> None:
        analytics = PrivacySafePostHog(
            "project-key", opener=lambda *_args, **_kwargs: (_ for _ in ()).throw(TimeoutError())
        )
        analytics.capture("analysis_completed", {"status": "open"})

    def test_posthog_uses_default_host_when_optional_environment_value_is_blank(self) -> None:
        with patch.dict(
            os.environ,
            {"POSTHOG_PROJECT_API_KEY": "project-key", "POSTHOG_HOST": ""},
            clear=True,
        ):
            analytics = analytics_from_env()

        self.assertIsInstance(analytics, PrivacySafePostHog)
        self.assertEqual(analytics.endpoint, "https://us.i.posthog.com/capture/")

    def test_sentry_scrubber_removes_request_and_user_content(self) -> None:
        event = {
            "user": {"id": "private"},
            "request": {
                "data": "raw",
                "query_string": "q=private",
                "url": "https://api.example/v1/analyze?q=private",
            },
            "breadcrumbs": {"values": [{"message": "private", "data": {"token": "secret"}}]},
            "exception": {"values": [{"type": "ValueError", "value": "private text"}]},
        }

        scrubbed = scrub_sentry_event(event)
        self.assertNotIn("user", scrubbed)
        self.assertNotIn("data", scrubbed["request"])
        self.assertNotIn("query_string", scrubbed["request"])
        self.assertEqual(scrubbed["request"]["url"], "https://api.example/v1/analyze")
        self.assertNotIn("message", scrubbed["breadcrumbs"]["values"][0])
        self.assertNotIn("value", scrubbed["exception"]["values"][0])


if __name__ == "__main__":
    unittest.main()
