import json
import unittest
from unittest.mock import Mock, patch

from app.live_activity import FcmLiveActivitySender, SqsLiveActivitySender


class LiveActivitySenderTests(unittest.TestCase):
    def test_sqs_sender_accepts_after_queue_ack_without_calling_fcm(self) -> None:
        devices = Mock()
        devices.live_activity_target.return_value = ("fcm-token", "activity-token")
        sqs = Mock()
        sender = SqsLiveActivitySender(devices, "https://sqs.example/queue", sqs)

        accepted = sender.send_completed("install-id", "  저녁 약속  ", "job-id")

        self.assertTrue(accepted)
        body = json.loads(sqs.send_message.call_args.kwargs["MessageBody"])
        self.assertEqual(
            body,
            {"ownerId": "install-id", "title": "저녁 약속", "jobId": "job-id"},
        )

    def test_sqs_sender_falls_back_when_target_or_queue_ack_is_missing(self) -> None:
        devices = Mock()
        devices.live_activity_target.return_value = None
        sqs = Mock()
        sender = SqsLiveActivitySender(devices, "https://sqs.example/queue", sqs)
        self.assertFalse(sender.send_completed("install-id", "일정", "job-id"))
        sqs.send_message.assert_not_called()

        devices.live_activity_target.return_value = ("fcm-token", "activity-token")
        sqs.send_message.side_effect = RuntimeError("unavailable")
        self.assertFalse(sender.send_completed("install-id", "일정", "job-id"))

    def test_sends_privacy_bounded_completed_activity_through_fcm(self) -> None:
        devices = Mock()
        devices.live_activity_target.return_value = (
            "fcm-registration-token",
            "push-to-start-token",
        )
        secrets = Mock()
        secrets.get_secret_value.return_value = {
            "SecretString": json.dumps({"project_id": "openloop-project"})
        }
        http = Mock()
        http.post.return_value.status_code = 200
        sender = FcmLiveActivitySender(
            devices=devices,
            secret_arn="arn:aws:secretsmanager:test",
            secrets_client=secrets,
            http_client=http,
        )

        with patch.object(sender, "_oauth_token", return_value="oauth-token"):
            accepted = sender.send_completed(
                owner_id="install-id",
                title="저녁 약속",
                job_id="job-id",
            )

        self.assertTrue(accepted)
        request = http.post.call_args.kwargs
        message = request["json"]["message"]
        self.assertEqual(message["token"], "fcm-registration-token")
        self.assertEqual(message["apns"]["live_activity_token"], "push-to-start-token")
        self.assertEqual(message["apns"]["headers"]["apns-collapse-id"], "job-id")
        aps = message["apns"]["payload"]["aps"]
        self.assertEqual(aps["event"], "start")
        self.assertEqual(aps["content-state"]["phase"], "completed")
        self.assertEqual(aps["content-state"]["title"], "저녁 약속")
        self.assertEqual(aps["attributes"], {"jobId": "job-id"})
        self.assertNotIn("image", str(message).lower())
        self.assertNotIn("participant", str(message).lower())

    def test_missing_token_pair_falls_back_without_loading_secret(self) -> None:
        devices = Mock()
        devices.live_activity_target.return_value = None
        secrets = Mock()
        sender = FcmLiveActivitySender(
            devices=devices,
            secret_arn="arn:aws:secretsmanager:test",
            secrets_client=secrets,
            http_client=Mock(),
        )

        self.assertFalse(sender.send_completed("install-id", "일정", "job-id"))
        secrets.get_secret_value.assert_not_called()

    def test_sends_ordinary_completion_notification_as_fallback(self) -> None:
        devices = Mock()
        devices.latest_ios_fcm_token.return_value = "fcm-registration-token"
        secrets = Mock()
        secrets.get_secret_value.return_value = {
            "SecretString": json.dumps({"project_id": "openloop-project"})
        }
        http = Mock()
        http.post.return_value.status_code = 200
        sender = FcmLiveActivitySender(
            devices=devices,
            secret_arn="arn:aws:secretsmanager:test",
            secrets_client=secrets,
            http_client=http,
        )

        with patch.object(sender, "_oauth_token", return_value="oauth-token"):
            sent = sender.send_fallback_notification("install-id", "저녁 약속", "job-id")

        self.assertTrue(sent)
        message = http.post.call_args.kwargs["json"]["message"]
        self.assertEqual(message["token"], "fcm-registration-token")
        self.assertEqual(
            message["data"],
            {
                "type": "analysis.completed",
                "job_id": "job-id",
                "payload": "draft:job-id",
            },
        )
        self.assertEqual(message["apns"]["headers"]["apns-collapse-id"], "job-id")
        self.assertNotIn("live_activity_token", str(message))


if __name__ == "__main__":
    unittest.main()
