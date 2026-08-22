"""Consume queued Live Activity completions and deliver them through FCM."""

from __future__ import annotations

import json
import logging
import os
import time
from typing import Any
from uuid import uuid4

from .device_tokens import DynamoDeviceTokenStore
from .live_activity import FcmLiveActivitySender

logger = logging.getLogger(__name__)
DELIVERY_LEASE_SECONDS = 45
DELIVERY_TTL_SECONDS = 86400


class DeliveryClaimBusy(RuntimeError):
    pass


def _required_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def _is_conditional_failure(error: Exception) -> bool:
    response = getattr(error, "response", None)
    return isinstance(response, dict) and response.get("Error", {}).get("Code") == (
        "ConditionalCheckFailedException"
    )


def _delivery_key(owner_id: str, job_id: str) -> dict[str, dict[str, str]]:
    return {
        "PK": {"S": f"USER#{owner_id}"},
        "SK": {"S": f"LIVE_ACTIVITY_JOB#{job_id}"},
    }


def _claim_delivery(client: Any, table_name: str, owner_id: str, job_id: str) -> str | None:
    now = int(time.time())
    claim_id = str(uuid4())
    try:
        client.put_item(
            TableName=table_name,
            Item={
                **_delivery_key(owner_id, job_id),
                "entityType": {"S": "LiveActivityDelivery"},
                "ownerId": {"S": owner_id},
                "status": {"S": "processing"},
                "claimId": {"S": claim_id},
                "leaseUntil": {"N": str(now + DELIVERY_LEASE_SECONDS)},
                "expiresAt": {"N": str(now + DELIVERY_TTL_SECONDS)},
            },
            ConditionExpression=(
                "attribute_not_exists(PK) OR (#status = :processing AND leaseUntil < :now)"
            ),
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues={
                ":processing": {"S": "processing"},
                ":now": {"N": str(now)},
            },
        )
    except Exception as error:
        if _is_conditional_failure(error):
            existing = client.get_item(
                TableName=table_name,
                Key=_delivery_key(owner_id, job_id),
                ConsistentRead=True,
            ).get("Item", {})
            if existing.get("status", {}).get("S") == "delivered":
                return None
            raise DeliveryClaimBusy("Live Activity delivery is already processing") from error
        raise
    return claim_id


def _release_delivery(
    client: Any, table_name: str, owner_id: str, job_id: str, claim_id: str
) -> None:
    try:
        client.delete_item(
            TableName=table_name,
            Key=_delivery_key(owner_id, job_id),
            ConditionExpression="claimId = :claim",
            ExpressionAttributeValues={":claim": {"S": claim_id}},
        )
    except Exception as error:
        if not _is_conditional_failure(error):
            raise


def _complete_delivery(
    client: Any, table_name: str, owner_id: str, job_id: str, claim_id: str
) -> None:
    client.update_item(
        TableName=table_name,
        Key=_delivery_key(owner_id, job_id),
        UpdateExpression=(
            "SET #status = :delivered, deliveredAt = :now REMOVE leaseUntil, claimId"
        ),
        ConditionExpression="claimId = :claim AND #status = :processing",
        ExpressionAttributeNames={"#status": "status"},
        ExpressionAttributeValues={
            ":claim": {"S": claim_id},
            ":processing": {"S": "processing"},
            ":delivered": {"S": "delivered"},
            ":now": {"N": str(int(time.time()))},
        },
    )


def _process(record: dict[str, Any]) -> None:
    message = json.loads(record["body"])
    owner_id = message["ownerId"]
    title = message["title"]
    job_id = message["jobId"]
    if not all(isinstance(value, str) and value for value in (owner_id, title, job_id)):
        raise ValueError("Live Activity message fields must be non-empty strings")

    table_name = _required_env("OPENLOOP_TABLE_NAME")
    devices = DynamoDeviceTokenStore(table_name)
    claim_id = _claim_delivery(devices.client, table_name, owner_id, job_id)
    if claim_id is None:
        # The job is durably marked delivered. Acknowledge the duplicate
        # without sending another push.
        return
    sender = FcmLiveActivitySender(
        devices=devices,
        secret_arn=_required_env("FCM_SECRET_ARN"),
        project_id=os.getenv("FCM_PROJECT_ID", "").strip() or None,
    )
    try:
        delivered = devices.live_activity_target(owner_id) is not None and (
            sender.send_completed(owner_id=owner_id, title=title, job_id=job_id)
        )
        if not delivered:
            delivered = sender.send_fallback_notification(
                owner_id=owner_id, title=title, job_id=job_id
            )
        if not delivered:
            raise RuntimeError("Live Activity and fallback notification delivery failed")
    except Exception:
        _release_delivery(devices.client, table_name, owner_id, job_id, claim_id)
        raise
    # Never release a successfully delivered claim if this state update fails;
    # keeping the lease prevents an immediate concurrent duplicate send.
    _complete_delivery(devices.client, table_name, owner_id, job_id, claim_id)


def lambda_handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    failures: list[dict[str, str]] = []
    for record in event.get("Records", []):
        try:
            _process(record)
        except Exception:
            message_id = record.get("messageId", "unknown")
            logger.exception("Live Activity delivery failed for SQS message %s", message_id)
            failures.append({"itemIdentifier": message_id})
    return {"batchItemFailures": failures}
