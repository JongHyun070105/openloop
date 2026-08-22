import hashlib
import os
from datetime import UTC, datetime
from typing import Any, Protocol

from .models import LiveActivityTokenRequest, PushTokenRequest, PushTokenResponse


class DeviceTokenStore(Protocol):
    provider: str

    def register(self, request: PushTokenRequest, owner_id: str) -> PushTokenResponse: ...

    def unregister(self, request: PushTokenRequest, owner_id: str) -> PushTokenResponse: ...

    def register_live_activity(
        self, request: LiveActivityTokenRequest, owner_id: str
    ) -> PushTokenResponse: ...

    def live_activity_target(self, owner_id: str) -> tuple[str, str] | None: ...

    def latest_ios_fcm_token(self, owner_id: str) -> str | None: ...


class DisabledDeviceTokenStore:
    provider = "disabled"

    def register(self, request: PushTokenRequest, owner_id: str) -> PushTokenResponse:
        del request, owner_id
        return PushTokenResponse(registered=False, provider="disabled")

    def unregister(self, request: PushTokenRequest, owner_id: str) -> PushTokenResponse:
        del request, owner_id
        return PushTokenResponse(registered=False, provider="disabled")

    def register_live_activity(
        self, request: LiveActivityTokenRequest, owner_id: str
    ) -> PushTokenResponse:
        del request, owner_id
        return PushTokenResponse(registered=False, provider="disabled")

    def live_activity_target(self, owner_id: str) -> tuple[str, str] | None:
        del owner_id
        return None

    def latest_ios_fcm_token(self, owner_id: str) -> str | None:
        del owner_id
        return None


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

    def register_live_activity(
        self, request: LiveActivityTokenRequest, owner_id: str
    ) -> PushTokenResponse:
        self.client.put_item(
            TableName=self.table_name,
            Item={
                "PK": {"S": f"USER#{owner_id}"},
                "SK": {"S": "LIVE_ACTIVITY#PUSH_TO_START"},
                "entityType": {"S": "LiveActivityToken"},
                "pushToStartToken": {"S": request.token},
                "active": {"BOOL": True},
                "updatedAt": {"S": datetime.now(UTC).isoformat()},
            },
        )
        return PushTokenResponse(registered=True, provider="dynamodb")

    def live_activity_target(self, owner_id: str) -> tuple[str, str] | None:
        fcm_token, live_token = self._live_activity_tokens(owner_id)
        if not live_token or not fcm_token:
            return None
        return fcm_token, live_token

    def latest_ios_fcm_token(self, owner_id: str) -> str | None:
        fcm_token, _live_token = self._live_activity_tokens(owner_id)
        return fcm_token

    def _live_activity_tokens(self, owner_id: str) -> tuple[str | None, str | None]:
        response = self.client.query(
            TableName=self.table_name,
            KeyConditionExpression="PK = :pk",
            ExpressionAttributeValues={":pk": {"S": f"USER#{owner_id}"}},
            ConsistentRead=True,
        )
        items = response.get("Items", [])
        live_token: str | None = None
        ios_devices: list[tuple[str, str]] = []
        for item in items:
            if item.get("active", {}).get("BOOL") is not True:
                continue
            if item.get("entityType", {}).get("S") == "LiveActivityToken":
                live_token = item.get("pushToStartToken", {}).get("S")
            elif (
                item.get("entityType", {}).get("S") == "PushDevice"
                and item.get("platform", {}).get("S") == "ios"
            ):
                token = item.get("fcmToken", {}).get("S")
                updated_at = item.get("updatedAt", {}).get("S", "")
                if token:
                    ios_devices.append((updated_at, token))
        if not ios_devices:
            return None, live_token
        ios_devices.sort(reverse=True)
        return ios_devices[0][1], live_token


def device_token_store_from_env() -> DeviceTokenStore:
    table_name = os.getenv("OPENLOOP_TABLE_NAME")
    if not table_name:
        return DisabledDeviceTokenStore()
    return DynamoDeviceTokenStore(table_name)
