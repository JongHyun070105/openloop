import json
import os
import unittest
from unittest.mock import Mock, patch

import handler


def _record(message_id="message-1"):
    return {
        "messageId": message_id,
        "body": json.dumps(
            {
                "pk": "LOOP#123",
                "sk": "CHECKPOINT#456",
                "dueAt": "2026-08-16T03:00:00Z",
            }
        ),
    }


class CheckpointWorkerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dynamodb = Mock()
        handler._dynamodb = self.dynamodb
        handler._secrets = Mock()
        handler._fcm_secret = {"project_id": "firebase-project"}
        handler._credentials = None

    def tearDown(self) -> None:
        handler._dynamodb = None
        handler._secrets = None
        handler._fcm_secret = None
        handler._credentials = None

    @patch.dict(
        os.environ,
        {
            "OPENLOOP_TABLE_NAME": "openloop-test",
            "FCM_SECRET_ARN": "arn:aws:secretsmanager:test",
        },
        clear=True,
    )
    @patch.object(handler, "_send", return_value=(200, {"name": "message-id"}))
    def test_sends_notification_to_active_device(self, send: Mock) -> None:
        self.dynamodb.get_item.return_value = {
            "Item": {
                "PK": {"S": "LOOP#123"},
                "SK": {"S": "CHECKPOINT#456"},
                "userId": {"S": "user-1"},
                "notificationTitle": {"S": "출발할 시간이에요"},
                "notificationBody": {"S": "지금 출발하면 늦지 않아요."},
            }
        }
        self.dynamodb.query.return_value = {
            "Items": [
                {
                    "PK": {"S": "USER#user-1"},
                    "SK": {"S": "DEVICE#abc"},
                    "fcmToken": {"S": "token-1"},
                    "platform": {"S": "ios"},
                }
            ]
        }

        result = handler.lambda_handler({"Records": [_record()]}, None)

        self.assertEqual(result, {"batchItemFailures": []})
        payload = send.call_args.args[1]
        self.assertEqual(payload["message"]["token"], "token-1")
        self.assertEqual(payload["message"]["apns"]["payload"]["aps"]["sound"], "default")
        self.assertEqual(
            payload["message"]["data"],
            {
                "type": "checkpoint.due",
                "loop_id": "123",
                "checkpoint_id": "456",
                "due_at": "2026-08-16T03:00:00Z",
            },
        )
        self.assertEqual(
            self.dynamodb.update_item.call_args.kwargs["ExpressionAttributeValues"][":status"],
            {"S": "sent"},
        )

    @patch.dict(
        os.environ,
        {
            "OPENLOOP_TABLE_NAME": "openloop-test",
            "FCM_SECRET_ARN": "arn:aws:secretsmanager:test",
        },
        clear=True,
    )
    @patch.object(
        handler,
        "_send",
        return_value=(404, {"error": {"status": "UNREGISTERED"}}),
    )
    def test_disables_unregistered_token(self, _send: Mock) -> None:
        self.dynamodb.get_item.return_value = {
            "Item": {
                "userId": {"S": "user-1"},
            }
        }
        self.dynamodb.query.return_value = {
            "Items": [
                {
                    "PK": {"S": "USER#user-1"},
                    "SK": {"S": "DEVICE#abc"},
                    "fcmToken": {"S": "expired-token"},
                }
            ]
        }

        result = handler.lambda_handler({"Records": [_record()]}, None)

        self.assertEqual(result, {"batchItemFailures": []})
        first_update = self.dynamodb.update_item.call_args_list[0].kwargs
        self.assertEqual(first_update["Key"]["SK"], {"S": "DEVICE#abc"})
        self.assertEqual(
            first_update["ExpressionAttributeValues"][":reason"],
            {"S": "fcm_invalid_token"},
        )

    def test_invalid_argument_detail_is_an_invalid_token(self) -> None:
        self.assertTrue(
            handler._is_invalid_token(
                400,
                {
                    "error": {
                        "status": "INVALID_ARGUMENT",
                        "details": [{"errorCode": "INVALID_ARGUMENT"}],
                    }
                },
            )
        )
        self.assertFalse(
            handler._is_invalid_token(400, {"error": {"status": "INVALID_ARGUMENT"}})
        )

    @patch.dict(
        os.environ,
        {
            "OPENLOOP_TABLE_NAME": "openloop-test",
            "FCM_SECRET_ARN": "arn:aws:secretsmanager:test",
        },
        clear=True,
    )
    @patch.object(handler, "_process", side_effect=RuntimeError("transient"))
    @patch.object(handler.logger, "exception")
    def test_fifo_failure_returns_current_and_remaining_records(
        self, log_exception: Mock, _process: Mock
    ) -> None:
        result = handler.lambda_handler(
            {"Records": [_record("one"), _record("two")]}, None
        )

        self.assertEqual(
            result,
            {"batchItemFailures": [{"itemIdentifier": "one"}, {"itemIdentifier": "two"}]},
        )
        log_exception.assert_called_once()


if __name__ == "__main__":
    unittest.main()
