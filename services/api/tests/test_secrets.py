import os
import unittest
from unittest.mock import Mock, patch

from app.secrets import ProviderSecretError, load_provider_secrets_from_env


class ProviderSecretTests(unittest.TestCase):
    def test_loads_single_integration_json_secret(self) -> None:
        client = Mock()
        client.get_secret_value.return_value = {
            "SecretString": (
                '{"GEMINI_API_KEY":"gemini","KAKAO_REST_API_KEY":"kakao",'
                '"KMA_AUTH_KEY":"kma","POSTHOG_PROJECT_API_KEY":"posthog",'
                '"POSTHOG_HOST":"https://us.i.posthog.com",'
                '"SENTRY_DSN":"https://public@sentry.example/1","UNSUPPORTED":"ignored"}'
            )
        }
        with patch.dict(
            os.environ,
            {
                "INTEGRATION_SECRET_ARN": "arn:private:integrations",
                "KMA_AUTH_KEY": "direct-kma",
                "POSTHOG_HOST": "",
            },
            clear=True,
        ):
            self.assertEqual(load_provider_secrets_from_env(client), 1)
            self.assertEqual(os.environ["GEMINI_API_KEY"], "gemini")
            self.assertEqual(os.environ["KAKAO_REST_API_KEY"], "kakao")
            self.assertEqual(os.environ["KMA_AUTH_KEY"], "direct-kma")
            self.assertEqual(os.environ["POSTHOG_HOST"], "https://us.i.posthog.com")
            self.assertNotIn("UNSUPPORTED", os.environ)
        client.get_secret_value.assert_called_once_with(SecretId="arn:private:integrations")

    def test_loads_json_and_plain_secret_contracts_without_overriding_direct_env(self) -> None:
        client = Mock()
        client.get_secret_value.side_effect = [
            {
                "SecretString": (
                    '{"GEMINI_API_KEY":"from-secret","GEMINI_MODEL":"gemini-3.5-flash-lite",'
                    '"IGNORED":"value"}'
                )
            },
            {"SecretString": "plain-kakao-key"},
        ]
        environment = {
            "GEMINI_SECRET_ARN": "arn:private:gemini",
            "KAKAO_SECRET_ARN": "arn:private:kakao",
            "GEMINI_API_KEY": "direct-value-wins",
        }
        with patch.dict(os.environ, environment, clear=True):
            loaded = load_provider_secrets_from_env(client)
            self.assertEqual(loaded, 2)
            self.assertEqual(os.environ["GEMINI_API_KEY"], "direct-value-wins")
            self.assertEqual(os.environ["GEMINI_MODEL"], "gemini-3.5-flash-lite")
            self.assertEqual(os.environ["KAKAO_REST_API_KEY"], "plain-kakao-key")
            self.assertNotIn("IGNORED", os.environ)

    def test_invalid_secret_fails_closed_without_value_or_arn_in_message(self) -> None:
        client = Mock()
        client.get_secret_value.side_effect = RuntimeError("secret-value-and-arn")
        with patch.dict(os.environ, {"SENTRY_SECRET_ARN": "arn:very-private"}, clear=True):
            with self.assertRaises(ProviderSecretError) as raised:
                load_provider_secrets_from_env(client)
        message = str(raised.exception)
        self.assertNotIn("arn:very-private", message)
        self.assertNotIn("secret-value", message)

    def test_no_arn_is_a_noop_without_constructing_client(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(load_provider_secrets_from_env(), 0)


if __name__ == "__main__":
    unittest.main()
