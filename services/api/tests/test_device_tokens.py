import hashlib
import unittest
from unittest.mock import Mock

from app.device_tokens import DynamoDeviceTokenStore
from app.models import PushTokenRequest


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


if __name__ == "__main__":
    unittest.main()
