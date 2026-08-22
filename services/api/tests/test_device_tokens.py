import hashlib
import unittest
from unittest.mock import Mock

from app.device_tokens import DynamoDeviceTokenStore
from app.models import LiveActivityTokenRequest, PushTokenRequest


class DeviceTokenTests(unittest.TestCase):
    def setUp(self) -> None:
        self.client = Mock()
        self.store = DynamoDeviceTokenStore("openloop-test", client=self.client)
        self.request = PushTokenRequest(
            token="a-sensitive-fcm-token-at-least-twenty-chars",
            platform="android",
        )
        self.owner_id = "11111111-1111-4111-8111-111111111111"

    def test_registers_token_in_installation_scoped_partition(self) -> None:
        result = self.store.register(self.request, self.owner_id)

        self.assertTrue(result.registered)
        item = self.client.put_item.call_args.kwargs["Item"]
        token_hash = hashlib.sha256(self.request.token.encode()).hexdigest()
        self.assertEqual(item["PK"], {"S": f"USER#{self.owner_id}"})
        self.assertEqual(item["SK"], {"S": f"DEVICE#{token_hash}"})
        self.assertEqual(item["fcmToken"], {"S": self.request.token})
        self.assertEqual(item["active"], {"BOOL": True})

    def test_unregister_disables_without_echoing_token(self) -> None:
        result = self.store.unregister(self.request, self.owner_id)

        self.assertFalse(result.registered)
        update = self.client.update_item.call_args.kwargs
        self.assertEqual(update["ExpressionAttributeValues"][":inactive"], {"BOOL": False})
        self.assertNotIn(self.request.token, str(result.model_dump()))

    def test_same_token_is_isolated_by_owner_partition(self) -> None:
        self.store.register(self.request, self.owner_id)
        first = self.client.put_item.call_args.kwargs["Item"]
        other_owner = "22222222-2222-4222-8222-222222222222"
        self.store.register(self.request, other_owner)
        second = self.client.put_item.call_args.kwargs["Item"]

        self.assertNotEqual(first["PK"], second["PK"])
        self.assertEqual(first["SK"], second["SK"])

    def test_registers_and_pairs_live_activity_with_latest_ios_device(self) -> None:
        live_request = LiveActivityTokenRequest(
            token="activity-push-to-start-token-at-least-twenty-chars"
        )
        result = self.store.register_live_activity(live_request, self.owner_id)

        self.assertTrue(result.registered)
        item = self.client.put_item.call_args.kwargs["Item"]
        self.assertEqual(item["SK"], {"S": "LIVE_ACTIVITY#PUSH_TO_START"})
        self.assertEqual(item["pushToStartToken"], {"S": live_request.token})

        self.client.query.return_value = {
            "Items": [
                item,
                {
                    "entityType": {"S": "PushDevice"},
                    "fcmToken": {"S": "older-ios-fcm-token-value"},
                    "platform": {"S": "ios"},
                    "active": {"BOOL": True},
                    "updatedAt": {"S": "2026-08-19T00:00:00+00:00"},
                },
                {
                    "entityType": {"S": "PushDevice"},
                    "fcmToken": {"S": "newer-ios-fcm-token-value"},
                    "platform": {"S": "ios"},
                    "active": {"BOOL": True},
                    "updatedAt": {"S": "2026-08-20T00:00:00+00:00"},
                },
            ]
        }

        self.assertEqual(
            self.store.live_activity_target(self.owner_id),
            ("newer-ios-fcm-token-value", live_request.token),
        )
        self.assertEqual(
            self.store.latest_ios_fcm_token(self.owner_id),
            "newer-ios-fcm-token-value",
        )


if __name__ == "__main__":
    unittest.main()
