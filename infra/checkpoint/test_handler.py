import json
import os
import unittest
from unittest.mock import Mock, patch

import handler


class CheckpointDispatcherTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dynamodb = Mock()
        self.sqs = Mock()
        handler._dynamodb = self.dynamodb
        handler._sqs = self.sqs

    def tearDown(self) -> None:
        handler._dynamodb = None
        handler._sqs = None

    @patch.dict(
        os.environ,
        {
            "OPENLOOP_TABLE_NAME": "openloop-test",
            "CHECKPOINT_QUEUE_URL": "https://sqs.test/checkpoints.fifo",
            "CHECKPOINT_BATCH_SIZE": "10",
        },
        clear=True,
    )
    def test_dispatches_due_checkpoint_and_removes_due_index(self) -> None:
        self.dynamodb.query.return_value = {
            "Items": [
                {
                    "PK": {"S": "LOOP#123"},
                    "SK": {"S": "CHECKPOINT#456"},
                    "GSI1PK": {"S": "CHECKPOINT#OPEN"},
                    "GSI1SK": {"S": "2026-08-16T03:00:00Z"},
                }
            ]
        }

        result = handler.lambda_handler({"source": "test"}, None)

        self.assertEqual(result["dispatched"], 1)
        self.assertFalse(result["hasMore"])
        message = self.sqs.send_message.call_args.kwargs
        self.assertEqual(message["MessageGroupId"], "openloop-checkpoints")
        self.assertEqual(json.loads(message["MessageBody"])["pk"], "LOOP#123")
        update = self.dynamodb.update_item.call_args.kwargs
        self.assertIn("REMOVE GSI1PK, GSI1SK", update["UpdateExpression"])
        self.assertEqual(update["ConditionExpression"], "GSI1PK = :open")

    @patch.dict(
        os.environ,
        {
            "OPENLOOP_TABLE_NAME": "openloop-test",
            "CHECKPOINT_QUEUE_URL": "https://sqs.test/checkpoints.fifo",
        },
        clear=True,
    )
    def test_empty_query_is_a_successful_noop(self) -> None:
        self.dynamodb.query.return_value = {"Items": []}

        result = handler.lambda_handler({}, None)

        self.assertEqual(result["dispatched"], 0)
        self.sqs.send_message.assert_not_called()
        self.dynamodb.update_item.assert_not_called()

    @patch.dict(os.environ, {}, clear=True)
    def test_missing_configuration_fails_closed(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "OPENLOOP_TABLE_NAME"):
            handler.lambda_handler({}, None)


if __name__ == "__main__":
    unittest.main()
