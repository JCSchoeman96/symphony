"""Versioned, payload-free qualification evidence contract tests."""

import copy
import importlib.util
import json
import pathlib
import unittest


ELIXIR_ROOT = pathlib.Path(__file__).parents[2]
RUNNER_PATH = pathlib.Path(__file__).parents[1] / "support/a4/run_h100_local_qualification.py"
SCHEMA_PATH = ELIXIR_ROOT / "priv/h100/evidence_schema.json"
spec = importlib.util.spec_from_file_location("h100_evidence_runner", RUNNER_PATH)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


EVIDENCE_FIELDS = {
    "policy_mechanism", "policy_scope", "pre_spawn_deny_all_verified", "pre_spawn_deny_rule_handle",
    "proof_identity", "relay_identity", "relay_bound_host", "relay_bound_port",
    "relay_listener_socket_inode", "second_exact_port_policy_verified", "stage_b_allow_rule_handle",
    "stage_b_deny_rule_handle", "manifest_sha256", "relay_script_sha256", "provider_request_id",
    "connect_count", "upstream_connection_count", "client_application_data_record_count",
    "origin_request_count", "complete_request", "server_application_data_observed",
    "server_application_data_forwarded", "suppressed_encrypted_record_length",
    "suppressed_encrypted_record_sha256", "finch_result", "retry_count", "replay_count",
    "ipv4_egress_canary", "ipv6_egress_canary", "proof_drop_packets_after_canaries",
    "unrelated_control_exchange", "tls_version", "tls_verify_peer", "tls_hostname_verification",
    "shared_trust_unchanged", "trust_material_removed", "policy_deny_all_restored",
    "policy_table_removed_and_verified", "proof_process_stopped", "relay_process_stopped",
    "origin_process_stopped", "controller_socket_removed", "manifest_finch_absent_before_ready",
    "finch_started_after_ready_validation", "ready_withheld_until_stage_b_verified",
    "non_proof_control_exchange", "implementation_head_sha", "implementation_head_tree",
    "implementation_base", "spec_commit",
    "proof_build_fresh", "proof_build_read_only", "proof_build_source_head_sha",
    "proof_build_source_tree_sha", "proof_build_artifact_count",
    "proof_build_artifact_inventory_sha256", "proof_build_mix_lock_sha256",
}


def _sample(schema, root):
    if "$ref" in schema:
        return _sample(root["$defs"][schema["$ref"].split("/")[-1]], root)
    if "const" in schema:
        return schema["const"]
    schema_type = schema.get("type")
    if schema_type == "object":
        return {key: _sample(schema["properties"][key], root) for key in schema.get("required", [])}
    if schema_type == "array":
        return []
    if schema_type == "integer":
        return schema.get("minimum", 0)
    if schema_type == "boolean":
        return True
    if schema_type == "string":
        pattern = schema.get("pattern")
        if pattern:
            return "a" * int(pattern.rsplit("{", 1)[1].split("}", 1)[0])
        return "x" * max(1, schema.get("minLength", 1))
    raise AssertionError(f"test schema has no sample value for {schema_type}")


def valid_result():
    schema = json.loads(SCHEMA_PATH.read_text(encoding="ascii"))
    return _sample(schema, schema)


class QualificationEvidenceTests(unittest.TestCase):
    def test_schema_is_versioned_and_names_every_evidence_field(self):
        schema = json.loads(SCHEMA_PATH.read_text(encoding="ascii"))
        self.assertEqual(schema["schema_version"], 2)
        self.assertTrue(schema["$id"].endswith("/v2"))
        self.assertEqual(runner.EVIDENCE_SCHEMA_VERSION, 2)
        self.assertEqual(set(schema["properties"]["evidence"]["required"]), EVIDENCE_FIELDS)

    def test_validator_accepts_the_exact_payload_free_evidence_shape(self):
        self.assertEqual(runner.validate_qualification_result(valid_result()), valid_result())

    def test_validator_rejects_payload_secret_and_unknown_fields(self):
        for name in ("authorization", "request_body", "tls_plaintext", "private_key", "unreviewed_field"):
            with self.subTest(name=name):
                result = copy.deepcopy(valid_result())
                result["evidence"][name] = "forbidden"
                with self.assertRaises(runner.QualificationFailure):
                    runner.validate_qualification_result(result)

    def test_validator_rejects_wrong_version_and_unbounded_evidence(self):
        result = valid_result()
        result["schema_version"] = 3
        with self.assertRaises(runner.QualificationFailure):
            runner.validate_qualification_result(result)
        result = valid_result()
        result["evidence"]["provider_request_id"] = "x" * 32_768
        with self.assertRaises(runner.QualificationFailure):
            runner.validate_qualification_result(result)

    def test_validator_requires_the_fresh_build_to_match_the_candidate_sha_and_tree(self):
        for field in ("proof_build_source_head_sha", "proof_build_source_tree_sha"):
            with self.subTest(field=field):
                result = valid_result()
                result["evidence"][field] = "b" * 40
                with self.assertRaises(runner.QualificationFailure):
                    runner.validate_qualification_result(result)


if __name__ == "__main__":
    unittest.main()
