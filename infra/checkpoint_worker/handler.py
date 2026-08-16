"""Consume checkpoint messages and send notifications through FCM HTTP v1."""

from __future__ import annotations

import json
import logging
import os
from datetime import UTC, datetime
from typing import Any

FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
logger = logging.getLogger(__name__)

_dynamodb: Any = None
_secrets: Any = None
_credentials: Any = None
_fcm_secret: dict[str, Any] | None = None


def _client(service: str) -> Any:
    global _dynamodb, _secrets
    if service == "dynamodb":
        if _dynamodb is None:
            import boto3

            _dynamodb = boto3.client("dynamodb")
        return _dynamodb
    if _secrets is None:
        import boto3

        _secrets = boto3.client("secretsmanager")
    return _secrets


def _required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def _secret() -> dict[str, Any]:
    global _fcm_secret
    if _fcm_secret is None:
        response = _client("secretsmanager").get_secret_value(
            SecretId=_required_env("FCM_SECRET_ARN")
        )
        secret_string = response.get("SecretString")
        if not secret_string:
            raise RuntimeError("FCM secret must contain a JSON SecretString")
        _fcm_secret = json.loads(secret_string)
    return _fcm_secret


def _access_token() -> str:
    global _credentials
    from google.auth.transport.requests import Request
    from google.oauth2 import service_account

    if _credentials is None:
        _credentials = service_account.Credentials.from_service_account_info(
            _secret(), scopes=[FCM_SCOPE]
        )
    if not _credentials.valid:
        _credentials.refresh(Request())
    if not _credentials.token:
        raise RuntimeError("FCM OAuth token refresh returned no token")
    return _credentials.token


def _s(item: dict[str, Any], key: str, default: str = "") -> str:
    return item.get(key, {}).get("S", default)


def _checkpoint(table_name: str, message: dict[str, Any]) -> dict[str, Any]:
    response = _client("dynamodb").get_item(
        TableName=table_name,
        Key={"PK": {"S": message["pk"]}, "SK": {"S": message["sk"]}},
        ConsistentRead=True,
    )
    item = response.get("Item")
    if not item:
        raise ValueError("Checkpoint record no longer exists")
    return item


def _devices(table_name: str, user_id: str) -> list[dict[str, Any]]:
    response = _client("dynamodb").query(
        TableName=table_name,
        KeyConditionExpression="PK = :user AND begins_with(SK, :device)",
        FilterExpression="attribute_not_exists(active) OR active = :true",
        ExpressionAttributeValues={
            ":user": {"S": f"USER#{user_id}"},
            ":device": {"S": "DEVICE#"},
            ":true": {"BOOL": True},
        },
        ConsistentRead=True,
    )
    return response.get("Items", [])


def _payload(token: str, checkpoint: dict[str, Any], message: dict[str, Any]) -> dict[str, Any]:
    title = _s(checkpoint, "notificationTitle", "OpenLoop 알림")
    body = _s(checkpoint, "notificationBody", "확인할 일정이 있습니다.")
    return {
        "message": {
            "token": token,
            "notification": {"title": title, "body": body},
            "data": {
                "type": "checkpoint.due",
                # FCM data values must be strings. Keep this public contract
                # independent from the DynamoDB key representation so the app
                # can navigate directly to an OpenLoop after a notification tap.
                "loop_id": message["pk"].removeprefix("LOOP#"),
                "checkpoint_id": message["sk"].removeprefix("CHECKPOINT#"),
                "due_at": str(message.get("dueAt", "")),
            },
            "android": {"priority": "HIGH"},
            "apns": {
                "headers": {"apns-priority": "10"},
                "payload": {"aps": {"sound": "default"}},
            },
        }
    }


def _send(project_id: str, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    import requests

    response = requests.post(
        f"https://fcm.googleapis.com/v1/projects/{project_id}/messages:send",
        headers={
            "Authorization": f"Bearer {_access_token()}",
            "Content-Type": "application/json; charset=UTF-8",
        },
        json=payload,
        timeout=10,
    )
    try:
        body = response.json()
    except ValueError:
        body = {"raw": response.text[:500]}
    return response.status_code, body


def _is_invalid_token(status: int, body: dict[str, Any]) -> bool:
    if status not in (400, 404):
        return False
    error = body.get("error", {})
    if status == 404 and error.get("status") == "UNREGISTERED":
        return True
    return any(
        detail.get("errorCode") in {"UNREGISTERED", "INVALID_ARGUMENT"}
        for detail in error.get("details", [])
        if isinstance(detail, dict)
    )


def _disable_device(table_name: str, device: dict[str, Any]) -> None:
    _client("dynamodb").update_item(
        TableName=table_name,
        Key={"PK": device["PK"], "SK": device["SK"]},
        UpdateExpression="SET active = :false, disabledReason = :reason, updatedAt = :now",
        ExpressionAttributeValues={
            ":false": {"BOOL": False},
            ":reason": {"S": "fcm_invalid_token"},
            ":now": {
                "S": datetime.now(UTC)
                .isoformat(timespec="seconds")
                .replace("+00:00", "Z")
            },
        },
    )


def _mark_delivery(table_name: str, message: dict[str, Any], status: str) -> None:
    _client("dynamodb").update_item(
        TableName=table_name,
        Key={"PK": {"S": message["pk"]}, "SK": {"S": message["sk"]}},
        UpdateExpression="SET deliveryStatus = :status, deliveredAt = :now",
        ExpressionAttributeValues={
            ":status": {"S": status},
            ":now": {
                "S": datetime.now(UTC)
                .isoformat(timespec="seconds")
                .replace("+00:00", "Z")
            },
        },
    )


def _process(record: dict[str, Any]) -> None:
    table_name = _required_env("OPENLOOP_TABLE_NAME")
    message = json.loads(record["body"])
    checkpoint = _checkpoint(table_name, message)
    user_id = _s(checkpoint, "userId")
    if not user_id:
        raise ValueError("Checkpoint record is missing userId")

    secret = _secret()
    project_id = os.environ.get("FCM_PROJECT_ID", "").strip() or secret.get(
        "project_id", ""
    )
    if not project_id:
        raise RuntimeError("FCM project ID is not configured")

    devices = _devices(table_name, user_id)
    sent = 0
    for device in devices:
        token = _s(device, "fcmToken")
        if not token:
            continue
        status, response = _send(project_id, _payload(token, checkpoint, message))
        if 200 <= status < 300:
            sent += 1
            continue
        if _is_invalid_token(status, response):
            _disable_device(table_name, device)
            continue
        raise RuntimeError(f"FCM request failed with HTTP {status}")

    _mark_delivery(table_name, message, "sent" if sent else "no_active_devices")


def lambda_handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    records = event.get("Records", [])
    failures: list[dict[str, str]] = []
    for index, record in enumerate(records):
        try:
            _process(record)
        except Exception:
            logger.exception(
                "Checkpoint notification failed for SQS message %s",
                record.get("messageId", "unknown"),
            )
            failures.extend(
                {"itemIdentifier": remaining["messageId"]}
                for remaining in records[index:]
            )
            break
    return {"batchItemFailures": failures}
