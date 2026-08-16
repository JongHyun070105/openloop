import importlib.util
import unittest
from pathlib import Path


_SCRIPT = Path(__file__).parents[1] / "scripts" / "sync_integration_secret.py"
_SPEC = importlib.util.spec_from_file_location("sync_integration_secret", _SCRIPT)
assert _SPEC and _SPEC.loader
sync = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(sync)


class IntegrationSecretSyncTests(unittest.TestCase):
    def test_non_empty_local_values_override_and_blank_values_preserve_existing(self) -> None:
        merged = sync.merge_supported_values(
            {
                "GEMINI_API_KEY": "remote-gemini",
                "POSTHOG_PROJECT_API_KEY": "remote-posthog",
                "UNSUPPORTED": "ignored",
            },
            {
                "GEMINI_API_KEY": "local-gemini",
                "KMA_AUTH_KEY": "local-kma",
                "POSTHOG_PROJECT_API_KEY": "",
            },
        )

        self.assertEqual(
            merged,
            {
                "GEMINI_API_KEY": "local-gemini",
                "KMA_AUTH_KEY": "local-kma",
                "POSTHOG_PROJECT_API_KEY": "remote-posthog",
            },
        )

    def test_unsupported_and_empty_values_are_excluded(self) -> None:
        self.assertEqual(
            sync.merge_supported_values(None, {"UNSUPPORTED": "value", "SENTRY_DSN": None}),
            {},
        )


if __name__ == "__main__":
    unittest.main()
