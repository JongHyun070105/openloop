import tempfile
import unittest
from os import environ
from pathlib import Path
from unittest.mock import Mock, patch

from fastapi.testclient import TestClient

from app.analyzer import DeterministicAnalysisAdapter
from app.device_tokens import DisabledDeviceTokenStore
from app.errors import ExternalIntegrationError, ExternalIntegrationTimeout
from app.main import create_app


class ApiTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        app = create_app(
            database_path=Path(self.temp_dir.name) / "api.sqlite3",
            analyzer=DeterministicAnalysisAdapter(),
        )
        self.client = TestClient(app)

    def tearDown(self) -> None:
        self.client.close()
        self.temp_dir.cleanup()

    def test_analyze_response_remains_backward_compatible(self) -> None:
        response = self.client.post("/v1/analyze", json={"text": "토요일 저녁 성수에서 만나자"})
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["status"], "needs_input")
        self.assertIn("start_time", body["event"])
        self.assertIn("missing_fields", body["event"])
        self.assertIn("resolution_note", body["event"])
        self.assertIn("suggested_question", body)

    def test_capabilities_expose_provider_state_without_configuration_values(self) -> None:
        response = self.client.get("/v1/capabilities")
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["analysis_provider"], "deterministic")
        self.assertFalse(body["analysis_enabled"])
        self.assertIsNone(body["analysis_model"])
        self.assertFalse(body["places_enabled"])
        self.assertFalse(body["weather_enabled"])
        self.assertEqual(body["push_provider"], "disabled")
        self.assertFalse(body["push_enabled"])
        serialized = response.text.lower()
        self.assertNotIn("api_key", serialized)
        self.assertNotIn("secret_arn", serialized)

    def test_full_rest_lifecycle(self) -> None:
        created_response = self.client.post(
            "/v1/loops/analyze", json={"text": "토요일 저녁 성수에서 만나자", "source": "text"}
        )
        self.assertEqual(created_response.status_code, 201)
        created = created_response.json()
        loop_id = created["id"]

        listed = self.client.get("/v1/loops", params={"status": "needs_input"}).json()
        self.assertEqual([item["id"] for item in listed], [loop_id])

        resolved_response = self.client.patch(
            f"/v1/loops/{loop_id}/ambiguity", json={"field": "start_time", "value": "19:30:00"}
        )
        self.assertEqual(resolved_response.status_code, 200)
        self.assertEqual(resolved_response.json()["status"], "open")

        action_id = resolved_response.json()["actions"][0]["id"]
        action_response = self.client.patch(
            f"/v1/loops/{loop_id}/actions/{action_id}", json={"completed": True}
        )
        self.assertTrue(action_response.json()["actions"][0]["completed"])

        completed_response = self.client.post(
            f"/v1/loops/{loop_id}/complete", json={"retention": "7_days"}
        )
        self.assertEqual(completed_response.json()["status"], "closed")
        self.assertIsNotNone(completed_response.json()["delete_at"])

        self.assertEqual(self.client.delete(f"/v1/loops/{loop_id}").status_code, 204)
        self.assertEqual(self.client.get(f"/v1/loops/{loop_id}").status_code, 404)

    def test_image_analysis_validates_upload_and_uses_companion_text_fallback(self) -> None:
        response = self.client.post(
            "/v1/analyze/image",
            files={"file": ("capture.png", b"not-decoded-by-api", "image/png")},
            data={"companion_text": "토요일 저녁 성수에서 만나자", "source": "screenshot"},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "needs_input")
        self.assertEqual(response.json()["event"]["source"], "screenshot")

        unsupported = self.client.post(
            "/v1/analyze/image", files={"file": ("capture.txt", b"text", "text/plain")}
        )
        self.assertEqual(unsupported.status_code, 415)

        empty = self.client.post(
            "/v1/analyze/image", files={"file": ("capture.png", b"", "image/png")}
        )
        self.assertEqual(empty.status_code, 400)

    def test_image_analysis_can_create_and_persist_deadline_loop(self) -> None:
        response = self.client.post(
            "/v1/loops/analyze/image",
            files={"file": ("deadline.png", b"image-content", "image/png")},
            data={
                "companion_text": "AI 공모전 접수 마감 8월 22일 23:59",
                "source": "screenshot",
            },
        )

        self.assertEqual(response.status_code, 201)
        loop = response.json()
        self.assertEqual(loop["event"]["source"], "screenshot")
        self.assertEqual(loop["event"]["type"], "deadline")
        self.assertEqual(len(loop["checklist"]), 2)
        self.assertEqual(len(loop["checkpoints"]), 3)
        persisted = self.client.get(f"/v1/loops/{loop['id']}")
        self.assertEqual(persisted.status_code, 200)
        self.assertEqual(persisted.json()["id"], loop["id"])

    def test_dynamodb_is_selected_only_when_table_environment_is_present(self) -> None:
        repository = Mock()
        with patch.dict(environ, {"OPENLOOP_TABLE_NAME": "openloop-test"}, clear=False):
            with patch("app.main.DynamoLoopRepository", return_value=repository) as repository_class:
                app = create_app(
                    analyzer=DeterministicAnalysisAdapter(),
                    device_token_store=DisabledDeviceTokenStore(),
                )

        repository_class.assert_called_once_with("openloop-test")
        self.assertIs(app.state.repository, repository)

    def test_loop_access_is_scoped_to_installation_header(self) -> None:
        owner = "11111111-1111-4111-8111-111111111111"
        other = "22222222-2222-4222-8222-222222222222"
        created = self.client.post(
            "/v1/loops/analyze",
            headers={"X-OpenLoop-Install-Id": owner},
            json={"text": "토요일 저녁 성수에서 만나자"},
        ).json()

        self.assertEqual(created["owner_id"], owner)
        self.assertEqual(
            self.client.get(
                f"/v1/loops/{created['id']}", headers={"X-OpenLoop-Install-Id": other}
            ).status_code,
            403,
        )
        listed = self.client.get("/v1/loops", headers={"X-OpenLoop-Install-Id": other})
        self.assertEqual(listed.json(), [])

    def test_disabled_context_and_push_providers_are_explicit_noops(self) -> None:
        self.assertEqual(self.client.get("/v1/places/search", params={"q": "성수"}).json(), [])
        weather = self.client.get(
            "/v1/weather", params={"lat": 37.5665, "lon": 126.978}
        ).json()
        self.assertFalse(weather["available"])
        self.assertEqual(weather["provider"], "disabled")

        payload = {
            "token": "a-fcm-token-that-is-at-least-twenty-characters",
            "platform": "android",
        }
        headers = {"X-OpenLoop-Install-Id": "11111111-1111-4111-8111-111111111111"}
        registered = self.client.post("/v1/devices/push-token", json=payload, headers=headers)
        self.assertEqual(registered.json(), {"registered": False, "provider": "disabled"})
        unregistered = self.client.request(
            "DELETE", "/v1/devices/push-token", json=payload, headers=headers
        )
        self.assertEqual(unregistered.json(), {"registered": False, "provider": "disabled"})

    def test_installation_header_is_validated_and_can_be_required(self) -> None:
        invalid = self.client.get(
            "/v1/loops", headers={"X-OpenLoop-Install-Id": "not-a-uuid"}
        )
        self.assertEqual(invalid.status_code, 422)

        with tempfile.TemporaryDirectory() as directory:
            with patch.dict(environ, {"OPENLOOP_REQUIRE_INSTALL_ID": "true"}, clear=False):
                required_client = TestClient(
                    create_app(
                        database_path=Path(directory) / "required.sqlite3",
                        analyzer=DeterministicAnalysisAdapter(),
                    )
                )
                missing = required_client.get("/v1/loops")
                self.assertEqual(missing.status_code, 422)
                required_client.close()

    def test_external_errors_return_safe_gateway_statuses(self) -> None:
        class FailingPlace:
            provider = "kakao"

            def search(self, *_args, **_kwargs):  # type: ignore[no-untyped-def]
                raise ExternalIntegrationError("secret provider detail")

        class TimeoutPlace:
            provider = "kakao"

            def search(self, *_args, **_kwargs):  # type: ignore[no-untyped-def]
                raise ExternalIntegrationTimeout("secret provider timeout")

        with tempfile.TemporaryDirectory() as directory:
            failing = TestClient(
                create_app(
                    database_path=Path(directory) / "failure.sqlite3",
                    analyzer=DeterministicAnalysisAdapter(),
                    place_adapter=FailingPlace(),
                )
            )
            failed = failing.get("/v1/places/search", params={"q": "private query"})
            self.assertEqual(failed.status_code, 502)
            self.assertEqual(failed.json(), {"detail": "External provider unavailable"})
            failing.close()

            timing_out = TestClient(
                create_app(
                    database_path=Path(directory) / "timeout.sqlite3",
                    analyzer=DeterministicAnalysisAdapter(),
                    place_adapter=TimeoutPlace(),
                )
            )
            timed_out = timing_out.get("/v1/places/search", params={"q": "private query"})
            self.assertEqual(timed_out.status_code, 504)
            self.assertEqual(timed_out.json(), {"detail": "External provider timed out"})
            timing_out.close()


if __name__ == "__main__":
    unittest.main()
