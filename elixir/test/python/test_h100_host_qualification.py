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
import signal
import tempfile
import time
from unittest.mock import patch


MODULE = pathlib.Path(__file__).parents[1] / "support/a4/run_h100_local_qualification.py"
spec = importlib.util.spec_from_file_location("h100_host_qualification_runner", MODULE)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class HostQualificationLauncherTests(unittest.TestCase):
    def test_proof_build_uses_production_mix_environment(self):
        environment = runner._build_environment(
            "/tmp/h100-proof-build",
            home="/tmp/h100-build-home",
            runtime_path="/runtime/elixir/bin:/runtime/erlang/bin",
        )
        self.assertEqual(environment["MIX_ENV"], "prod")

    def test_candidate_private_source_preflight_rejects_ignored_code_files(self):
        verify = getattr(runner, "verify_private_source_cleanliness", None)
        self.assertTrue(callable(verify), "candidate source preflight ignores private source artifacts")
        with patch.object(runner, "_run_bounded", return_value=b"!! elixir/priv/h100/__pycache__/relay.pyc\n"):
            with self.assertRaises(runner.QualificationFailure):
                verify("/repo")

    def test_candidate_inventory_records_bounded_commit_and_file_lists(self):
        with patch.object(runner, "_run_bounded", side_effect=[b"a" * 40 + b"\n", b"elixir/priv/h100/relay.py\n"]) as run:
            commits, files = runner.candidate_change_inventory("/repo")

        self.assertEqual(commits, ["a" * 40])
        self.assertEqual(files, ["elixir/priv/h100/relay.py"])
        self.assertEqual(run.call_count, 2)

    def test_candidate_inventory_rejects_unbounded_or_unsafe_entries(self):
        with patch.object(runner, "_run_bounded", side_effect=[b"bad\n", b"../private\n"]):
            with self.assertRaises(runner.QualificationFailure):
                runner.candidate_change_inventory("/repo")

    def test_unrelated_control_listener_starts_only_when_requested(self):
        listener, port, result, thread = runner._outer_listener()
        try:
            self.assertFalse(thread.is_alive(), "control accept window began before Stage B")
            thread.start()
            self.assertTrue(runner._outside_control_exchange(port))
            thread.join(2)
            self.assertFalse(thread.is_alive())
            self.assertTrue(result["complete"])
        finally:
            listener.close()
            if thread.is_alive():
                thread.join(2)

    def test_isolated_mix_home_copies_only_hex_and_rebar_tooling(self):
        prepare = getattr(runner, "prepare_isolated_mix_home", None)
        self.assertTrue(callable(prepare), "proof build does not seed its isolated Mix home")
        with tempfile.TemporaryDirectory(prefix="h100-mix-home-") as directory:
            root = pathlib.Path(directory)
            source_home = root / "host-mix"
            target_home = root / "build-home/.mix"
            hex_root = source_home / "archives/hex-2.5.1/hex-2.5.1"
            (hex_root / "ebin").mkdir(parents=True)
            (hex_root / ".elixir").write_text("1.19.5", encoding="ascii")
            (hex_root / "ebin/Elixir.Hex.beam").write_bytes(b"isolated Hex tooling")
            rebar = source_home / "elixir/1-19-otp-28/rebar3"
            rebar.parent.mkdir(parents=True)
            rebar.write_bytes(b"isolated Rebar3 tooling")
            rebar.chmod(0o700)
            (source_home / "hex.config").write_text("credential-sentinel", encoding="ascii")

            result = prepare(str(source_home), str(target_home), rebar_key="1-19-otp-28")

            copied_hex = target_home / "archives/hex-2.5.1/hex-2.5.1"
            copied_rebar = target_home / "elixir/1-19-otp-28/rebar3"
            self.assertEqual(result["hex_version"], "2.5.1")
            self.assertEqual(len(result["hex_archive_sha256"]), 64)
            self.assertEqual(len(result["rebar3_sha256"]), 64)
            self.assertTrue((copied_hex / "ebin/Elixir.Hex.beam").is_file())
            self.assertTrue(copied_rebar.is_file())
            self.assertTrue(copied_rebar.stat().st_mode & 0o100)
            self.assertFalse((target_home / "hex.config").exists())
            self.assertNotIn(
                b"credential-sentinel",
                b"".join(path.read_bytes() for path in target_home.rglob("*") if path.is_file()),
            )

    def test_dependency_copy_is_bounded_writable_and_content_identical(self):
        copy_tree = getattr(runner, "copy_dependency_tree", None)
        self.assertTrue(callable(copy_tree), "proof build does not copy writable dependency sources")
        with tempfile.TemporaryDirectory(prefix="h100-deps-copy-") as directory:
            root = pathlib.Path(directory)
            source = root / "source-deps"
            package = source / "phoenix/priv/installer/templates"
            package.mkdir(parents=True)
            (source / "phoenix/mix.exs").write_text("package-source", encoding="ascii")
            template = package / "core_components.ex.eex"
            template.write_text("template-source", encoding="ascii")
            destination = root / "writable-deps"

            result = copy_tree(str(source), str(destination))

            copied_template = destination / "phoenix/priv/installer/templates/core_components.ex.eex"
            self.assertEqual(result["file_count"], 2)
            self.assertEqual(len(result["source_sha256"]), 64)
            self.assertEqual(copied_template.read_text(encoding="ascii"), "template-source")
            self.assertTrue(os.access(copied_template.parent, os.W_OK))
            copied_template.write_text("compiler-output", encoding="ascii")
            self.assertEqual(template.read_text(encoding="ascii"), "template-source")

    def test_dependency_copy_rejects_symlinks_and_removes_partial_output(self):
        with tempfile.TemporaryDirectory(prefix="h100-deps-link-") as directory:
            root = pathlib.Path(directory)
            source = root / "source-deps"
            source.mkdir()
            (source / "regular.txt").write_text("regular", encoding="ascii")
            (source / "linked.txt").symlink_to(source / "regular.txt")
            destination = root / "writable-deps"

            with self.assertRaises(runner.QualificationFailure):
                runner.copy_dependency_tree(str(source), str(destination))

            self.assertFalse(destination.exists())

    def test_dependency_copy_rejects_dangling_destination_symlink(self):
        with tempfile.TemporaryDirectory(prefix="h100-deps-dangling-") as directory:
            root = pathlib.Path(directory)
            source = root / "source-deps"
            source.mkdir()
            (source / "regular.txt").write_text("regular", encoding="ascii")
            destination = root / "writable-deps"
            dangling_target = root / "future-target"
            destination.symlink_to(dangling_target, target_is_directory=True)

            with self.assertRaises(runner.QualificationFailure):
                runner.copy_dependency_tree(str(source), str(destination))

            self.assertFalse(dangling_target.exists())

    def test_writable_dependency_overlay_requires_the_project_deps_mountpoint(self):
        bind_copy = getattr(runner, "_bind_writable_dependency_copy", None)
        self.assertTrue(callable(bind_copy), "qualification does not bind a writable dependency overlay")
        with tempfile.TemporaryDirectory(prefix="h100-deps-mount-") as directory:
            root = pathlib.Path(directory)
            source = root / "copy"
            target = root / "unexpected-target"
            source.mkdir()
            target.mkdir()

            with self.assertRaises(runner.QualificationFailure):
                bind_copy(str(source), str(target))

    def test_mix_runtime_maps_to_its_rebar_home_key(self):
        key = getattr(runner, "mix_rebar_home_key", None)
        self.assertTrue(callable(key), "proof build cannot select its matching Rebar3 binary")
        self.assertEqual(
            key("/opt/elixir/1.19.3-otp-28/bin/mix"),
            "1-19-otp-28",
        )

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

    def test_outside_control_listener_can_close_before_activation(self):
        listener, _port, result, thread = runner._outer_listener()
        listener.close()
        self.assertFalse(thread.is_alive())
        self.assertFalse(result["complete"])

    def test_cleanup_keeps_policy_and_mounts_when_a_process_group_would_not_stop(self):
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
        with tempfile.TemporaryDirectory(prefix="h100-retained-policy-") as directory:
            temp_root = pathlib.Path(directory) / "active-namespace"
            temp_root.mkdir()
            with patch.object(runner, "_stop_process", side_effect=[False, True]) as stop:
                with patch.object(runner, "_nft_delete_if_present") as remove_policy:
                    with patch.object(runner, "_unmount_repo") as unmount:
                        with self.assertRaisesRegex(runner.QualificationFailure, "cleanup"):
                            runner._cleanup_inside_resources(
                                control_server=controller,
                                processes=(("proof", proof), ("relay", relay)),
                                canaries=(canary,), ca_path=None, cert_directory=None,
                                policy=policy, mount_path=pathlib.Path("/unused"), mounted=True,
                                temp_root=temp_root,
                            )
            self.assertTrue(temp_root.exists(), "resources were removed while a process group remained")
            self.assertEqual(stop.call_count, 2)
            self.assertTrue(controller.closed)
            self.assertTrue(canary.closed)
            remove_policy.assert_not_called()
            unmount.assert_not_called()

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
            root = pathlib.Path(directory)
            build_root = root / "_build/test"
            build_lib = build_root / "lib"
            app_ebin = build_lib / "symphony_elixir/ebin"
            dep_ebin = build_lib / "finch/ebin"
            source_root = root / "project"
            source_root.mkdir()
            app_ebin.mkdir(parents=True)
            dep_ebin.mkdir(parents=True)
            (app_ebin / "symphony.beam").write_bytes(b"application artifact")
            (dep_ebin / "finch.beam").write_bytes(b"dependency artifact")
            inventory = runner.build_artifact_inventory(str(build_root), source_root=str(source_root))
            provenance = {
                "build_lib_path": str(build_lib),
                "source_root": str(source_root),
                "source_head_sha": "a" * 40,
                "source_tree_sha": "b" * 40,
                **inventory,
                "mix_lock_sha256": "c" * 64,
                "hex_version": "2.5.1",
                "hex_archive_sha256": "d" * 64,
                "rebar3_sha256": "e" * 64,
            }
            command = runner.proof_elixir_command(
                "/runtime/elixir/bin/elixir", provenance, "/repo/test/support/proof.exs"
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

    def test_proof_elixir_command_rejects_an_unverified_existing_build(self):
        with tempfile.TemporaryDirectory(prefix="h100-unverified-proof-build-") as directory:
            build_lib = pathlib.Path(directory) / "_build/test/lib"
            for app in ("symphony_elixir", "finch"):
                ebin = build_lib / app / "ebin"
                ebin.mkdir(parents=True)
                (ebin / "stale.beam").write_bytes(b"stale build artifact")

            with self.assertRaises(runner.QualificationFailure):
                runner.proof_elixir_command(
                    "/runtime/elixir/bin/elixir", str(build_lib), "/repo/test/support/proof.exs"
                )

    def test_build_artifact_inventory_rejects_a_symlinked_directory(self):
        with tempfile.TemporaryDirectory(prefix="h100-proof-build-link-") as directory:
            root = pathlib.Path(directory)
            real_build = root / "real-build"
            ebin = real_build / "symphony_elixir/ebin"
            ebin.mkdir(parents=True)
            (ebin / "module.beam").write_bytes(b"compiled module")
            linked_build = root / "linked-build"
            linked_build.symlink_to(real_build, target_is_directory=True)

            with self.assertRaises(runner.QualificationFailure):
                runner.build_artifact_inventory(str(linked_build))

    def test_build_artifact_inventory_binds_mix_symlinks_to_the_candidate_tree(self):
        with tempfile.TemporaryDirectory(prefix="h100-proof-build-source-link-") as directory:
            root = pathlib.Path(directory)
            project = root / "project"
            source_priv = project / "priv"
            (source_priv / "static").mkdir(parents=True)
            (source_priv / "static/asset.txt").write_text("candidate asset", encoding="ascii")
            build = root / "proof-build"
            ebin = build / "lib/app/ebin"
            ebin.mkdir(parents=True)
            (ebin / "module.beam").write_bytes(b"compiled module")
            (build / "lib/app/priv").symlink_to(source_priv, target_is_directory=True)
            (build / "phoenix-colocated/app/node_modules").parent.mkdir(parents=True)
            (build / "phoenix-colocated/app/node_modules").symlink_to(
                project / "assets/node_modules", target_is_directory=True
            )

            inventory = runner.build_artifact_inventory(str(build), source_root=str(project))

            self.assertEqual(inventory["artifact_count"], 3)
            self.assertEqual(len(inventory["artifact_inventory_sha256"]), 64)

    def test_build_artifact_inventory_rejects_symlinks_outside_candidate_and_build(self):
        with tempfile.TemporaryDirectory(prefix="h100-proof-build-escape-") as directory:
            root = pathlib.Path(directory)
            project = root / "project"
            project.mkdir()
            outside = root / "outside"
            outside.mkdir()
            (outside / "asset.txt").write_text("unbound", encoding="ascii")
            build = root / "proof-build"
            ebin = build / "lib/app/ebin"
            ebin.mkdir(parents=True)
            (ebin / "module.beam").write_bytes(b"compiled module")
            (build / "lib/app/priv").symlink_to(outside, target_is_directory=True)

            with self.assertRaises(runner.QualificationFailure):
                runner.build_artifact_inventory(str(build), source_root=str(project))

    def test_fresh_proof_build_compiles_and_hashes_a_dedicated_mix_build(self):
        compile_build = getattr(runner, "compile_fresh_proof_build", None)
        self.assertTrue(callable(compile_build), "qualification lacks a fresh proof build compiler")

        mix_path = runner.shutil.which("mix")
        elixir_path = runner.shutil.which("elixir")
        erlang_path = runner.shutil.which("erl")
        if not all((mix_path, elixir_path, erlang_path)):
            self.skipTest("Mix and its pinned Elixir/Erlang runtime are unavailable")

        with tempfile.TemporaryDirectory(prefix="h100-proof-build-") as directory:
            root = pathlib.Path(directory)
            project = root / "project"
            (project / "lib").mkdir(parents=True)
            (project / "mix.exs").write_text(
                "defmodule BuildFixture.MixProject do\n"
                "  use Mix.Project\n"
                "  def project, do: [app: :build_fixture, version: \"0.1.0\", elixirc_paths: [\"lib\"]]\n"
                "  def application, do: []\n"
                "end\n",
                encoding="utf-8",
            )
            (project / "lib/build_fixture.ex").write_text(
                "defmodule BuildFixture do\n  def ready, do: true\nend\n", encoding="utf-8"
            )
            (project / "mix.lock").write_text("%{}\n", encoding="utf-8")
            stale = project / "_build/test/lib/build_fixture/ebin/stale.beam"
            stale.parent.mkdir(parents=True)
            stale.write_bytes(b"stale repository build")
            build_path = root / "fresh-proof-build"
            runtime_path = runner.runtime_path_for(mix_path, elixir_path, erlang_path)

            result = compile_build(
                mix_path,
                str(project),
                str(build_path),
                home=str(root / "build-home"),
                runtime_path=runtime_path,
                source_head_sha="a" * 40,
                source_tree_sha="b" * 40,
            )

            compiled = build_path / "lib/build_fixture/ebin/Elixir.BuildFixture.beam"
            self.assertTrue(compiled.is_file())
            self.assertEqual(result["build_lib_path"], str(build_path / "lib"))
            self.assertEqual(result["source_root"], str(project))
            self.assertEqual(result["source_head_sha"], "a" * 40)
            self.assertEqual(result["source_tree_sha"], "b" * 40)
            self.assertGreater(result["artifact_count"], 0)
            self.assertEqual(len(result["artifact_inventory_sha256"]), 64)
            self.assertEqual(result["hex_version"], "2.5.1")
            self.assertEqual(len(result["hex_archive_sha256"]), 64)
            self.assertEqual(len(result["rebar3_sha256"]), 64)
            self.assertTrue(stale.is_file(), "fresh compile modified the pre-existing build")
            for path in [build_path, *build_path.rglob("*")]:
                mode = stat.S_IMODE(path.stat().st_mode)
                self.assertEqual(mode & 0o222, 0, f"proof build path is writable: {path.name}")
                if path.is_dir():
                    self.assertEqual(mode & 0o555, 0o555)
                else:
                    self.assertNotEqual(mode & 0o444, 0)

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

    def test_process_group_wait_stops_polling_at_its_deadline(self):
        wait_calls = []

        class StillRunningProcess:
            @staticmethod
            def poll():
                return None

            @staticmethod
            def wait(timeout):
                wait_calls.append(timeout)
                if len(wait_calls) > 1:
                    raise AssertionError("process-group wait continued after its deadline")
                raise subprocess.TimeoutExpired("still-running", timeout)

        with patch.object(runner, "_active_process_group_members", return_value=[]), \
                patch.object(runner.time, "monotonic", side_effect=[0.0, 0.05]):
            self.assertFalse(runner._wait_for_process_group(StillRunningProcess(), 123, 0.05))
        self.assertEqual(len(wait_calls), 1)

    def test_namespace_options_make_controller_pid1_own_descendant_cleanup(self):
        options = runner.namespace_unshare_options()
        self.assertIn("--pid", options)
        self.assertIn("--fork", options)
        self.assertIn("--mount-proc", options)
        self.assertIn("--kill-child=KILL", options)

    def test_outer_cleanup_checks_process_scope_after_launcher_leader_exits(self):
        class Stream:
            def __init__(self):
                self.closed = False

            def close(self):
                self.closed = True

        class ExitedController:
            pid = 43210

            def __init__(self):
                self.stdin = Stream()
                self.stdout = Stream()
                self.poll_result = 137

            def poll(self):
                return self.poll_result

        process = ExitedController()
        failures = []
        with patch.object(runner, "_active_process_group_members", return_value=[43211]) as members:
            with patch.object(runner, "_stop_process") as stop:
                stopped = runner._cleanup_outer_resources(process, failures)

        members.assert_called_once_with(process.pid)
        stop.assert_not_called()
        self.assertIs(stopped, False)
        self.assertEqual(failures, ["namespace_process"])
        self.assertTrue(process.stdin.closed)
        self.assertTrue(process.stdout.closed)

    def test_outer_cleanup_accepts_an_exited_controller_with_an_empty_process_group(self):
        class ExitedController:
            pid = 43210
            stdin = None
            stdout = None

            @staticmethod
            def poll():
                return 0

        process = ExitedController()
        failures = []
        with patch.object(runner, "_active_process_group_members", return_value=[]) as members:
            with patch.object(runner, "_stop_process") as stop:
                stopped = runner._cleanup_outer_resources(process, failures)

        members.assert_called_once_with(process.pid)
        stop.assert_not_called()
        self.assertIs(stopped, True)
        self.assertEqual(failures, [])

    def test_unshare_controller_death_kills_descendants_in_separate_sessions(self):
        unshare = runner.shutil.which("unshare")
        if unshare is None:
            self.skipTest("unshare is unavailable")

        with tempfile.TemporaryDirectory(prefix="h100-pidns-cleanup-") as directory:
            marker = pathlib.Path(directory) / "child-ready"
            script = (
                "import os,pathlib,sys,time\n"
                "pid=os.fork()\n"
                "if pid==0:\n"
                " os.setsid(); pathlib.Path(sys.argv[1]).write_text('ready')\n"
                " while True: time.sleep(1)\n"
                "while not pathlib.Path(sys.argv[1]).exists(): time.sleep(.01)\n"
                "while True: time.sleep(1)\n"
            )
            process = subprocess.Popen(
                [unshare, *runner.namespace_unshare_options(), "--", sys.executable, "-I",
                 "-c", script, str(marker)],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"},
                start_new_session=True,
            )
            child_pid = None
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and not marker.exists() and process.poll() is None:
                    time.sleep(0.01)
                if not marker.exists():
                    _output, error = process.communicate(timeout=3)
                    if b"Operation not permitted" in error:
                        self.skipTest("unprivileged PID namespaces are unavailable")
                    self.fail("PID namespace fixture exited before starting its detached child")

                deadline = time.monotonic() + 1
                while time.monotonic() < deadline and child_pid is None:
                    try:
                        init_pid = int(pathlib.Path(
                            f"/proc/{process.pid}/task/{process.pid}/children"
                        ).read_text().split()[0])
                        children = pathlib.Path(
                            f"/proc/{init_pid}/task/{init_pid}/children"
                        ).read_text().split()
                        if children:
                            child_pid = int(children[0])
                    except (FileNotFoundError, IndexError, ValueError):
                        pass
                    if child_pid is None:
                        time.sleep(0.01)
                self.assertIsNotNone(child_pid, "detached namespace child was not inspectable")
                os.kill(process.pid, signal.SIGKILL)
                _output, error = process.communicate(timeout=5)
                self.assertEqual(process.returncode, -signal.SIGKILL,
                                 error[:256].decode("utf-8", errors="replace"))
                failures = []
                self.assertIs(runner._cleanup_outer_resources(process, failures), True)
                self.assertEqual(failures, [])

                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    stat_path = pathlib.Path(f"/proc/{child_pid}/stat")
                    if not stat_path.exists():
                        break
                    state = stat_path.read_text().rsplit(")", 1)[1].split()[0]
                    if state in ("Z", "X"):
                        break
                    time.sleep(0.01)
                stat_path = pathlib.Path(f"/proc/{child_pid}/stat")
                if stat_path.exists():
                    state = stat_path.read_text().rsplit(")", 1)[1].split()[0]
                    self.assertIn(state, ("Z", "X"), "PID namespace left a runnable descendant")
            finally:
                if process.poll() is None:
                    runner._stop_process(process, timeout=2)
                if process.stderr is not None:
                    process.stderr.close()
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                if child_pid is not None:
                    try:
                        os.kill(child_pid, 9)
                    except ProcessLookupError:
                        pass

    def test_host_reaps_service_owned_private_material_after_controller_death(self):
        unshare = runner.shutil.which("unshare")
        if unshare is None:
            self.skipTest("unshare is unavailable")

        with tempfile.TemporaryDirectory(prefix="h100-reapable-material-") as directory:
            pathlib.Path(directory).chmod(0o711)
            temp_root = pathlib.Path(directory) / "qualification"
            temp_root.mkdir(mode=0o700)
            temp_root.chmod(0o711)
            ready = temp_root / "origin/service-ready"
            uid = runner.ORIGIN_UID
            script = (
                "import importlib.util,os,pathlib,sys,time\n"
                "source=pathlib.Path(sys.argv[1])\n"
                "spec=importlib.util.spec_from_file_location('qualification',source)\n"
                "module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)\n"
                "directory=pathlib.Path(sys.argv[2])/'origin'\n"
                "module._set_reapable_service_directory(directory,int(sys.argv[3]))\n"
                "source_root=pathlib.Path(sys.argv[2])/'source'\n"
                "source_root.mkdir()\n"
                "build_root=pathlib.Path(sys.argv[2])/'proof-build-source'\n"
                "artifact=build_root/'_build/test/lib/sample/ebin/Elixir.Sample.beam'\n"
                "artifact.parent.mkdir(parents=True)\n"
                "artifact.write_bytes(b'compiled-proof-artifact')\n"
                "module._seal_proof_build(build_root,source_root)\n"
                "pid=os.fork()\n"
                "if pid==0:\n"
                " os.setgroups([]);os.setgid(int(sys.argv[3]));os.setuid(int(sys.argv[3]))\n"
                " (directory/'server.key').write_bytes(b'private-key-sentinel')\n"
                " os.chmod(directory/'server.key',0o600)\n"
                " (directory/'service-ready').write_text('ready')\n"
                " while True: time.sleep(1)\n"
                "while True: time.sleep(1)\n"
            )
            process = subprocess.Popen(
                [unshare, *runner.namespace_unshare_options(), "--", sys.executable, "-I",
                 "-c", script, str(MODULE), str(temp_root), str(uid)],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"},
                start_new_session=True,
            )
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and not ready.exists() and process.poll() is None:
                    time.sleep(0.01)
                if not ready.exists():
                    _output, error = process.communicate(timeout=3)
                    if b"Operation not permitted" in error:
                        self.skipTest("unprivileged user and PID namespaces are unavailable")
                    self.fail("service process did not create its private material: " +
                              error[:2048].decode("utf-8", errors="replace"))

                namespace_init = int(pathlib.Path(
                    f"/proc/{process.pid}/task/{process.pid}/children"
                ).read_text().split()[0])
                service_pid = int(pathlib.Path(
                    f"/proc/{namespace_init}/task/{namespace_init}/children"
                ).read_text().split()[0])
                os.kill(process.pid, signal.SIGKILL)
                try:
                    _output, error = process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    for pid in (service_pid, namespace_init):
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    process.communicate(timeout=5)
                    self.fail("namespace controller death left a service process alive")
                self.assertEqual(process.returncode, -signal.SIGKILL,
                                 error[:256].decode("utf-8", errors="replace"))
                private_key = temp_root / "origin/server.key"
                with self.assertRaises(PermissionError):
                    private_key.read_bytes()
                self.assertEqual(private_key.stat().st_mode & 0o777, 0o600)
                build_root = temp_root / "proof-build-source"
                sealed_directory = build_root / "_build/test/lib/sample/ebin"
                self.assertEqual(sealed_directory.stat().st_mode & 0o777, 0o555)
                restore_build = getattr(runner, "restore_host_reapable_build_directories", None)
                self.assertTrue(callable(restore_build),
                                "outer cleanup cannot reap the sealed proof build")
                restore_build(temp_root)
                self.assertEqual(sealed_directory.stat().st_mode & stat.S_IWUSR, stat.S_IWUSR)

                import shutil
                shutil.rmtree(temp_root)
                self.assertFalse(temp_root.exists())
            finally:
                if process.poll() is None:
                    runner._stop_process(process, timeout=2)
                if process.stderr is not None:
                    process.stderr.close()
                if temp_root.exists():
                    for root, directories, _files in os.walk(temp_root):
                        for name in directories:
                            path = pathlib.Path(root) / name
                            if not path.is_symlink() and path.stat().st_uid == os.getuid():
                                path.chmod(path.stat().st_mode | stat.S_IWUSR)
                    import shutil
                    shutil.rmtree(temp_root, ignore_errors=True)

    def test_reapable_service_directory_requires_namespace_root(self):
        with tempfile.TemporaryDirectory(prefix="h100-reapable-directory-") as directory:
            with self.assertRaises(runner.QualificationFailure):
                runner._set_reapable_service_directory(pathlib.Path(directory) / "service", 1203)

    def test_build_cleanup_restores_only_owned_directories_without_following_links(self):
        with tempfile.TemporaryDirectory(prefix="h100-build-reaper-") as directory:
            parent = pathlib.Path(directory)
            temp_root = parent / "qualification"
            temp_root.mkdir()
            build_root = temp_root / "proof-build-source"
            sealed = build_root / "_build/test/lib/sample/ebin"
            sealed.mkdir(parents=True)
            artifact = sealed / "Elixir.Sample.beam"
            artifact.write_bytes(b"compiled-artifact")
            artifact.chmod(0o444)
            outside = parent / "outside"
            outside.mkdir()
            outside.chmod(0o555)
            (build_root / "outside-link").symlink_to(outside, target_is_directory=True)
            for directory_path in (build_root, build_root / "_build", build_root / "_build/test",
                                   build_root / "_build/test/lib", build_root / "_build/test/lib/sample",
                                   sealed):
                directory_path.chmod(0o555)

            self.assertTrue(runner.restore_host_reapable_build_directories(temp_root))

            for directory_path in (build_root, build_root / "_build", build_root / "_build/test",
                                   build_root / "_build/test/lib", build_root / "_build/test/lib/sample",
                                   sealed):
                self.assertTrue(directory_path.stat().st_mode & stat.S_IWUSR)
            self.assertEqual(artifact.stat().st_mode & 0o777, 0o444)
            self.assertEqual(outside.stat().st_mode & 0o777, 0o555)
            self.assertTrue((build_root / "outside-link").is_symlink())

            with patch.object(runner.os, "getuid", return_value=os.getuid() + 1):
                with self.assertRaises(runner.QualificationFailure):
                    runner.restore_host_reapable_build_directories(temp_root)

            import shutil
            shutil.rmtree(temp_root)
            self.assertFalse(temp_root.exists())
            outside.chmod(0o755)

    def test_process_teardown_kills_descendants_after_leader_exits(self):
        with tempfile.TemporaryDirectory(prefix="h100-stop-descendant-") as directory:
            marker = pathlib.Path(directory) / "child-pid"
            child_script = (
                "import os, pathlib, signal, sys, time\n"
                "pid = os.fork()\n"
                "if pid == 0:\n"
                "    signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                "    pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))\n"
                "    time.sleep(30)\n"
                "    os._exit(0)\n"
            )
            process = subprocess.Popen(
                [sys.executable, "-c", child_script, str(marker)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
            )
            child_pid = None
            try:
                self.assertEqual(process.wait(timeout=3), 0)
                deadline = time.monotonic() + 3
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(marker.exists(), "descendant did not start")
                child_pid = int(marker.read_text())
                self.assertTrue(runner._stop_process(process, timeout=0.1))

                deadline = time.monotonic() + 3
                while pathlib.Path(f"/proc/{child_pid}/stat").exists() and time.monotonic() < deadline:
                    stat_line = pathlib.Path(f"/proc/{child_pid}/stat").read_text()
                    if stat_line.rsplit(")", 1)[1].split()[0] == "Z":
                        break
                    time.sleep(0.01)
                stat_path = pathlib.Path(f"/proc/{child_pid}/stat")
                if stat_path.exists():
                    state = stat_path.read_text().rsplit(")", 1)[1].split()[0]
                    self.assertEqual(state, "Z", "surviving descendant remained runnable")
            finally:
                if child_pid is not None:
                    try:
                        os.kill(child_pid, 9)
                    except ProcessLookupError:
                        pass
                try:
                    os.killpg(process.pid, 9)
                except ProcessLookupError:
                    pass

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
                "                      '--runtime-path', '/usr/bin:/bin', '--source-mix-home', '/tmp/mix-home',",
                "                      '--outside-control-port', '1']))",
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
