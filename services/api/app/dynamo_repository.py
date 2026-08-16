from __future__ import annotations

import json
from datetime import UTC, datetime
from typing import Any

from .models import LoopStatus, OpenLoop


def _iso_z(value: datetime) -> str:
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


class DynamoLoopRepository:
    """DynamoDB implementation matching ``infra/template.yaml`` keys and GSI1."""

    def __init__(self, table_name: str, client: Any | None = None) -> None:
        self.table_name = table_name
        if client is None:
            import boto3

            client = boto3.client("dynamodb")
        self.client = client

    @staticmethod
    def _pk(loop_id: str) -> str:
        return f"LOOP#{loop_id}"

    def save(self, loop: OpenLoop) -> OpenLoop:
        item: dict[str, dict[str, str]] = {
            "PK": {"S": self._pk(loop.id)},
            "SK": {"S": "METADATA"},
            "entityType": {"S": "OpenLoop"},
            "ownerId": {"S": loop.owner_id},
            "status": {"S": loop.status.value},
            "updatedAt": {"S": _iso_z(loop.updated_at)},
            "GSI1PK": {"S": f"STATUS#{loop.status.value.upper()}"},
            "GSI1SK": {"S": _iso_z(loop.updated_at)},
            "document": {"S": loop.model_dump_json()},
        }
        if loop.delete_at:
            item["expiresAt"] = {"N": str(int(loop.delete_at.timestamp()))}
        self.client.put_item(TableName=self.table_name, Item=item)
        for checkpoint in loop.checkpoints:
            checkpoint_item: dict[str, dict[str, str]] = {
                "PK": {"S": self._pk(loop.id)},
                "SK": {"S": f"CHECKPOINT#{checkpoint.id}"},
                "entityType": {"S": "Checkpoint"},
                "checkpointStatus": {"S": "dispatched" if checkpoint.completed else "open"},
                "userId": {"S": loop.owner_id},
                "notificationTitle": {"S": loop.event.title},
                "notificationBody": {"S": checkpoint.title},
                "document": {"S": checkpoint.model_dump_json()},
            }
            if not checkpoint.completed and checkpoint.due_at:
                checkpoint_item["GSI1PK"] = {"S": "CHECKPOINT#OPEN"}
                checkpoint_item["GSI1SK"] = {"S": _iso_z(checkpoint.due_at)}
            if loop.delete_at:
                checkpoint_item["expiresAt"] = {"N": str(int(loop.delete_at.timestamp()))}
            self.client.put_item(TableName=self.table_name, Item=checkpoint_item)
        return loop

    def get(self, loop_id: str) -> OpenLoop | None:
        response = self.client.get_item(
            TableName=self.table_name,
            Key={"PK": {"S": self._pk(loop_id)}, "SK": {"S": "METADATA"}},
            ConsistentRead=True,
        )
        item = response.get("Item")
        if not item:
            return None
        loop = OpenLoop.model_validate_json(item["document"]["S"])
        if loop.delete_at and loop.delete_at <= datetime.now(UTC):
            self.delete(loop_id)
            return None
        return loop

    def list(self, status: str | None = None) -> list[OpenLoop]:
        statuses = [status] if status else [candidate.value for candidate in LoopStatus]
        loops: list[OpenLoop] = []
        for candidate in statuses:
            items = self._query_all(
                TableName=self.table_name,
                IndexName="GSI1",
                KeyConditionExpression="GSI1PK = :status",
                ExpressionAttributeValues={":status": {"S": f"STATUS#{candidate.upper()}"}},
                ScanIndexForward=False,
            )
            loops.extend(OpenLoop.model_validate_json(item["document"]["S"]) for item in items)
        now = datetime.now(UTC)
        active = [loop for loop in loops if not loop.delete_at or loop.delete_at > now]
        for expired in (loop for loop in loops if loop.delete_at and loop.delete_at <= now):
            self.delete(expired.id)
        return sorted(active, key=lambda loop: loop.updated_at, reverse=True)

    def delete(self, loop_id: str) -> bool:
        pk = self._pk(loop_id)
        items = self._query_all(
            TableName=self.table_name,
            KeyConditionExpression="PK = :pk",
            ExpressionAttributeValues={":pk": {"S": pk}},
            ProjectionExpression="PK, SK",
            ConsistentRead=True,
        )
        for item in items:
            self.client.delete_item(
                TableName=self.table_name,
                Key={"PK": item["PK"], "SK": item["SK"]},
            )
        return bool(items)

    def _query_all(self, **kwargs: Any) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        while True:
            response = self.client.query(**kwargs)
            items.extend(response.get("Items", []))
            last_key = response.get("LastEvaluatedKey")
            if not last_key:
                return items
            kwargs["ExclusiveStartKey"] = last_key
