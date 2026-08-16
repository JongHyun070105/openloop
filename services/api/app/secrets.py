import json
import os
from typing import Any


_SECRET_CONTRACTS = {
    "GEMINI_SECRET_ARN": ("GEMINI_API_KEY", {"GEMINI_API_KEY", "GEMINI_MODEL"}),
    "KAKAO_SECRET_ARN": ("KAKAO_REST_API_KEY", {"KAKAO_REST_API_KEY"}),
    "KMA_SECRET_ARN": ("KMA_AUTH_KEY", {"KMA_AUTH_KEY"}),
    "POSTHOG_SECRET_ARN": (
        "POSTHOG_PROJECT_API_KEY",
        {"POSTHOG_PROJECT_API_KEY", "POSTHOG_HOST"},
    ),
    "SENTRY_SECRET_ARN": ("SENTRY_DSN", {"SENTRY_DSN"}),
}
_INTEGRATION_SECRET_KEYS = {
    "GEMINI_API_KEY",
    "GEMINI_MODEL",
    "KAKAO_REST_API_KEY",
    "KMA_AUTH_KEY",
    "POSTHOG_PROJECT_API_KEY",
    "POSTHOG_HOST",
    "SENTRY_DSN",
}


class ProviderSecretError(RuntimeError):
    pass


def load_provider_secrets_from_env(client: Any | None = None) -> int:
    integration_arn = os.getenv("INTEGRATION_SECRET_ARN")
    configured = ["INTEGRATION_SECRET_ARN"] if integration_arn else [
        name for name in _SECRET_CONTRACTS if os.getenv(name)
    ]
    if not configured:
        return 0
    if client is None:
        import boto3

        client = boto3.client("secretsmanager")
    loaded = 0
    for arn_name in configured:
        try:
            response = client.get_secret_value(SecretId=os.environ[arn_name])
            secret = response.get("SecretString")
            if not isinstance(secret, str) or not secret:
                raise ValueError("SecretString is missing")
            if arn_name == "INTEGRATION_SECRET_ARN":
                values = _parse_integration_secret(secret)
            else:
                primary_name, allowed_names = _SECRET_CONTRACTS[arn_name]
                values = _parse_secret(secret, primary_name, allowed_names)
        except Exception:
            # Never include the ARN, secret name, response body, or provider exception text.
            raise ProviderSecretError("A configured provider secret could not be loaded") from None
        for name, value in values.items():
            # A template may deliberately supply an empty optional environment
            # value. Only a non-empty direct value takes precedence over a secret.
            if not os.getenv(name):
                os.environ[name] = value
        loaded += 1
    return loaded


def _parse_integration_secret(secret: str) -> dict[str, str]:
    parsed = json.loads(secret)
    if not isinstance(parsed, dict):
        raise ValueError("Integration SecretString must be a JSON object")
    values = {
        name: value
        for name, value in parsed.items()
        if name in _INTEGRATION_SECRET_KEYS and isinstance(value, str) and value
    }
    if not values:
        raise ValueError("Integration secret has no supported values")
    return values


def _parse_secret(secret: str, primary_name: str, allowed_names: set[str]) -> dict[str, str]:
    try:
        parsed = json.loads(secret)
    except json.JSONDecodeError:
        return {primary_name: secret}
    if isinstance(parsed, str):
        return {primary_name: parsed}
    if not isinstance(parsed, dict):
        raise ValueError("Secret JSON must be an object or string")
    values = {
        name: value
        for name, value in parsed.items()
        if name in allowed_names and isinstance(value, str) and value
    }
    if primary_name not in values:
        raise ValueError("Secret JSON is missing its primary value")
    return values
