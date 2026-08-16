import json
import os
import re
from typing import Callable, Protocol
from urllib.request import Request, urlopen
from urllib.parse import urlsplit, urlunsplit


_EVENT_NAME = re.compile(r"^[a-z][a-z0-9_]{1,63}$")
_SAFE_PROPERTIES = {
    "source",
    "status",
    "intent",
    "provider",
    "result_count",
    "available",
    "platform",
    "registered",
}


class Analytics(Protocol):
    provider: str

    def capture(self, event: str, properties: dict[str, object] | None = None) -> None: ...


class NoopAnalytics:
    provider = "disabled"

    def capture(self, event: str, properties: dict[str, object] | None = None) -> None:
        del event, properties


class PrivacySafePostHog:
    """Fail-open server event capture with an allowlist that excludes user content."""

    provider = "posthog"

    def __init__(
        self,
        project_api_key: str,
        host: str = "https://us.i.posthog.com",
        timeout_seconds: float = 1.0,
        opener: Callable[..., object] = urlopen,
    ) -> None:
        self.project_api_key = project_api_key
        self.endpoint = f"{host.rstrip('/')}/capture/"
        self.timeout_seconds = timeout_seconds
        self.opener = opener

    def capture(self, event: str, properties: dict[str, object] | None = None) -> None:
        if not _EVENT_NAME.fullmatch(event):
            return
        safe = {key: value for key, value in (properties or {}).items() if key in _SAFE_PROPERTIES}
        safe.update({"distinct_id": "openloop-api", "$process_person_profile": False})
        request = Request(
            self.endpoint,
            data=json.dumps(
                {"api_key": self.project_api_key, "event": event, "properties": safe},
                separators=(",", ":"),
            ).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with self.opener(request, timeout=self.timeout_seconds) as response:
                response.read(1)
        except Exception:
            # Product analytics must never make an API request fail.
            return


def analytics_from_env() -> Analytics:
    api_key = os.getenv("POSTHOG_PROJECT_API_KEY")
    if not api_key:
        return NoopAnalytics()
    return PrivacySafePostHog(
        project_api_key=api_key,
        host=os.getenv("POSTHOG_HOST") or "https://us.i.posthog.com",
        timeout_seconds=float(os.getenv("POSTHOG_TIMEOUT_SECONDS", "1")),
    )


def scrub_sentry_event(event: dict, _hint: dict | None = None) -> dict:
    event.pop("user", None)
    request = event.get("request")
    if isinstance(request, dict):
        for key in ("data", "cookies", "env", "headers", "query_string"):
            request.pop(key, None)
        if isinstance(request.get("url"), str):
            parts = urlsplit(request["url"])
            request["url"] = urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))
    for exception in event.get("exception", {}).get("values", []):
        if isinstance(exception, dict):
            exception.pop("value", None)
    for breadcrumb in event.get("breadcrumbs", {}).get("values", []):
        if isinstance(breadcrumb, dict):
            breadcrumb.pop("data", None)
            breadcrumb.pop("message", None)
    return event


def initialize_sentry_from_env() -> bool:
    dsn = os.getenv("SENTRY_DSN")
    if not dsn:
        return False
    import sentry_sdk

    sentry_sdk.init(
        dsn=dsn,
        environment=os.getenv("APP_ENV", "development"),
        send_default_pii=False,
        traces_sample_rate=float(os.getenv("SENTRY_TRACES_SAMPLE_RATE", "0")),
        include_local_variables=False,
        before_send=scrub_sentry_event,
    )
    return True
