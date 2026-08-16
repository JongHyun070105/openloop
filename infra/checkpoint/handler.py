"""Dispatch due OpenLoop checkpoints without running an always-on worker."""

from __future__ import annotations

import hashlib
import json
import os
from datetime import UTC, datetime
from typing import Any

_dynamodb: Any = None
_sqs: Any = None


def _client(service: str) -> Any:
    global _dynamodb, _sqs
    if service == "dynamodb":
        if _dynamodb is None:
            import boto3

            _dynamodb = boto3.client("dynamodb")
        return _dynamodb
    if _sqs is None:
        import boto3

        _sqs = boto3.client("sqs")
    return _sqs


def _required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def _string(item: dict[str, Any], name: str) -> str:
    value = item.get(name, {}).get("S")
    if not value:
        raise ValueError(f"Checkpoint item is missing string attribute {name}")
    return value


def _message(item: dict[str, Any]) -> tuple[str, str]:
    payload = {
        "type": "checkpoint.due",
        "pk": _string(item, "PK"),
        "sk": _string(item, "SK"),
        "dueAt": _string(item, "GSI1SK"),
    }
    body = json.dumps(payload, separators=(",", ":"), sort_keys=True)
    deduplication_id = hashlib.sha256(body.encode("utf-8")).hexdigest()
    return body, deduplication_id


def lambda_handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    table_name = _required_env("OPENLOOP_TABLE_NAME")
    queue_url = _required_env("CHECKPOINT_QUEUE_URL")
    batch_size = max(1, min(int(os.environ.get("CHECKPOINT_BATCH_SIZE", "25")), 100))
    now = datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")

    dynamodb = _client("dynamodb")
    sqs = _client("sqs")
    response = dynamodb.query(
        TableName=table_name,
        IndexName="GSI1",
        KeyConditionExpression="GSI1PK = :open AND GSI1SK <= :now",
        ExpressionAttributeValues={
            ":open": {"S": "CHECKPOINT#OPEN"},
            ":now": {"S": now},
        },
        Limit=batch_size,
        ScanIndexForward=True,
        ConsistentRead=False,
    )

    dispatched = 0
    for item in response.get("Items", []):
        pk = _string(item, "PK")
        sk = _string(item, "SK")
        body, deduplication_id = _message(item)
        sqs.send_message(
            QueueUrl=queue_url,
            MessageBody=body,
            MessageGroupId="openloop-checkpoints",
            MessageDeduplicationId=deduplication_id,
        )
        dynamodb.update_item(
            TableName=table_name,
            Key={"PK": {"S": pk}, "SK": {"S": sk}},
            UpdateExpression=(
                "SET checkpointStatus = :dispatched, dispatchedAt = :now "
                "REMOVE GSI1PK, GSI1SK"
            ),
            ConditionExpression="GSI1PK = :open",
            ExpressionAttributeValues={
                ":open": {"S": "CHECKPOINT#OPEN"},
                ":dispatched": {"S": "dispatched"},
                ":now": {"S": now},
            },
        )
        dispatched += 1

    return {
        "status": "ok",
        "dispatched": dispatched,
        "hasMore": "LastEvaluatedKey" in response,
        "source": event.get("source", "unknown"),
    }
