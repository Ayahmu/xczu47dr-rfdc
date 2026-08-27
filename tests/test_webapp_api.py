import json
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, call, patch

from fastapi.testclient import TestClient

from software.webapp.main import STATIC_DIR, app
from software.webapp.models import NetworkInterfaceInfo


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
                "waveform": "xy",
                "format": "real" if channel in (5, 6) else "iq",
                "frequency_mhz": 10.0 * channel,
                "data_offset_mhz": 10.0 * channel,
                "phase_deg": 15.0 * channel,
                "amplitude": 1200,
                "data_amplitude": 1200 / 32767,
                "duration_ns": 200,
                "delay_ns": 0,
                "target_rf_mhz": 4500.0,
                "nco_mhz": -1900.0,
                "nyquist_zone": 2,
                "nco_phase_deg": 0.0,
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
            "RFSOC_WEB_RUNTIME_DIR", "RFSOC_WEB_SIMULATION", "RFSOC_WEB_SEED_SIMULATION_BOARDS",
            "RFSOC_WEB_ADMIN_USERNAME", "RFSOC_WEB_ADMIN_PASSWORD"
        )}
        os.environ["RFSOC_WEB_RUNTIME_DIR"] = self.temp_dir.name
        os.environ["RFSOC_WEB_SIMULATION"] = "1"
        os.environ["RFSOC_WEB_SEED_SIMULATION_BOARDS"] = "1"
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

    def test_production_inventory_starts_empty_until_scan(self):
        self.client_context.__exit__(None, None, None)
        for key, value in self.old_environment.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        with tempfile.TemporaryDirectory() as temp_dir:
            os.environ["RFSOC_WEB_RUNTIME_DIR"] = temp_dir
            os.environ["RFSOC_WEB_ADMIN_USERNAME"] = "admin"
            os.environ["RFSOC_WEB_ADMIN_PASSWORD"] = "admin12345"
            os.environ.pop("RFSOC_WEB_SIMULATION", None)
            os.environ.pop("RFSOC_WEB_SEED_SIMULATION_BOARDS", None)
            with TestClient(app) as client:
                login = client.post("/api/auth/login", json={"username": "admin", "password": "admin12345"})
                self.assertEqual(login.status_code, 200, login.text)
                response = client.get("/api/boards")
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.json(), [])
        os.environ["RFSOC_WEB_RUNTIME_DIR"] = self.temp_dir.name
        os.environ["RFSOC_WEB_SIMULATION"] = "1"
        os.environ["RFSOC_WEB_SEED_SIMULATION_BOARDS"] = "1"
        os.environ["RFSOC_WEB_ADMIN_USERNAME"] = "admin"
        os.environ["RFSOC_WEB_ADMIN_PASSWORD"] = "admin12345"
        self.client_context = TestClient(app)
        self.client = self.client_context.__enter__()
        self.login("admin", "admin12345")

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

    def test_manual_board_create_api_is_discovery_only_by_default(self):
        board = self.client.get("/api/boards").json()[0]
        board.pop("id", None)
        board.pop("lease", None)
        response = self.client.post("/api/admin/boards", json=board, headers=self.headers)
        self.assertEqual(response.status_code, 410, response.text)
        self.assertIn("RFCTRL2 discovery", response.text)

    def test_scan_prepares_host_link_before_rechecking_carrier(self):
        down = NetworkInterfaceInfo(
            name="enp-test0",
            present=True,
            operstate="down",
            carrier=False,
            ipv4_addresses=[],
            message="未检测到网线载波",
        )
        up = NetworkInterfaceInfo(
            name="enp-test0",
            present=True,
            operstate="up",
            carrier=True,
            ipv4_addresses=["192.168.77.10"],
            message="链路已连接",
        )
        profile = {
            "target_ip": "192.168.77.128",
            "target_mac": "02:00:00:00:00:01",
            "target_profile": "custom_xczu47dr",
            "source_ip": "192.168.77.10",
            "source_cidr": "192.168.77.10/24",
            "discovery_source_ip": "169.254.250.77",
            "discovery_source_cidr": "169.254.250.77/16",
            "bootstrap_source_ip": "192.168.254.77",
            "bootstrap_source_cidr": "192.168.254.77/24",
            "bootstrap_ip": "192.168.254.254",
            "pool_prefix": "192.168.77",
            "pool_start": "128",
            "pool_end": "254",
        }
        with patch("software.webapp.main.list_udp_interfaces", side_effect=[[down], [up], [up]]), \
             patch("software.webapp.main.auto_fpga_link_profile", return_value=profile), \
             patch("software.webapp.main.ensure_auto_link_ready", return_value=[]) as ensure, \
             patch("software.webapp.main.discovery_targets_for_interface", return_value=[]):
            response = self.client.post("/api/boards/scan", headers=self.headers)

        self.assertEqual(response.status_code, 200, response.text)
        ensure.assert_called_once_with("enp-test0")
        results = response.json()["results"]
        self.assertEqual(results[-1]["stage"], "discovery")
        self.assertNotIn("载波", results[-1]["message"])

    def test_server_udp_interface_inventory_exposes_host_ethernet_port(self):
        response = self.client.get("/api/network/interfaces")
        self.assertEqual(response.status_code, 200, response.text)
        names = {item["name"] for item in response.json()}
        self.assertTrue({"enp225s0f0", "enp225s0f1", "eno1np0", "eno2np1"} <= names)

    def test_admin_capability_report_exposes_required_net_caps(self):
        response = self.client.get("/api/admin/system/capabilities", headers=self.headers)
        self.assertEqual(response.status_code, 200, response.text)
        report = response.json()
        self.assertEqual(report["required"], ["CAP_NET_ADMIN", "CAP_NET_RAW"])
        self.assertIn("ok", report)
        self.assertIn("missing", report)

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

    def test_phase_calibration_is_persisted_and_returned_by_exact_key(self):
        response = self.client.put(
            "/api/boards/board-a/phase-calibration",
            json={"frequency_hz": 4500000000, "channel": 2, "phase_deg": 7.25},
            headers=self.headers,
        )
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["device_uid"], "sim-board-a")
        records = self.client.get("/api/boards/board-a/phase-calibration")
        self.assertEqual(records.status_code, 200, records.text)
        self.assertEqual(records.json()[0]["frequency_hz"], 4500000000)
        self.assertEqual(records.json()[0]["phase_deg"], 7.25)

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

    def test_synchronized_two_board_dry_run_is_accepted(self):
        payload = {
            "jobs": [
                {"board_id": "board-a", "waveform": manual_waveform_payload()},
                {"board_id": "board-b", "waveform": manual_waveform_payload()},
            ],
            "dry_run": True,
            "execution_mode": "synchronized",
        }
        response = self.client.post("/api/runs", json=payload, headers=self.headers)
        self.assertEqual(response.status_code, 202, response.text)
        record = self.wait_done(response.json()["id"])
        self.assertEqual(record["state"], "DONE")
        self.assertEqual(record["execution_mode"], "synchronized")
        self.assertEqual(record["board_ids"], ["board-a", "board-b"])

    def test_synchronized_run_rejects_wrong_job_count(self):
        payload = {
            "jobs": [
                {"board_id": "board-a", "waveform": manual_waveform_payload()},
                {"board_id": "board-b", "waveform": manual_waveform_payload()},
                {"board_id": "board-a", "waveform": manual_waveform_payload()},
            ],
            "dry_run": True,
            "execution_mode": "synchronized",
        }
        response = self.client.post("/api/runs", json=payload, headers=self.headers)
        self.assertEqual(response.status_code, 422, response.text)

    def test_sync_endpoint_requires_and_reports_both_boards(self):
        for board_id in ("board-a", "board-b"):
            leased = self.client.post(f"/api/boards/{board_id}/lease", headers=self.headers)
            self.assertEqual(leased.status_code, 200, leased.text)
        response = self.client.post(
            "/api/sync",
            json={"master_board_id": "board-a", "slave_board_id": "board-b"},
            headers=self.headers,
        )
        self.assertEqual(response.status_code, 200, response.text)
        result = response.json()
        self.assertTrue(result["ok"])
        self.assertEqual([item["board_id"] for item in result["boards"]], ["board-a", "board-b"])
        self.assertTrue(all(item["dac_mts_ready"] and item["nco_sync_ready"] for item in result["boards"]))

    def test_synchronized_live_one_shot_arms_both_and_triggers_master(self):
        for board_id in ("board-a", "board-b"):
            leased = self.client.post(f"/api/boards/{board_id}/lease", headers=self.headers)
            self.assertEqual(leased.status_code, 200, leased.text)
        payload = {
            "jobs": [
                {"board_id": "board-a", "waveform": manual_waveform_payload()},
                {"board_id": "board-b", "waveform": manual_waveform_payload()},
            ],
            "dry_run": False,
            "execution_mode": "synchronized",
            "completion_mode": "one_shot",
            "one_shot_duration_ms": 1,
        }
        created = self.client.post("/api/runs", json=payload, headers=self.headers)
        self.assertEqual(created.status_code, 202, created.text)
        record = self.wait_done(created.json()["id"])
        self.assertEqual(record["state"], "DONE")
        events = [event["message"] for event in self.client.get(f"/api/runs/{record['id']}/events").json()]
        self.assertTrue(any("synchronizing HMC7044" in message for message in events))

    def test_live_run_fault_mutes_every_board_in_the_run(self):
        services = app.state.services
        services.boards.mute = Mock()
        payload = run_payload(dry_run=False)
        from software.webapp.models import RunCreateRequest
        request = RunCreateRequest.model_validate(payload)
        record = services.runs.create(request)

        services.runs._fault(record.id, "simulated failure")

        self.assertEqual(
            services.boards.mute.call_args_list,
            [call("board-a")],
        )

    def test_max_length_dry_run_completes_with_metadata(self):
        leased = self.client.post("/api/boards/board-a/lease", headers=self.headers)
        self.assertEqual(leased.status_code, 200, leased.text)
        created = self.client.post(
            "/api/boards/board-a/max-length-test",
            json={"name": "max dry", "board_id": "board-a", "bytes_per_channel": 4096, "dry_run": True},
            headers=self.headers,
        )
        self.assertEqual(created.status_code, 202, created.text)
        test_id = created.json()["id"]
        deadline = time.monotonic() + 5
        record = None
        while time.monotonic() < deadline:
            record = self.client.get(f"/api/max-length-tests/{test_id}").json()
            if record["state"] == "COMPLETED":
                break
            time.sleep(0.02)
        self.assertEqual(record["state"], "COMPLETED")
        self.assertEqual(record["bytes_per_channel"], 4096)
        self.assertEqual(record["physical_bytes"], 4096 * 8)
        self.assertGreater(record["theoretical_duration_s"], 0)

    def test_max_length_simulation_mode_completes_without_network(self):
        leased = self.client.post("/api/boards/board-a/lease", headers=self.headers)
        self.assertEqual(leased.status_code, 200, leased.text)
        created = self.client.post(
            "/api/boards/board-a/max-length-test",
            json={"name": "max sim", "board_id": "board-a", "bytes_per_channel": 1024 * 1024, "dry_run": False},
            headers=self.headers,
        )
        self.assertEqual(created.status_code, 202, created.text)
        test_id = created.json()["id"]
        deadline = time.monotonic() + 5
        record = None
        while time.monotonic() < deadline:
            record = self.client.get(f"/api/max-length-tests/{test_id}").json()
            if record["state"] == "COMPLETED":
                break
            time.sleep(0.02)
        self.assertEqual(record["state"], "COMPLETED")

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
        self.assertTrue(any("continuous playback triggered once" in message for message in messages))
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

    def test_continuous_playback_rejects_non_loop_and_accepts_other_waveforms(self):
        not_loop = run_payload(waveform=manual_waveform_payload(loop=False))
        not_loop["playback_mode"] = "continuous_sine"
        response = self.client.post("/api/runs", json=not_loop, headers=self.headers)
        self.assertEqual(response.status_code, 422, response.text)
        self.assertIn("waveform.loop=true", response.text)

        z_waveform = manual_waveform_payload(loop=True)
        z_waveform["manual_channels"][0]["waveform"] = "z"
        z_playback = run_payload(waveform=z_waveform)
        z_playback["playback_mode"] = "continuous_sine"
        response = self.client.post("/api/runs", json=z_playback, headers=self.headers)
        self.assertEqual(response.status_code, 202, response.text)

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

    def test_live_run_requires_applied_network_identity(self):
        leased = self.client.post("/api/boards/board-a/lease", headers=self.headers)
        self.assertEqual(leased.status_code, 200, leased.text)
        app.state.services.management.update_network_state(
            "board-a",
            status="failed",
            error="NETWORK_APPLY failed in scan",
        )

        denied = self.client.post("/api/runs", json=run_payload(dry_run=False), headers=self.headers)
        self.assertEqual(denied.status_code, 409, denied.text)
        self.assertIn("network identity is not applied", denied.text)

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
