import hashlib
import os
from datetime import UTC, datetime
from typing import Any, Protocol

from .models import PushTokenRequest, PushTokenResponse


class DeviceTokenStore(Protocol):
    provider: str

    def register(self, request: PushTokenRequest, owner_id: str) -> PushTokenResponse: ...

    def unregister(self, request: PushTokenRequest, owner_id: str) -> PushTokenResponse: ...


class DisabledDeviceTokenStore:
    provider = "disabled"

    def register(self, request: PushTokenRequest, owner_id: str) -> PushTokenResponse:
        del request, owner_id
        return PushTokenResponse(registered=False, provider="disabled")

    def unregister(self, request: PushTokenRequest, owner_id: str) -> PushTokenResponse:
        del request, owner_id
        return PushTokenResponse(registered=False, provider="disabled")


class DynamoDeviceTokenStore:
    """Installation-scoped token storage protected by the table's DynamoDB SSE."""

    provider = "dynamodb"

    def __init__(self, table_name: str, client: Any | None = None) -> None:
        self.table_name = table_name
        if client is None:
            import boto3

            client = boto3.client("dynamodb")
        self.client = client

    @staticmethod
    def _key(request: PushTokenRequest, owner_id: str) -> dict[str, dict[str, str]]:
        token_hash = hashlib.sha256(request.token.encode("utf-8")).hexdigest()
        return {
            "PK": {"S": f"USER#{owner_id}"},
            "SK": {"S": f"DEVICE#{token_hash}"},
        }

    def register(self, request: PushTokenRequest, owner_id: str) -> PushTokenResponse:
        item: dict[str, Any] = {
            **self._key(request, owner_id),
            "entityType": {"S": "PushDevice"},
            "fcmToken": {"S": request.token},
            "platform": {"S": request.platform},
            "active": {"BOOL": True},
            "updatedAt": {"S": datetime.now(UTC).isoformat()},
        }
        self.client.put_item(TableName=self.table_name, Item=item)
        return PushTokenResponse(registered=True, provider="dynamodb")

    def unregister(self, request: PushTokenRequest, owner_id: str) -> PushTokenResponse:
        self.client.update_item(
            TableName=self.table_name,
            Key=self._key(request, owner_id),
            UpdateExpression="SET active = :inactive, updatedAt = :updated",
            ExpressionAttributeValues={
                ":inactive": {"BOOL": False},
                ":updated": {"S": datetime.now(UTC).isoformat()},
            },
        )
        return PushTokenResponse(registered=False, provider="dynamodb")


def device_token_store_from_env() -> DeviceTokenStore:
    table_name = os.getenv("OPENLOOP_TABLE_NAME")
    if not table_name:
        return DisabledDeviceTokenStore()
    return DynamoDeviceTokenStore(table_name)
