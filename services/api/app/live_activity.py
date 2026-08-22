import json
import os
import time
from typing import Any, Protocol

import httpx

from .device_tokens import DeviceTokenStore


class LiveActivitySender(Protocol):
    provider: str

    def send_completed(self, owner_id: str, title: str, job_id: str) -> bool: ...


class DisabledLiveActivitySender:
    provider = "disabled"

    def send_completed(self, owner_id: str, title: str, job_id: str) -> bool:
        del owner_id, title, job_id
        return False


class SqsLiveActivitySender:
    """Accept Live Activity work without putting FCM on the HTTP critical path."""

    provider = "sqs"

    def __init__(
        self,
        devices: DeviceTokenStore,
        queue_url: str,
        sqs_client: Any | None = None,
    ) -> None:
        self.devices = devices
        self.queue_url = queue_url
        if sqs_client is None:
            import boto3

            sqs_client = boto3.client("sqs")
        self.sqs_client = sqs_client

    def send_completed(self, owner_id: str, title: str, job_id: str) -> bool:
        if self.devices.live_activity_target(owner_id) is None:
            return False
        try:
            self.sqs_client.send_message(
                QueueUrl=self.queue_url,
                MessageBody=json.dumps(
                    {
                        "ownerId": owner_id,
                        "title": title.strip()[:80] or "일정",
                        "jobId": job_id,
                    },
                    ensure_ascii=False,
                    separators=(",", ":"),
                ),
            )
            return True
        except Exception:
            return False


class FcmLiveActivitySender:
    provider = "fcm"

    def __init__(
        self,
        devices: DeviceTokenStore,
        secret_arn: str,
        project_id: str | None = None,
        secrets_client: Any | None = None,
        http_client: httpx.Client | None = None,
    ) -> None:
        self.devices = devices
        self.secret_arn = secret_arn
        self.configured_project_id = project_id
        if secrets_client is None:
            import boto3

            secrets_client = boto3.client("secretsmanager")
        self.secrets_client = secrets_client
        self.http_client = http_client or httpx.Client(timeout=8)
        self._secret: dict[str, Any] | None = None

    def _load_secret(self) -> dict[str, Any]:
        if self._secret is None:
            response = self.secrets_client.get_secret_value(SecretId=self.secret_arn)
            raw = response.get("SecretString")
            if not isinstance(raw, str):
                raise RuntimeError("FCM secret must contain a JSON SecretString")
            parsed = json.loads(raw)
            if not isinstance(parsed, dict):
                raise RuntimeError("FCM secret must contain a JSON object")
            self._secret = parsed
        return self._secret

    def _oauth_token(self, secret: dict[str, Any]) -> str:
        from google.auth.transport.requests import Request as GoogleAuthRequest
        from google.oauth2 import service_account

        credentials = service_account.Credentials.from_service_account_info(
            secret,
            scopes=["https://www.googleapis.com/auth/firebase.messaging"],
        )
        credentials.refresh(GoogleAuthRequest())
        if not credentials.token:
            raise RuntimeError("FCM OAuth token refresh returned no token")
        return credentials.token

    def send_completed(self, owner_id: str, title: str, job_id: str) -> bool:
        target = self.devices.live_activity_target(owner_id)
        if target is None:
            return False
        fcm_token, push_to_start_token = target
        try:
            secret = self._load_secret()
            project_id = self.configured_project_id or secret.get("project_id")
            if not isinstance(project_id, str) or not project_id:
                return False
            access_token = self._oauth_token(secret)
            safe_title = title.strip()[:80] or "일정"
            payload = {
                "message": {
                    "token": fcm_token,
                    "apns": {
                        "live_activity_token": push_to_start_token,
                        "headers": {
                            "apns-priority": "10",
                            "apns-collapse-id": job_id,
                        },
                        "payload": {
                            "aps": {
                                "timestamp": int(time.time()),
                                "event": "start",
                                "input-push-token": 1,
                                "content-state": {
                                    "phase": "completed",
                                    "title": safe_title,
                                },
                                "attributes-type": "OpenLoopAnalysisAttributes",
                                "attributes": {"jobId": job_id},
                                "alert": {
                                    "title": f"{safe_title} 정리 완료",
                                    "body": "OpenLoop에서 분석 결과를 확인해 보세요.",
                                },
                            }
                        },
                    },
                }
            }
            response = self.http_client.post(
                f"https://fcm.googleapis.com/v1/projects/{project_id}/messages:send",
                headers={
                    "Authorization": f"Bearer {access_token}",
                    "Content-Type": "application/json",
                },
                json=payload,
            )
            return 200 <= response.status_code < 300
        except Exception:
            return False

    def send_fallback_notification(self, owner_id: str, title: str, job_id: str) -> bool:
        fcm_token = self.devices.latest_ios_fcm_token(owner_id)
        if not fcm_token:
            return False
        try:
            secret = self._load_secret()
            project_id = self.configured_project_id or secret.get("project_id")
            if not isinstance(project_id, str) or not project_id:
                return False
            access_token = self._oauth_token(secret)
            safe_title = title.strip()[:80] or "일정"
            response = self.http_client.post(
                f"https://fcm.googleapis.com/v1/projects/{project_id}/messages:send",
                headers={
                    "Authorization": f"Bearer {access_token}",
                    "Content-Type": "application/json",
                },
                json={
                    "message": {
                        "token": fcm_token,
                        "notification": {
                            "title": f"{safe_title} 정리 완료",
                            "body": "OpenLoop에서 분석 결과를 확인해 보세요.",
                        },
                        "data": {
                            "type": "analysis.completed",
                            "job_id": job_id,
                            "payload": f"draft:{job_id}",
                        },
                        "apns": {
                            "headers": {
                                "apns-priority": "10",
                                "apns-collapse-id": job_id,
                            },
                            "payload": {"aps": {"sound": "default"}},
                        },
                    }
                },
            )
            return 200 <= response.status_code < 300
        except Exception:
            return False


def live_activity_sender_from_env(
    devices: DeviceTokenStore,
) -> LiveActivitySender:
    queue_url = os.getenv("LIVE_ACTIVITY_QUEUE_URL", "").strip()
    enabled = os.getenv("OPENLOOP_LIVE_ACTIVITY_ENABLED", "false").lower() == "true"
    if not enabled or not queue_url or devices.provider == "disabled":
        return DisabledLiveActivitySender()
    return SqsLiveActivitySender(
        devices=devices,
        queue_url=queue_url,
    )
