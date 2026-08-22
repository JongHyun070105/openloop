import json
import unittest
from unittest.mock import Mock, patch

from app import live_activity_worker


class ConditionalFailure(Exception):
    response = {"Error": {"Code": "ConditionalCheckFailedException"}}


class LiveActivityWorkerTests(unittest.TestCase):
    def test_delivers_each_valid_message_and_reports_only_failures(self) -> None:
        event = {
            "Records": [
                {"messageId": "ok", "body": json.dumps({"ownerId": "owner", "title": "일정", "jobId": "job"})},
                {"messageId": "bad", "body": "{}"},
            ]
        }
        with patch.object(live_activity_worker, "_process") as process:
            process.side_effect = [None, ValueError("bad")]
            result = live_activity_worker.lambda_handler(event, None)

        self.assertEqual(result, {"batchItemFailures": [{"itemIdentifier": "bad"}]})
        self.assertEqual(process.call_count, 2)

    @patch.dict(
        "os.environ",
        {"OPENLOOP_TABLE_NAME": "table", "FCM_SECRET_ARN": "secret"},
        clear=True,
    )
    @patch("app.live_activity_worker.FcmLiveActivitySender")
    @patch("app.live_activity_worker.DynamoDeviceTokenStore")
    def test_process_sends_completed_activity_without_duplicate_fallback(
        self, store_type: Mock, sender_type: Mock
    ) -> None:
        store = store_type.return_value
        store.live_activity_target.return_value = ("fcm", "activity")
        sender_type.return_value.send_completed.return_value = True

        live_activity_worker._process(
            {
                "body": json.dumps(
                    {"ownerId": "owner", "title": "저녁 약속", "jobId": "job"}
                )
            }
        )

        sender_type.return_value.send_completed.assert_called_once_with(
            owner_id="owner", title="저녁 약속", job_id="job"
        )
        sender_type.return_value.send_fallback_notification.assert_not_called()
        self.assertEqual(
            store.client.put_item.call_args.kwargs["Item"]["PK"],
            {"S": "USER#owner"},
        )
        self.assertEqual(
            store.client.put_item.call_args.kwargs["Item"]["SK"],
            {"S": "LIVE_ACTIVITY_JOB#job"},
        )
        store.client.update_item.assert_called_once()
        self.assertEqual(
            store.client.update_item.call_args.kwargs["ExpressionAttributeValues"][
                ":delivered"
            ],
            {"S": "delivered"},
        )

    @patch.dict(
        "os.environ",
        {"OPENLOOP_TABLE_NAME": "table", "FCM_SECRET_ARN": "secret"},
        clear=True,
    )
    @patch("app.live_activity_worker.FcmLiveActivitySender")
    @patch("app.live_activity_worker.DynamoDeviceTokenStore")
    def test_process_acknowledges_delivered_duplicate_without_sending(
        self, store_type: Mock, sender_type: Mock
    ) -> None:
        client = store_type.return_value.client
        client.put_item.side_effect = ConditionalFailure()
        client.get_item.return_value = {"Item": {"status": {"S": "delivered"}}}

        live_activity_worker._process(
            {"body": json.dumps({"ownerId": "owner", "title": "일정", "jobId": "job"})}
        )

        sender_type.assert_not_called()

    @patch.dict(
        "os.environ",
        {"OPENLOOP_TABLE_NAME": "table", "FCM_SECRET_ARN": "secret"},
        clear=True,
    )
    @patch("app.live_activity_worker.FcmLiveActivitySender")
    @patch("app.live_activity_worker.DynamoDeviceTokenStore")
    def test_process_retries_while_another_claim_lease_is_active(
        self, store_type: Mock, sender_type: Mock
    ) -> None:
        client = store_type.return_value.client
        client.put_item.side_effect = ConditionalFailure()
        client.get_item.return_value = {"Item": {"status": {"S": "processing"}}}

        with self.assertRaises(live_activity_worker.DeliveryClaimBusy):
            live_activity_worker._process(
                {
                    "body": json.dumps(
                        {"ownerId": "owner", "title": "일정", "jobId": "job"}
                    )
                }
            )

        sender_type.assert_not_called()

    @patch.dict(
        "os.environ",
        {"OPENLOOP_TABLE_NAME": "table", "FCM_SECRET_ARN": "secret"},
        clear=True,
    )
    @patch("app.live_activity_worker.DynamoDeviceTokenStore")
    @patch("app.live_activity_worker.FcmLiveActivitySender")
    def test_process_falls_back_when_live_activity_is_unavailable(
        self, sender_type: Mock, store_type: Mock
    ) -> None:
        store_type.return_value.live_activity_target.return_value = None
        sender_type.return_value.send_fallback_notification.return_value = True
        live_activity_worker._process(
            {"body": json.dumps({"ownerId": "owner", "title": "일정", "jobId": "job"})}
        )
        sender_type.return_value.send_completed.assert_not_called()
        sender_type.return_value.send_fallback_notification.assert_called_once_with(
            owner_id="owner", title="일정", job_id="job"
        )

    @patch.dict(
        "os.environ",
        {"OPENLOOP_TABLE_NAME": "table", "FCM_SECRET_ARN": "secret"},
        clear=True,
    )
    @patch("app.live_activity_worker.FcmLiveActivitySender")
    @patch("app.live_activity_worker.DynamoDeviceTokenStore")
    def test_process_falls_back_when_live_activity_send_fails(
        self, store_type: Mock, sender_type: Mock
    ) -> None:
        store_type.return_value.live_activity_target.return_value = ("fcm", "activity")
        sender_type.return_value.send_completed.return_value = False
        sender_type.return_value.send_fallback_notification.return_value = True

        live_activity_worker._process(
            {"body": json.dumps({"ownerId": "owner", "title": "일정", "jobId": "job"})}
        )

        sender_type.return_value.send_fallback_notification.assert_called_once()

    @patch.dict(
        "os.environ",
        {"OPENLOOP_TABLE_NAME": "table", "FCM_SECRET_ARN": "secret"},
        clear=True,
    )
    @patch("app.live_activity_worker.FcmLiveActivitySender")
    @patch("app.live_activity_worker.DynamoDeviceTokenStore")
    def test_process_releases_claim_when_both_delivery_paths_fail(
        self, store_type: Mock, sender_type: Mock
    ) -> None:
        store = store_type.return_value
        store.live_activity_target.return_value = ("fcm", "activity")
        sender_type.return_value.send_completed.return_value = False
        sender_type.return_value.send_fallback_notification.return_value = False

        with self.assertRaisesRegex(RuntimeError, "fallback notification"):
            live_activity_worker._process(
                {
                    "body": json.dumps(
                        {"ownerId": "owner", "title": "일정", "jobId": "job"}
                    )
                }
            )

        store.client.delete_item.assert_called_once()
        store.client.update_item.assert_not_called()


if __name__ == "__main__":
    unittest.main()
