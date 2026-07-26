import json
import os
import tempfile
import time
import unittest
from pathlib import Path

from fastapi.testclient import TestClient

from software.webapp.main import STATIC_DIR, app


def manual_waveform_payload(loop=False):
    return {
        "name": "Single-board manual smoke",
        "mode": "manual",
        "loop": loop,
        "record_duration_ns": 1000,
        "manual_channels": [
            {
                "channel": channel,
                "enabled": channel in {1, 3, 8},
                "waveform": "iq-sine",
                "frequency_mhz": 10.0 * channel,
                "phase_deg": 15.0 * channel,
                "amplitude": 1200,
                "duration_ns": 200,
            }
            for channel in range(1, 9)
        ],
    }


def ezq_waveform_payload():
    channels = []
    for channel in range(1, 9):
        role = "xy" if channel <= 4 else "z" if channel <= 6 else "readout"
        channels.append(
            {
                "channel": channel,
                "enabled": True,
                "role": role,
                "start_ns": channel * 20,
                "target_rf_mhz": 4500 if channel <= 4 else 0 if channel <= 6 else 5800 + (channel - 7) * 400,
                "detune_mhz": 0,
                "phase_deg": 0,
                "amplitude": 0.2,
                "duration_ns": 120 if channel <= 4 else 240 if channel <= 6 else 800,
                "xy_gate": "x_pi",
                "z_shape": "square",
            }
        )
    return {"name": "Single-board ez-Q smoke", "mode": "ezq", "record_duration_ns": 2000, "ezq_channels": channels}


def run_payload(waveform=None, board_id="board-a", dry_run=True):
    return {
        "jobs": [{"board_id": board_id, "waveform": waveform or manual_waveform_payload()}],
        "dry_run": dry_run,
        "execution_mode": "single",
    }


class WebAppApiTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.old_environment = {key: os.environ.get(key) for key in (
            "RFSOC_WEB_RUNTIME_DIR", "RFSOC_WEB_SIMULATION", "RFSOC_WEB_ADMIN_USERNAME", "RFSOC_WEB_ADMIN_PASSWORD"
        )}
        os.environ["RFSOC_WEB_RUNTIME_DIR"] = self.temp_dir.name
        os.environ["RFSOC_WEB_SIMULATION"] = "1"
        os.environ["RFSOC_WEB_ADMIN_USERNAME"] = "admin"
        os.environ["RFSOC_WEB_ADMIN_PASSWORD"] = "admin12345"
        self.client_context = TestClient(app)
        self.client = self.client_context.__enter__()
        self.login("admin", "admin12345")

    def tearDown(self):
        self.client_context.__exit__(None, None, None)
        self.temp_dir.cleanup()
        for key, value in self.old_environment.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def login(self, username, password):
        response = self.client.post("/api/auth/login", json={"username": username, "password": password})
        self.assertEqual(response.status_code, 200, response.text)
        self.csrf = response.json()["csrf_token"]
        self.headers = {"X-CSRF-Token": self.csrf}

    def wait_done(self, run_id):
        record = {}
        for _ in range(100):
            record = self.client.get(f"/api/runs/{run_id}").json()
            if record["state"] in {"DONE", "FAULT"}:
                break
            time.sleep(0.02)
        self.assertEqual(record["state"], "DONE", self.client.get(f"/api/runs/{run_id}/events").text)
        return record

    def test_authentication_boards_and_preview(self):
        self.assertIsNone(TestClient(app).get("/api/auth/me").json()["user"])
        boards = self.client.get("/api/boards")
        self.assertEqual(boards.status_code, 200)
        self.assertEqual([item["id"] for item in boards.json()], ["board-a", "board-b"])

        preview = self.client.post(
            "/api/waveforms/preview", json={"waveform": manual_waveform_payload(), "fft_channel": 1}, headers=self.headers
        )
        self.assertEqual(preview.status_code, 200, preview.text)
        self.assertEqual(len(preview.json()["series"]), 8)

        with self.client.websocket_connect("/api/events") as socket:
            self.assertEqual(socket.receive_json()["type"], "service.ready")

    def test_vue_router_paths_refresh_to_spa_without_hiding_unknown_api_routes(self):
        if not STATIC_DIR.exists():
            self.skipTest("production frontend has not been built")
        response = self.client.get("/boards/board-a/output")
        self.assertEqual(response.status_code, 200)
        self.assertIn("text/html", response.headers["content-type"])
        self.assertIn('<div id="app"></div>', response.text)
        self.assertEqual(self.client.get("/api/not-a-real-endpoint").status_code, 404)
        self.assertEqual(self.client.get("/favicon.ico").status_code, 404)

    def test_server_udp_interface_inventory_exposes_host_ethernet_port(self):
        response = self.client.get("/api/network/interfaces")
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(
            [item["name"] for item in response.json()],
            ["enp225s0f0", "enp225s0f1", "eno1np0", "eno2np1"],
        )

    def test_preflight_tracks_live_control_lease(self):
        initial = self.client.get("/api/boards/board-a/preflight?refresh=false")
        self.assertEqual(initial.status_code, 200, initial.text)
        self.assertFalse(initial.json()["can_start_live"])
        self.assertEqual(next(item for item in initial.json()["checks"] if item["key"] == "lease")["state"], "warning")

        leased = self.client.post("/api/boards/board-a/lease", headers=self.headers)
        self.assertEqual(leased.status_code, 200, leased.text)
        ready = self.client.get("/api/boards/board-a/preflight?refresh=false")
        self.assertTrue(ready.json()["can_start_live"])
        self.assertEqual(next(item for item in ready.json()["checks"] if item["key"] == "lease")["state"], "pass")

    def test_rfdc_apply_uses_pl_path_without_uart_binding(self):
        leased = self.client.post("/api/boards/board-a/lease", headers=self.headers)
        self.assertEqual(leased.status_code, 200, leased.text)
        board = next(item for item in self.client.get("/api/boards").json() if item["id"] == "board-a")
        self.assertEqual(board["serial_path"], "")
        config = self.client.get("/api/boards/board-a/rfdc-config").json()
        response = self.client.post(
            "/api/boards/board-a/rfdc-config/apply",
            json={"channels": config["channels"], "channel_mask": 0x31},
            headers=self.headers,
        )
        self.assertEqual(response.status_code, 200, response.text)
        applied = response.json()
        self.assertEqual(applied["apply_status"], "applied")
        self.assertEqual(applied["applied_mask"], 0x31)
        self.assertEqual(applied["config_valid_mask"], 0x31)
        self.assertIsNotNone(applied["channels"][0]["actual_nco_hz"])

    def test_administrator_can_disable_user(self):
        created = self.client.post(
            "/api/admin/users", json={"username": "disabled-user", "password": "password123", "role": "user", "enabled": True},
            headers=self.headers,
        )
        self.assertEqual(created.status_code, 201, created.text)
        updated = self.client.patch(
            f"/api/admin/users/{created.json()['id']}",
            json={"password": None, "role": "user", "enabled": False}, headers=self.headers,
        )
        self.assertEqual(updated.status_code, 200, updated.text)
        self.assertFalse(updated.json()["enabled"])
        denied = self.client.post("/api/auth/login", json={"username": "disabled-user", "password": "password123"})
        self.assertEqual(denied.status_code, 401, denied.text)

    def test_single_board_dry_run_completes_without_claiming_hardware_is_loaded(self):
        created = self.client.post("/api/runs", json=run_payload(), headers=self.headers)
        self.assertEqual(created.status_code, 202, created.text)
        run_id = created.json()["id"]
        record = self.wait_done(run_id)
        self.assertEqual(record["board_ids"], ["board-a"])
        self.assertFalse(record["loaded"])
        self.assertTrue(Path(record["artifact_dir"]).exists())
        self.assertIsNone(self.client.get("/api/boards/board-a/loaded-waveform").json())

        armed = self.client.post("/api/boards/board-a/arm", headers=self.headers)
        self.assertEqual(armed.status_code, 404, armed.text)
        messages = [event["message"] for event in self.client.get(f"/api/runs/{run_id}/events").json()]
        self.assertTrue(any("no data was sent to the board" in message for message in messages))
        self.assertFalse(any("sync epoch" in message for message in messages))
        status = self.client.get("/api/boards/board-a/status?refresh=false").json()
        self.assertEqual(status["state"], "IDLE")

    def test_live_upload_exposes_loaded_waveform_controls(self):
        leased = self.client.post("/api/boards/board-a/lease", headers=self.headers)
        self.assertEqual(leased.status_code, 200, leased.text)
        created = self.client.post("/api/runs", json=run_payload(dry_run=False), headers=self.headers)
        self.assertEqual(created.status_code, 202, created.text)
        record = self.wait_done(created.json()["id"])
        self.assertTrue(record["loaded"])

        armed = self.client.post("/api/boards/board-a/arm", headers=self.headers)
        self.assertEqual(armed.status_code, 200, armed.text)
        self.assertEqual(self.client.get("/api/boards/board-a/status?refresh=false").json()["state"], "ARMED")
        triggered = self.client.post("/api/boards/board-a/trigger", headers=self.headers)
        self.assertEqual(triggered.status_code, 200, triggered.text)
        self.assertEqual(self.client.get("/api/boards/board-a/status?refresh=false").json()["state"], "RUNNING")
        aborted = self.client.post("/api/boards/board-a/abort", headers=self.headers)
        self.assertEqual(aborted.status_code, 200, aborted.text)
        self.assertEqual(self.client.get("/api/boards/board-a/status?refresh=false").json()["state"], "MUTED")

    def test_completed_upload_releases_run_lock_for_next_task(self):
        first = self.client.post("/api/runs", json=run_payload(), headers=self.headers)
        self.assertEqual(first.status_code, 202, first.text)
        self.wait_done(first.json()["id"])
        second = self.client.post("/api/runs", json=run_payload(), headers=self.headers)
        self.assertEqual(second.status_code, 202, second.text)

    def test_web_run_loop_flag_reaches_generated_metadata(self):
        created = self.client.post(
            "/api/runs",
            json=run_payload(waveform=manual_waveform_payload(loop=True)),
            headers=self.headers,
        )
        self.assertEqual(created.status_code, 202, created.text)
        record = self.wait_done(created.json()["id"])
        request = app.state.services.store.get_request(record["id"])
        self.assertTrue(request.jobs[0].waveform.loop)
        metadata_path = Path(record["artifact_dir"]) / "board-a" / "manual-channels_metadata.json"
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        self.assertTrue(metadata["loop"])

    def test_multi_board_request_is_rejected_before_execution(self):
        payload = {
            "jobs": [
                {"board_id": "board-a", "waveform": manual_waveform_payload()},
                {"board_id": "board-b", "waveform": ezq_waveform_payload()},
            ],
            "dry_run": True,
            "execution_mode": "synchronized",
        }
        response = self.client.post("/api/runs", json=payload, headers=self.headers)
        self.assertEqual(response.status_code, 422, response.text)
        self.assertIn("hardware qualification", response.text)
        self.assertEqual(self.client.get("/api/runs").json(), [])

    def test_one_shot_finishes_after_mute_and_releases_board(self):
        payload = run_payload()
        payload["completion_mode"] = "one_shot"
        payload["one_shot_duration_ms"] = 1
        created = self.client.post("/api/runs", json=payload, headers=self.headers)
        self.assertEqual(created.status_code, 202, created.text)
        record = self.wait_done(created.json()["id"])
        self.assertEqual(record["state"], "DONE")
        self.assertFalse(record["loaded"])
        next_run = self.client.post("/api/runs", json=run_payload(), headers=self.headers)
        self.assertEqual(next_run.status_code, 202, next_run.text)

    def test_live_one_shot_finishes_muted_without_loaded_manual_controls(self):
        leased = self.client.post("/api/boards/board-a/lease", headers=self.headers)
        self.assertEqual(leased.status_code, 200, leased.text)
        payload = run_payload(dry_run=False)
        payload["completion_mode"] = "one_shot"
        payload["one_shot_duration_ms"] = 1
        created = self.client.post("/api/runs", json=payload, headers=self.headers)
        self.assertEqual(created.status_code, 202, created.text)
        record = self.wait_done(created.json()["id"])
        self.assertEqual(record["completion_mode"], "one_shot")
        self.assertFalse(record["loaded"])
        self.assertEqual(self.client.get("/api/boards/board-a/status?refresh=false").json()["state"], "MUTED")
        self.assertIsNone(self.client.get("/api/boards/board-a/loaded-waveform").json())

    def test_live_continuous_sine_triggers_once_mutes_and_releases_board(self):
        leased = self.client.post("/api/boards/board-a/lease", headers=self.headers)
        self.assertEqual(leased.status_code, 200, leased.text)
        payload = run_payload(waveform=manual_waveform_payload(loop=True), dry_run=False)
        payload["completion_mode"] = "one_shot"
        payload["playback_mode"] = "continuous_sine"
        payload["one_shot_duration_ms"] = 1
        created = self.client.post("/api/runs", json=payload, headers=self.headers)
        self.assertEqual(created.status_code, 202, created.text)
        record = self.wait_done(created.json()["id"])
        self.assertEqual(record["playback_mode"], "continuous_sine")
        self.assertFalse(record["loaded"])
        events = self.client.get(f"/api/runs/{record['id']}/events").json()
        messages = [event["message"] for event in events]
        self.assertTrue(any("continuous sine playback triggered once" in message for message in messages))
        self.assertFalse(any("loop playback sent" in message for message in messages))
        self.assertEqual(self.client.get("/api/boards/board-a/status?refresh=false").json()["state"], "MUTED")
        next_run = self.client.post("/api/runs", json=run_payload(dry_run=False), headers=self.headers)
        self.assertEqual(next_run.status_code, 202, next_run.text)

    def test_live_continuous_sine_zero_duration_runs_until_board_abort(self):
        leased = self.client.post("/api/boards/board-a/lease", headers=self.headers)
        self.assertEqual(leased.status_code, 200, leased.text)
        payload = run_payload(waveform=manual_waveform_payload(loop=True), dry_run=False)
        payload["completion_mode"] = "one_shot"
        payload["playback_mode"] = "continuous_sine"
        payload["one_shot_duration_ms"] = 0
        created = self.client.post("/api/runs", json=payload, headers=self.headers)
        self.assertEqual(created.status_code, 202, created.text)
        run_id = created.json()["id"]

        running = {}
        for _ in range(100):
            running = self.client.get(f"/api/runs/{run_id}").json()
            if running["state"] == "RUNNING":
                break
            time.sleep(0.02)
        self.assertEqual(running["state"], "RUNNING", self.client.get(f"/api/runs/{run_id}/events").text)
        self.assertEqual(self.client.get("/api/boards/board-a/status?refresh=false").json()["state"], "RUNNING")

        stopped = self.client.post("/api/boards/board-a/abort", headers=self.headers)
        self.assertEqual(stopped.status_code, 200, stopped.text)
        self.assertEqual(stopped.json()["state"], "ABORTED")
        self.assertEqual(self.client.get("/api/boards/board-a/status?refresh=false").json()["state"], "MUTED")

    def test_continuous_sine_rejects_non_loop_or_non_sine_payload(self):
        not_loop = run_payload(waveform=manual_waveform_payload(loop=False))
        not_loop["playback_mode"] = "continuous_sine"
        response = self.client.post("/api/runs", json=not_loop, headers=self.headers)
        self.assertEqual(response.status_code, 422, response.text)
        self.assertIn("waveform.loop=true", response.text)

        non_sine_waveform = manual_waveform_payload(loop=True)
        non_sine_waveform["manual_channels"][0]["waveform"] = "dc-iq-cw"
        non_sine = run_payload(waveform=non_sine_waveform)
        non_sine["playback_mode"] = "continuous_sine"
        response = self.client.post("/api/runs", json=non_sine, headers=self.headers)
        self.assertEqual(response.status_code, 422, response.text)
        self.assertIn("requires iq-sine", response.text)

    def test_live_run_auto_mutes_stale_armed_board_before_rfdc_apply(self):
        leased = self.client.post("/api/boards/board-a/lease", headers=self.headers)
        self.assertEqual(leased.status_code, 200, leased.text)
        first = self.client.post("/api/runs", json=run_payload(dry_run=False), headers=self.headers)
        self.assertEqual(first.status_code, 202, first.text)
        self.wait_done(first.json()["id"])
        armed = self.client.post("/api/boards/board-a/arm", headers=self.headers)
        self.assertEqual(armed.status_code, 200, armed.text)
        self.assertTrue(self.client.get("/api/boards/board-a/status?refresh=false").json()["playback_armed"])

        config = self.client.get("/api/boards/board-a/rfdc-config").json()
        payload = run_payload(dry_run=False)
        payload["jobs"][0]["rfdc_config"] = config
        payload["completion_mode"] = "one_shot"
        payload["one_shot_duration_ms"] = 1
        created = self.client.post("/api/runs", json=payload, headers=self.headers)
        self.assertEqual(created.status_code, 202, created.text)
        record = self.wait_done(created.json()["id"])
        self.assertFalse(record["loaded"])
        status = self.client.get("/api/boards/board-a/status?refresh=false").json()
        self.assertFalse(status["playback_armed"])
        self.assertFalse(status["playback_running"])

    def test_administrator_also_needs_lease_for_live_run(self):
        denied = self.client.post("/api/runs", json=run_payload(dry_run=False), headers=self.headers)
        self.assertEqual(denied.status_code, 403, denied.text)
        leased = self.client.post("/api/boards/board-a/lease", headers=self.headers)
        self.assertEqual(leased.status_code, 200, leased.text)
        accepted = self.client.post("/api/runs", json=run_payload(dry_run=False), headers=self.headers)
        self.assertEqual(accepted.status_code, 202, accepted.text)
        self.wait_done(accepted.json()["id"])

    def test_regular_user_needs_lease_for_live_run(self):
        created = self.client.post(
            "/api/admin/users",
            json={"username": "alice", "password": "password123", "role": "user", "enabled": True},
            headers=self.headers,
        )
        self.assertEqual(created.status_code, 201, created.text)
        self.client.post("/api/auth/logout", headers=self.headers)
        self.login("alice", "password123")

        denied = self.client.post("/api/runs", json=run_payload(dry_run=False), headers=self.headers)
        self.assertEqual(denied.status_code, 403, denied.text)
        leased = self.client.post("/api/boards/board-a/lease", headers=self.headers)
        self.assertEqual(leased.status_code, 200, leased.text)
        accepted = self.client.post("/api/runs", json=run_payload(dry_run=False), headers=self.headers)
        self.assertEqual(accepted.status_code, 202, accepted.text)
        self.wait_done(accepted.json()["id"])

    def test_performance_export_contains_environment_snapshot(self):
        created = self.client.post(
            "/api/tests",
            json={
                "name": "environment snapshot",
                "board_id": "board-a",
                "kind": "amplitude",
                "channels": [1],
                "points": [{"dac_output_current_ma": 2.25, "data_amplitude": 0.5}],
                "dry_run": True,
            },
            headers=self.headers,
        )
        self.assertEqual(created.status_code, 201, created.text)
        test_id = created.json()["id"]
        environment = created.json()["environment"]
        self.assertEqual(environment["board_id"], "board-a")
        self.assertIn("rfdc_config", environment)

        exported = self.client.get(f"/api/tests/{test_id}/export.csv")
        self.assertEqual(exported.status_code, 200, exported.text)
        self.assertIn("environment_snapshot", exported.text)
        self.assertIn("board-a", exported.text)

    def test_performance_dry_run_validates_point_without_loading_board(self):
        created = self.client.post(
            "/api/tests",
            json={
                "name": "dry point",
                "board_id": "board-a",
                "kind": "amplitude",
                "mode": "manual",
                "channels": [1],
                "points": [{"dac_output_current_ma": 20.0, "data_amplitude": 0.5}],
                "dry_run": True,
            },
            headers=self.headers,
        )
        self.assertEqual(created.status_code, 201, created.text)
        test_id = created.json()["id"]
        executed = self.client.post(f"/api/tests/{test_id}/points/0/execute", headers=self.headers)
        self.assertEqual(executed.status_code, 200, executed.text)
        self.assertEqual(executed.json()["state"], "READY")
        latest_run = self.client.get("/api/runs").json()[0]
        self.assertTrue(latest_run["dry_run"])
        self.assertFalse(latest_run["loaded"])
        self.assertEqual(self.client.get("/api/boards/board-a/status?refresh=false").json()["state"], "IDLE")

    def test_performance_scan_metadata_and_per_channel_snapshot(self):
        created = self.client.post(
            "/api/tests",
            json={
                "name": "per-channel amplitude sweep",
                "board_id": "board-a",
                "kind": "amplitude",
                "mode": "manual",
                "channels": [1, 3],
                "scan_axis": "data_amplitude",
                "scan_start": 0,
                "scan_stop": 1,
                "scan_step": 0.05,
                "scan_unit": "",
                "points": [{
                    "scan_axis": "data_amplitude",
                    "scan_value": 0.5,
                    "channel_configs": {
                        "1": {
                            "data_amplitude": 0.5, "data_offset_hz": 20e6,
                            "data_phase_deg": 10, "target_rf_hz": 4.5e9,
                            "nco_hz": -2e9, "nco_phase_deg": 20,
                            "dac_output_current_ma": 20, "duration_ns": 250,
                        },
                        "3": {
                            "data_amplitude": 0.25, "data_offset_hz": -10e6,
                            "data_phase_deg": 90, "target_rf_hz": 4.6e9,
                            "nco_hz": -1.8e9, "nco_phase_deg": 45,
                            "dac_output_current_ma": 22, "duration_ns": 500,
                        },
                    },
                }],
                "dry_run": True,
            },
            headers=self.headers,
        )
        self.assertEqual(created.status_code, 201, created.text)
        record = created.json()
        self.assertEqual(record["scan_axis"], "data_amplitude")
        self.assertEqual(record["scan_step"], 0.05)

        executed = self.client.post(f"/api/tests/{record['id']}/points/0/execute", headers=self.headers)
        self.assertEqual(executed.status_code, 200, executed.text)
        runs = self.client.get("/api/runs").json()
        request = app.state.services.store.get_request(runs[0]["id"])
        channels = request.jobs[0].waveform.manual_channels
        self.assertEqual(channels[0].data_amplitude, 0.5)
        self.assertEqual(channels[0].duration_ns, 250)
        self.assertEqual(channels[2].data_amplitude, 0.25)
        self.assertEqual(channels[2].duration_ns, 500)
        self.assertFalse(channels[1].enabled)


if __name__ == "__main__":
    unittest.main()
