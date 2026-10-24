"""Unit tests for the credential-free local qualification launcher."""

import importlib.util
import os
import pathlib
import socket
import stat
import subprocess
import sys
import unittest
import json
import tempfile
import time
from unittest.mock import patch


MODULE = pathlib.Path(__file__).parents[1] / "support/a4/run_h100_local_qualification.py"
spec = importlib.util.spec_from_file_location("h100_host_qualification_runner", MODULE)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class HostQualificationLauncherTests(unittest.TestCase):
    def test_proof_failure_summary_uses_only_bounded_exception_classes(self):
        detail = runner.proof_failure_detail(
            1,
            {
                "type": "PROOF_ERROR", "reason": "proof_process_failed", "error_class": "match_error",
                "failure_code": "not_available",
                "failure_site": {"function": "run_proof", "line": 97},
            },
        )
        self.assertEqual(detail, "proof BEAM raised match_error at run_proof:97")

        detail = runner.proof_failure_detail(
            1,
            {
                "type": "PROOF_ERROR", "reason": "proof_process_failed", "error_class": "unsafe secret text",
                "failure_code": "not_available",
                "failure_site": {"function": "run_proof", "line": 97},
            },
        )
        self.assertEqual(detail, "proof BEAM raised an unclassified exception at run_proof:97")

        detail = runner.proof_failure_detail(
            1,
            {
                "type": "PROOF_ERROR", "reason": "proof_process_failed", "error_class": "argument_error",
                "failure_code": "manifest_origin_authority",
                "failure_site": {"function": "run_proof", "line": 97},
            },
        )
        self.assertEqual(detail, "proof BEAM failed manifest_origin_authority at run_proof:97")

        detail = runner.proof_failure_detail(
            1,
            {
                "type": "PROOF_ERROR", "reason": "proof_process_failed", "error_class": "argument_error",
                "failure_code": "controller_manifest_ipc_failed",
                "failure_site": {"function": "run_proof", "line": 97},
            },
        )
        self.assertEqual(detail, "proof BEAM failed controller_manifest_ipc_failed at run_proof:97")

    def test_proof_failure_summary_reports_exit_status_without_raw_output(self):
        self.assertEqual(
            runner.proof_failure_detail(127, None, b"** (CompileError) sensitive details"),
            "unprivileged proof BEAM exited with status 127 without a bounded result: compile_error",
        )

    def test_proof_stderr_classifier_returns_only_fixed_categories(self):
        self.assertEqual(runner.proof_stderr_category(b"Failed to create scheduler thread 3"),
                         "erlang_startup_error")
        self.assertEqual(runner.proof_stderr_category(b"Permission denied: secret path"),
                         "permission_error")
        self.assertEqual(runner.proof_stderr_category(b"Permission denied writing _build/test"),
                         "permission_build_output")
        self.assertEqual(runner.proof_stderr_category(b"Permission denied proof-state/proof-result.json"),
                         "permission_proof_result")
        self.assertEqual(runner.proof_stderr_category(b"unrecognized sensitive output"),
                         "unclassified_stderr")
        self.assertEqual(runner.proof_stderr_category(b"** (Mix) Could not find a Mix.Project"),
                         "mix_project_error")
        self.assertEqual(runner.proof_stderr_category(b"** (Mix) Could not load dependency"),
                         "mix_load_error")
        self.assertEqual(runner.proof_stderr_category(b"** (Mix) Could not find a Mix.Project"),
                         "mix_project_error")
        self.assertEqual(runner.proof_stderr_category(b"** (Mix) Could not find dependency"),
                         "mix_dependency_error")

    def test_proof_failure_summary_names_only_failed_contract_fields(self):
        result = {
            "type": "PROOF_RESULT",
            "failure_code": "proof_manifest_mismatch_body_bytes",
            "provider_request_id": "preq_fixture",
            "manifest_finch_absent_before_ready": True,
            "finch_started_at_witness": True,
            "transport_result": "unexpected_success",
            "finch_stopped": True,
            "dispatch_witness_ack_count": 0,
            "retry_count": 0,
            "replay_count": 0,
            "canary_policy_verified": True,
            "direct_ipv4_canary": "blocked",
            "direct_ipv6_canary": "blocked",
            "canary_drop_packets": 2,
            "tls_verify_peer": True,
            "tls_hostname_verification": True,
            "shared_trust_unchanged": True,
        }
        self.assertEqual(
            runner.proof_failure_detail(1, result),
            "proof result rejected (proof_manifest_mismatch_body_bytes) [acks=0]",
        )

    def test_proof_failure_summary_prioritizes_ready_gate_failure(self):
        result = {
            "type": "PROOF_RESULT",
            "failure_code": "controller_ready_ipc_failed",
            "provider_request_id": "preq_fixture",
            "manifest_finch_absent_before_ready": True,
            "finch_started_at_witness": False,
            "finch_stopped": True,
            "dispatch_witness_ack_count": 0,
            "retry_count": 0,
            "replay_count": 0,
            "transport_result": "transport_failure",
            "direct_ipv4_canary": "failed",
            "direct_ipv6_canary": "failed",
            "canary_policy_verified": False,
            "canary_drop_packets": 0,
            "tls_verify_peer": True,
            "tls_hostname_verification": True,
            "shared_trust_unchanged": True,
        }
        self.assertEqual(
            runner.proof_failure_detail(1, result),
            "proof result rejected (controller_ready_ipc_failed) [ipv4=failed,ipv6=failed,acks=0]",
        )
        result["failure_code"] = "policy_not_verified"
        self.assertEqual(
            runner.proof_failure_detail(1, result),
            "proof result rejected (policy_not_verified) [ipv4=failed,ipv6=failed,acks=0]",
        )
        result["failure_code"] = "proof_finch_start_failed"
        self.assertEqual(
            runner.proof_failure_detail(1, result),
            "proof result rejected (proof_finch_start_failed) [ipv4=failed,ipv6=failed,acks=0]",
        )

    def test_proof_failure_summary_accepts_canaries_not_run_before_witness(self):
        result = {
            "type": "PROOF_RESULT",
            "failure_code": "controller_ready_ipc_failed",
            "provider_request_id": "preq_fixture",
            "manifest_finch_absent_before_ready": True,
            "finch_started_at_witness": False,
            "finch_stopped": True,
            "dispatch_witness_ack_count": 0,
            "retry_count": 0,
            "replay_count": 0,
            "transport_result": "transport_failure",
            "direct_ipv4_canary": "not_observed",
            "direct_ipv6_canary": "not_observed",
            "canary_policy_verified": False,
            "canary_drop_packets": 0,
            "tls_verify_peer": True,
            "tls_hostname_verification": True,
            "shared_trust_unchanged": True,
        }
        self.assertEqual(
            runner.proof_failure_detail(1, result),
            "proof result rejected (controller_ready_ipc_failed) "
            "[ipv4=not_observed,ipv6=not_observed,acks=0]",
        )

    def test_proof_failure_summary_reports_allowlisted_dispatch_sink_failure(self):
        result = {
            "type": "PROOF_RESULT",
            "failure_code": "sink_rejected",
            "provider_request_id": "preq_fixture",
            "manifest_finch_absent_before_ready": True,
            "finch_started_at_witness": False,
            "finch_stopped": True,
            "dispatch_witness_ack_count": 0,
            "retry_count": 0,
            "replay_count": 0,
            "transport_result": "transport_failure",
            "direct_ipv4_canary": "not_observed",
            "direct_ipv6_canary": "not_observed",
            "canary_policy_verified": False,
            "canary_drop_packets": 0,
            "tls_verify_peer": True,
            "tls_hostname_verification": True,
            "shared_trust_unchanged": True,
        }
        self.assertEqual(
            runner.proof_failure_detail(1, result),
            "proof result rejected (sink_rejected) "
            "[ipv4=not_observed,ipv6=not_observed,acks=0]",
        )

    def test_proof_failure_summary_accepts_bounded_witness_validation_failure(self):
        result = {
            "type": "PROOF_RESULT",
            "failure_code": "invalid_provider_dispatch_witness",
            "provider_request_id": "preq_fixture",
            "manifest_finch_absent_before_ready": True,
            "finch_started_at_witness": False,
            "finch_stopped": True,
            "dispatch_witness_ack_count": 0,
            "retry_count": 0,
            "replay_count": 0,
            "transport_result": "transport_failure",
            "direct_ipv4_canary": "not_observed",
            "direct_ipv6_canary": "not_observed",
            "canary_policy_verified": False,
            "canary_drop_packets": 0,
            "tls_verify_peer": True,
            "tls_hostname_verification": True,
            "shared_trust_unchanged": True,
        }
        self.assertEqual(
            runner.proof_failure_detail(1, result),
            "proof result rejected (invalid_provider_dispatch_witness) "
            "[ipv4=not_observed,ipv6=not_observed,acks=0]",
        )

    def test_proof_failure_summary_accepts_bounded_internal_witness_atom(self):
        result = {
            "type": "PROOF_RESULT",
            "failure_code": "dispatch_witness_failed_internal_reason",
            "provider_request_id": "preq_fixture",
            "manifest_finch_absent_before_ready": True,
            "finch_started_at_witness": False,
            "finch_stopped": True,
            "dispatch_witness_ack_count": 0,
            "retry_count": 0,
            "replay_count": 0,
            "transport_result": "transport_failure",
            "direct_ipv4_canary": "not_observed",
            "direct_ipv6_canary": "not_observed",
            "canary_policy_verified": False,
            "canary_drop_packets": 0,
            "tls_verify_peer": True,
            "tls_hostname_verification": True,
            "shared_trust_unchanged": True,
        }
        self.assertEqual(
            runner.proof_failure_detail(1, result),
            "proof result rejected (dispatch_witness_failed_internal_reason) "
            "[ipv4=not_observed,ipv6=not_observed,acks=0]",
        )
        result["failure_code"] = "dispatch_witness_failed_" + ("a" * 65)
        self.assertEqual(
            runner.proof_failure_detail(1, result),
            "proof BEAM failed with an invalid bounded result",
        )

    def test_proof_failure_summary_never_includes_untrusted_values(self):
        detail = runner.proof_failure_detail(
            1,
            {
                "type": "PROOF_ERROR",
                "reason": "proof_process_failed",
                "error_class": "match_error",
                "failure_code": "not_available",
                "failure_site": {"function": "run_proof", "line": 97},
                "authorization": "secret-value",
            },
        )
        self.assertEqual(detail, "proof BEAM failed with an invalid bounded result")

    def test_manifest_request_failure_reports_only_mismatched_field_names(self):
        request = {
            "provider_request_id": "preq_fixture",
            "transition_attempt_id": "attempt-fixture",
            "work_item_id": "work-1",
            "workspace_id": "workspace-1",
            "project_id": "project-1",
            "target_state_id": "state-1",
            "candidate_sha": "c" * 40,
            "candidate_tree": "b" * 40,
            "origin_base_url": "https://127.0.0.1:44321",
            "origin_authority": "127.0.0.1:44321",
            "method": "PATCH",
            "body_bytes": 16,
            "path_bytes": len(runner.EXPECTED_PATH.encode()),
        }
        expected = {
            "provider_request_id": "preq_fixture",
            "transition_attempt_id": "attempt-fixture",
            "origin_url": "https://127.0.0.1:44321",
            "origin_authority": "127.0.0.1:44321",
            "body_bytes": 16,
        }
        with self.assertRaisesRegex(runner.QualificationFailure, "^manifest_request_mismatch:candidate_sha$"):
            runner._manifest_for(
                request, expected, head="a" * 40, tree="b" * 40,
                relay_hash="d" * 64, python_path="/usr/bin/python3", python_version="3.14.0",
            )

    def test_ipc_filter_allows_only_frozen_operator_authorization_reference(self):
        self.assertTrue(
            runner._safe_ipc_value(
                {"manifest": {"operator_authorization_ref": "local-test-only"}}
            )
        )
        self.assertFalse(
            runner._safe_ipc_value(
                {"manifest": {"authorization_header": "fixture-sentinel"}}
            )
        )

    def test_outer_launcher_does_not_require_namespace_only_arguments(self):
        with patch.object(runner, "outer_main", return_value={"type": "TEST_RESULT"}) as outer:
            with patch.object(runner, "_write_status"):
                self.assertEqual(runner.main(["--repo-root", "/tmp"]), 0)
        outer.assert_called_once_with("/tmp")

    def test_launcher_reports_only_its_bounded_internal_failure_reason(self):
        statuses = []
        with patch.object(runner, "outer_main", side_effect=runner.QualificationFailure("fixture stage failed")):
            with patch.object(runner, "_write_status", side_effect=statuses.append):
                self.assertEqual(runner.main(["--repo-root", "/tmp"]), 1)
        self.assertEqual(statuses, [{"type": "QUALIFICATION_ERROR", "reason": "fixture stage failed"}])

    def test_outside_control_listener_stops_promptly_when_closed(self):
        listener, _port, result, thread = runner._outer_listener()
        listener.close()
        thread.join(timeout=1)
        self.assertFalse(thread.is_alive())
        self.assertFalse(result["complete"])

    def test_cleanup_attempts_every_resource_and_reports_a_child_that_would_not_stop(self):
        class Process:
            def __init__(self):
                self.stdout = None
                self.stderr = None
                self.stdin = None

        class Closable:
            def __init__(self):
                self.closed = False

            def close(self):
                self.closed = True

        proof = Process()
        relay = Process()
        canary = Closable()
        controller = Closable()
        policy = object()
        with patch.object(runner, "_stop_process", side_effect=[False, True]) as stop:
            with patch.object(runner, "_nft_delete_if_present") as remove_policy:
                with patch.object(runner, "_unmount_repo") as unmount:
                    with self.assertRaisesRegex(runner.QualificationFailure, "cleanup"):
                        runner._cleanup_inside_resources(
                            control_server=controller,
                            processes=(("proof", proof), ("relay", relay)),
                            canaries=(canary,), ca_path=None, cert_directory=None,
                            policy=policy, mount_path=pathlib.Path("/unused"), mounted=True,
                            temp_root=None,
                        )
        self.assertEqual(stop.call_count, 2)
        self.assertTrue(controller.closed)
        self.assertTrue(canary.closed)
        remove_policy.assert_called_once_with(policy)
        unmount.assert_called_once_with(pathlib.Path("/unused"))

    def test_cleanup_failure_preserves_primary_qualification_failure(self):
        primary = runner.QualificationFailure("Stage A verifier rejected policy")

        def cleanup_fails():
            raise runner.QualificationFailure("qualification cleanup failed: policy")

        with self.assertRaisesRegex(
            runner.QualificationFailure,
            "Stage A verifier rejected policy; qualification cleanup failed: policy",
        ):
            runner._cleanup_preserving_failure(primary, cleanup_fails)

    def test_policy_cleanup_uses_backend_removal_and_independent_verification(self):
        class Policy:
            def __init__(self, verified=True):
                self.removed = False
                self.verified = verified

            def remove_policy_table(self):
                self.removed = True

            def verify_policy_removed(self):
                return self.verified

        policy = Policy()
        runner._nft_delete_if_present(policy)
        self.assertTrue(policy.removed)

        with self.assertRaisesRegex(runner.QualificationFailure, "independently removed"):
            runner._nft_delete_if_present(Policy(verified=False))

    def test_read_only_mount_is_removed_when_remount_setup_fails(self):
        with tempfile.TemporaryDirectory(prefix="h100-mount-rollback-") as directory:
            repo = pathlib.Path(directory) / "repo"
            mount = pathlib.Path(directory) / "mount"
            with patch.object(runner, "_run_bounded", side_effect=[None, runner.QualificationFailure("remount")]):
                with patch.object(runner, "_unmount_repo") as unmount:
                    with self.assertRaises(runner.QualificationFailure):
                        runner._bind_repo_read_only(repo, mount)
            unmount.assert_called_once_with(mount)

    def test_cleanup_removes_the_namespace_temporary_root(self):
        class Process:
            stdin = stdout = stderr = None

        with tempfile.TemporaryDirectory(prefix="h100-namespace-cleanup-") as directory:
            temp_root = pathlib.Path(directory) / "namespace"
            temp_root.mkdir()
            (temp_root / "proof-state").mkdir()
            (temp_root / "proof-state" / "result.json").write_text("bounded result")

            with patch.object(runner, "_stop_process", return_value=True):
                runner._cleanup_inside_resources(
                    control_server=None,
                    processes=(("proof", Process()),),
                    canaries=(), ca_path=None, cert_directory=None,
                    policy=None, mount_path=temp_root / "repo", mounted=False,
                    temp_root=temp_root,
                )

            self.assertFalse(temp_root.exists())

    def test_generated_trust_material_is_removed_before_acceptance(self):
        with tempfile.TemporaryDirectory(prefix="h100-trust-cleanup-") as directory:
            ca_path = pathlib.Path(directory) / "fixture-ca.der"
            cert_directory = pathlib.Path(directory) / "generated-certs"
            ca_path.write_bytes(b"local-ca")
            cert_directory.mkdir()
            (cert_directory / "server.key").write_bytes(b"local-private-key")

            self.assertTrue(runner._remove_generated_trust_material(ca_path, cert_directory))
            self.assertFalse(ca_path.exists())
            self.assertFalse(cert_directory.exists())

    def test_child_environment_is_an_explicit_allowlist(self):
        values = {"H100_QUAL_REQUEST_ID": "req-1", "H100_QUAL_ORIGIN_URL": "https://127.0.0.1:44321"}
        with patch.dict(os.environ, {"PLANE_API_KEY_FERDI": "must-not-copy", "GH_TOKEN": "must-not-copy"}):
            child = runner.child_environment(values, home="/tmp/proof-home")
        self.assertEqual(child["H100_QUAL_REQUEST_ID"], "req-1")
        self.assertEqual(child["HOME"], "/tmp/proof-home")
        self.assertNotIn("PLANE_API_KEY_FERDI", child)
        self.assertNotIn("GH_TOKEN", child)
        self.assertNotIn("PATH_INFO", child)

    def test_runtime_path_contains_only_resolved_elixir_and_erlang_bins(self):
        runtime_path = runner.runtime_path_for(
            "/opt/elixir/bin/mix", "/opt/elixir/bin/elixir", "/opt/erlang/bin/erl"
        )
        self.assertEqual(runtime_path, "/opt/elixir/bin:/opt/erlang/bin")
        child = runner.child_environment({}, home="/tmp/proof-home", runtime_path=runtime_path)
        self.assertEqual(child["PATH"], runtime_path + ":" + runner.SYSTEM_PATH)

    def test_runtime_mount_plan_maps_only_pinned_elixir_and_erlang_installs(self):
        with tempfile.TemporaryDirectory(prefix="h100-runtime-plan-") as directory:
            root = pathlib.Path(directory)
            elixir_bin = root / "elixir" / "1.19" / "bin"
            erlang_bin = root / "erlang" / "28" / "bin"
            elixir_bin.mkdir(parents=True)
            erlang_bin.mkdir(parents=True)
            (elixir_bin / "mix").touch()
            (elixir_bin / "elixir").touch()
            (erlang_bin / "erl").touch()
            plan = runner.runtime_mount_plan(
                str(elixir_bin / "mix"),
                os.pathsep.join((str(elixir_bin), str(erlang_bin))),
                str(root / "namespace"),
            )
            self.assertEqual(
                [(item["source"], item["destination"]) for item in plan["mounts"]],
                [
                    (str(elixir_bin.parent), str(root / "namespace/runtime/elixir")),
                    (str(erlang_bin.parent), str(root / "namespace/runtime/erlang")),
                ],
            )
            self.assertEqual(plan["mix_path"], str(root / "namespace/runtime/elixir/bin/mix"))
            self.assertEqual(plan["elixir_path"], str(root / "namespace/runtime/elixir/bin/elixir"))
            self.assertEqual(
                plan["runtime_path"],
                os.pathsep.join((
                    str(root / "namespace/runtime/elixir/bin"),
                    str(root / "namespace/runtime/erlang/bin"),
                )),
            )

    def test_proof_elixir_command_uses_only_pinned_build_code_paths(self):
        with tempfile.TemporaryDirectory(prefix="h100-proof-code-paths-") as directory:
            build_lib = pathlib.Path(directory) / "_build/test/lib"
            app_ebin = build_lib / "symphony_elixir/ebin"
            dep_ebin = build_lib / "finch/ebin"
            app_ebin.mkdir(parents=True)
            dep_ebin.mkdir(parents=True)
            command = runner.proof_elixir_command(
                "/runtime/elixir/bin/elixir", str(build_lib), "/repo/test/support/proof.exs"
            )
        self.assertEqual(
            command,
            [
                "/runtime/elixir/bin/elixir",
                "-pa", str(dep_ebin),
                "-pa", str(app_ebin),
                "/repo/test/support/proof.exs",
            ],
        )
        self.assertNotIn("mix", command[0])

    def test_proof_identity_failure_reports_only_child_exit_status(self):
        class ExitedProcess:
            pid = 321

            @staticmethod
            def poll():
                return 127

        with patch.object(runner, "_process_identity", side_effect=runner.QualificationFailure("identity")):
            with self.assertRaisesRegex(runner.QualificationFailure, "status 127"):
                runner.proof_process_identity(ExitedProcess())

    def test_proof_launch_gate_holds_then_execs_target_in_the_same_pid(self):
        with tempfile.TemporaryDirectory(prefix="h100-proof-gate-") as directory:
            marker = pathlib.Path(directory) / "target-pid"
            target = [
                sys.executable, "-I", "-c",
                "import os,pathlib,sys; pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))",
                str(marker),
            ]
            process = subprocess.Popen(
                runner.proof_launch_command(target), stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}, start_new_session=True,
            )
            try:
                time.sleep(0.05)
                self.assertIsNone(process.poll())
                self.assertFalse(marker.exists())
                process.stdin.write(b"GO\n")
                process.stdin.flush()
                process.stdin.close()
                self.assertEqual(process.wait(timeout=3), 0)
                self.assertEqual(marker.read_text(), str(process.pid))
            finally:
                if process.poll() is None:
                    runner._stop_process(process)
                if process.stdin is not None and not process.stdin.closed:
                    process.stdin.close()

    def test_origin_summary_must_match_the_exact_patch_without_returning_payload(self):
        raw = ('{"type":"LOCAL_TLS_RESULT","request_count":1,"complete_request":true,'
               '"method":"PATCH","path":"/api/v1/work-items/work-1/",'
               '"body_bytes":16,"body_sha256":"' + "a" * 64 + '",'
               '"credential_valid":true,"tls_version":"TLSv1.2"}')
        result = runner.validate_origin_summary(
            raw,
            expected_path="/api/v1/work-items/work-1/",
            expected_body_bytes=16,
            expected_body_sha256="a" * 64,
        )
        self.assertTrue(result["complete_request"])
        self.assertEqual(result["request_count"], 1)
        self.assertEqual(result["tls_version"], "TLSv1.2")
        self.assertNotIn("path", result)
        self.assertNotIn("body_sha256", result)

    def test_origin_summary_rejects_a_different_path_or_body(self):
        raw = ('{"type":"LOCAL_TLS_RESULT","request_count":1,"complete_request":true,'
               '"method":"PATCH","path":"/wrong/", "body_bytes":16,'
               '"body_sha256":"' + "a" * 64 + '","credential_valid":true,'
               '"tls_version":"TLSv1.2"}')
        with self.assertRaises(runner.QualificationFailure):
            runner.validate_origin_summary(
                raw,
                expected_path="/expected/",
                expected_body_bytes=16,
                expected_body_sha256="a" * 64,
            )

    def test_origin_error_summary_reports_only_allowlisted_stage_and_class(self):
        raw = json.dumps({
            "type": "LOCAL_TLS_ERROR",
            "reason": "origin_failed",
            "stage": "response_write",
            "error_class": "SSLEOFError",
        })
        with self.assertRaisesRegex(runner.QualificationFailure, "local TLS origin failed at response_write"):
            runner.validate_origin_summary(
                raw,
                expected_path="/expected/",
                expected_body_bytes=16,
                expected_body_sha256="a" * 64,
            )

    def test_peer_credentials_report_the_actual_unix_socket_client(self):
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        path = pathlib.Path("/tmp") / f"h100-peer-{os.getpid()}-{id(self)}.sock"
        try:
            listener.bind(str(path))
            listener.listen(1)
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.connect(str(path))
            accepted, _ = listener.accept()
            try:
                self.assertEqual(runner.peer_credentials(accepted), (os.getpid(), os.geteuid(), os.getegid()))
            finally:
                accepted.close()
                client.close()
        finally:
            listener.close()
            path.unlink(missing_ok=True)

    def test_controller_ipc_accepts_only_the_live_proof_pid_and_uid(self):
        with tempfile.TemporaryDirectory(prefix="h100-ipc-test-") as directory:
            path = pathlib.Path(directory) / "controller.sock"
            server = runner.ControllerIPCServer(
                path,
                expected_uid=os.geteuid(),
                expected_pid=os.getpid(),
                handler=lambda message, _peer: {"verified": message.get("op") == "stage_a"},
            )
            server.start()
            try:
                metadata = path.stat()
                self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o600)
                self.assertEqual(metadata.st_uid, os.geteuid())
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                    client.connect(str(path))
                    client.sendall(b'{"op":"stage_a"}\n')
                    response = json.loads(client.recv(4096))
                self.assertEqual(response, {"verified": True})
            finally:
                server.close()

    def test_controller_ipc_rejects_a_different_local_pid(self):
        with tempfile.TemporaryDirectory(prefix="h100-ipc-test-") as directory:
            path = pathlib.Path(directory) / "controller.sock"
            server = runner.ControllerIPCServer(
                path,
                expected_uid=os.geteuid(),
                expected_pid=os.getpid() + 1000,
                handler=lambda _message, _peer: {"verified": True},
            )
            server.start()
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                    client.connect(str(path))
                    client.sendall(b'{"op":"stage_a"}\n')
                    response = json.loads(client.recv(4096))
                self.assertEqual(response, {"error": "unauthorized_controller_peer"})
            finally:
                server.close()

    def test_controller_ipc_fails_closed_when_handler_raises(self):
        with tempfile.TemporaryDirectory(prefix="h100-ipc-test-") as directory:
            path = pathlib.Path(directory) / "controller.sock"

            def fail_handler(_message, _peer):
                raise ValueError("private handler details")

            server = runner.ControllerIPCServer(
                path,
                expected_uid=os.geteuid(),
                expected_pid=os.getpid(),
                handler=fail_handler,
            )
            server.start()
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                    client.connect(str(path))
                    client.sendall(b'{"op":"stage_a"}\n')
                    response = json.loads(client.recv(4096))
                self.assertEqual(response, {"error": "controller_operation_failed"})
            finally:
                server.close()

    def test_controller_listener_waits_for_live_proof_pid_binding(self):
        with tempfile.TemporaryDirectory(prefix="h100-ipc-bind-") as directory:
            path = pathlib.Path(directory) / "controller.sock"
            server = runner.ControllerIPCServer(
                path,
                expected_uid=os.geteuid(),
                expected_pid=0,
                handler=lambda _message, _peer: {"verified": True},
            )
            server.start()
            client_code = (
                "import socket,sys; s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); "
                "s.connect(sys.argv[1]); s.sendall(b'{\\\"op\\\":\\\"stage_a\\\"}\\n'); "
                "print(s.recv(4096).decode()); s.close()"
            )
            child = subprocess.Popen(
                [sys.executable, "-I", "-c", client_code, str(path)],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"},
            )
            try:
                time.sleep(0.05)
                self.assertIsNone(child.poll(), "IPC request was handled before PID binding")
                server.set_expected_pid(child.pid)
                output, _ = child.communicate(timeout=3)
                self.assertEqual(json.loads(output), {"verified": True})
            finally:
                if child.poll() is None:
                    child.terminate()
                    child.wait(timeout=3)
                if child.stdout is not None:
                    child.stdout.close()
                server.close()

    def test_relay_listener_verification_requires_one_ipv4_loopback_socket(self):
        tcp = ("  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid timeout inode\n"
               "   0: 0100007F:A869 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1202 0 12345 1\n")
        self.assertEqual(
            runner.verify_relay_listener(tcp, "", {12345}, 43113),
            {"host": "127.0.0.1", "port": 43113, "socket_inode": 12345},
        )
        wildcard = tcp.replace("0100007F", "00000000")
        with self.assertRaises(runner.QualificationFailure):
            runner.verify_relay_listener(wildcard, "", {12345}, 43113)

    def test_process_teardown_waits_for_signal_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="h100-stop-test-") as directory:
            marker = pathlib.Path(directory) / "cleaned"
            ready = pathlib.Path(directory) / "handler-ready"
            handler = ("import pathlib,signal,sys,time; "
                       "signal.signal(signal.SIGTERM,lambda _s,_f:(pathlib.Path(sys.argv[1]).write_text('done'),sys.exit(143))); "
                       "pathlib.Path(sys.argv[2]).write_text('ready'); "
                       "time.sleep(30)")
            process = subprocess.Popen([sys.executable, "-c", handler, str(marker), str(ready)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       start_new_session=True)
            deadline = time.monotonic() + 3
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(ready.exists(), "child did not install its signal handler")
            self.assertTrue(runner._stop_process(process, timeout=3))
            self.assertEqual(marker.read_text(), "done")

    def test_origin_launcher_stops_child_when_identity_check_fails(self):
        self._assert_launcher_stops_child(
            lambda directory: runner._launch_origin(
                sys.executable, pathlib.Path(directory) / "fixture.py",
                pathlib.Path(directory) / "origin", "/expected/",
            )
        )

    def test_relay_launcher_stops_child_when_identity_check_fails(self):
        self._assert_launcher_stops_child(
            lambda directory: runner._launch_relay(
                sys.executable, pathlib.Path(directory) / "relay.py",
                pathlib.Path(directory) / "relay", pathlib.Path(directory) / "evidence.json",
                "preq_test", "127.0.0.1:44321",
            )
        )

    def test_inner_launcher_sigterm_runs_qualification_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="h100-signal-cleanup-") as directory:
            ready = pathlib.Path(directory) / "ready"
            cleaned = pathlib.Path(directory) / "cleaned"
            script = "\n".join([
                "import importlib.util, pathlib, sys, time",
                f"spec = importlib.util.spec_from_file_location('runner', {str(MODULE)!r})",
                "runner = importlib.util.module_from_spec(spec)",
                "spec.loader.exec_module(runner)",
                "def inside(*_args):",
                "    try:",
                "        pathlib.Path(sys.argv[1]).write_text('ready')",
                "        time.sleep(30)",
                "    finally:",
                "        pathlib.Path(sys.argv[2]).write_text('cleaned')",
                "runner._inside_main = inside",
                "sys.exit(runner.main(['--inside', '--repo-root', '/tmp', '--temp-root', '/tmp',",
                "                      '--head', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',",
                "                      '--tree', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',",
                "                      '--request-id', 'preq_signal', '--mix-path', '/usr/bin/mix',",
                "                      '--runtime-path', '/usr/bin:/bin', '--outside-control-port', '1']))",
            ])
            process = subprocess.Popen([sys.executable, "-I", "-c", script, str(ready), str(cleaned)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       start_new_session=True)
            deadline = time.monotonic() + 3
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(ready.exists(), "inner launcher did not start")
            self.assertTrue(runner._stop_process(process, timeout=3))
            self.assertTrue(cleaned.exists(), "SIGTERM bypassed the inner finally cleanup")

    def _assert_launcher_stops_child(self, launch):
        children = []
        real_popen = subprocess.Popen

        def capture_child(*args, **kwargs):
            child = real_popen([sys.executable, "-c", "import time; time.sleep(30)"],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               start_new_session=True)
            children.append(child)
            return child

        with tempfile.TemporaryDirectory(prefix="h100-launch-failure-") as directory:
            with patch.object(runner, "_setpriv_command", return_value=["unused"]):
                with patch.object(runner, "_process_identity", side_effect=runner.QualificationFailure("identity")):
                    with patch.object(runner.subprocess, "Popen", side_effect=capture_child):
                        with self.assertRaises(runner.QualificationFailure):
                            launch(directory)
        self.assertEqual(len(children), 1)
        self.assertIsNotNone(children[0].poll())
        self.assertTrue(children[0].stdout.closed)


if __name__ == "__main__":
    unittest.main()
