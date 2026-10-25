import importlib.util
import concurrent.futures
import copy
import json
import pathlib
import subprocess
import sys
import threading
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).parents[2] / "priv/h100"


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


policy = load("policy_verify")
qualification = load("host_qualification")


def nft_ruleset(proof_uid, port, extra_proof_accept=False):
    next_handle = 0

    def match(left, right):
        return {"match": {"op": "==", "left": left, "right": right}}

    def uid(uid):
        return {"meta": {"key": "skuid"}}

    def rule(expressions):
        nonlocal next_handle
        next_handle += 1
        return {"rule": {"family": "inet", "table": "symphony_h100", "chain": "output",
                         "handle": next_handle, "expr": expressions}}

    proof_match = match(uid(proof_uid), proof_uid)
    drop = rule([proof_match, {"counter": {"packets": 0, "bytes": 0}}, {"drop": None}])
    allow = rule([proof_match,
                  match({"payload": {"protocol": "ip", "field": "daddr"}}, "127.0.0.1"),
                  match({"payload": {"protocol": "tcp", "field": "dport"}}, port),
                  {"counter": {"packets": 0, "bytes": 0}}, {"accept": None}])
    proof_rules = ([allow, drop] if port is not None else [drop])
    rows = [{"metainfo": {"version": "1.1.6", "release_name": "test", "json_schema_version": 1}},
            {"table": {"family": "inet", "name": "symphony_h100"}},
            {"chain": {"family": "inet", "table": "symphony_h100", "name": "output",
                       "type": "filter", "hook": "output", "prio": 0, "policy": "accept"}},
            *proof_rules]
    if extra_proof_accept:
        rows.insert(3, rule([proof_match, {"counter": {"packets": 0, "bytes": 0}}, {"accept": None}]))
    return {"nftables": rows}


class PolicyVerifierTests(unittest.TestCase):
    def test_parses_live_nft_json_for_exact_proof_drop_and_loopback_exception(self):
        ruleset = nft_ruleset(proof_uid=1201, port=43210)
        self.assertEqual(policy.parse_effective_ruleset(ruleset, proof_uid=1201, proof_port=43210), {
            "proof_drop": True, "proof_drop_packets": 0, "proof_drop_bytes": 0,
            "proof_drop_rule_handle": 1,
            "proof_allow": {"uid": 1201, "family": "ipv4", "protocol": "tcp", "rule_handle": 2,
                            "destination": "127.0.0.1", "port": 43210,
                            "packets": 0, "bytes": 0},
            "relay_allow": None,
            "relay_established_return": None,
            "relay_drop": False,
            "relay_drop_rule_handle": None,
            "relay_drop_packets": None, "relay_drop_bytes": None,
        })

    def test_parser_rejects_missing_drop_bypass_and_unexpected_proof_allow(self):
        valid = nft_ruleset(proof_uid=1201, port=None)
        for rules in (valid["nftables"][:-1],
                      nft_ruleset(proof_uid=1201, port=43210, extra_proof_accept=True)["nftables"]):
            with self.subTest(rules=rules), self.assertRaises(policy.PolicyError):
                policy.parse_effective_ruleset({"nftables": rules}, proof_uid=1201)

    def test_parser_rejects_rule_widened_to_any_address_or_non_tcp(self):
        ruleset = nft_ruleset(proof_uid=1201, port=43210)
        accept = ruleset["nftables"][3]["rule"]["expr"]
        accept[1]["match"]["right"] = "0.0.0.0/0"
        with self.assertRaises(policy.PolicyError):
            policy.parse_effective_ruleset(ruleset, proof_uid=1201, proof_port=43210)

    def test_relay_policy_allows_only_fixture_connects_and_established_loopback_replies(self):
        ruleset = nft_ruleset(proof_uid=1201, port=None)

        def match(left, right, op="=="):
            return {"match": {"op": op, "left": left, "right": right}}

        relay_uid = match({"meta": {"key": "skuid"}}, 1202)
        fixture_connect = {"rule": {"family": "inet", "table": "symphony_h100", "chain": "output",
                                    "handle": 2, "expr": [
                                        relay_uid,
                                        match({"payload": {"protocol": "ip", "field": "daddr"}}, "127.0.0.1"),
                                        match({"payload": {"protocol": "tcp", "field": "dport"}}, 44321),
                                        {"counter": {"packets": 0, "bytes": 0}}, {"accept": None}]}}
        established_reply = {"rule": {"family": "inet", "table": "symphony_h100", "chain": "output",
                                     "handle": 3, "expr": [
                                         relay_uid,
                                         match({"ct": {"key": "state"}}, "established", "in"),
                                         match({"payload": {"protocol": "ip", "field": "daddr"}}, "127.0.0.1"),
                                         match({"meta": {"key": "l4proto"}}, "tcp"),
                                         {"counter": {"packets": 0, "bytes": 0}}, {"accept": None}]}}
        relay_drop = {"rule": {"family": "inet", "table": "symphony_h100", "chain": "output",
                              "handle": 4, "expr": [relay_uid, {"counter": {"packets": 0, "bytes": 0}},
                                                      {"drop": None}]}}
        ruleset["nftables"].extend([fixture_connect, established_reply, relay_drop])
        result = policy.parse_effective_ruleset(ruleset, proof_uid=1201,
                                                relay_uid=1202, fixture_port=44321)
        self.assertEqual(result["relay_allow"]["port"], 44321)
        self.assertEqual(result["relay_established_return"]["rule_handle"], 3)
        self.assertEqual(result["relay_established_return"]["destination"], "127.0.0.1")
        self.assertEqual(result["relay_drop_rule_handle"], 4)

        widened = copy.deepcopy(ruleset)
        widened["nftables"][-2]["rule"]["expr"][2]["match"]["right"] = "0.0.0.0/0"
        with self.assertRaises(policy.PolicyError):
            policy.parse_effective_ruleset(widened, proof_uid=1201,
                                           relay_uid=1202, fixture_port=44321)

    def test_parser_rejects_another_output_base_chain(self):
        ruleset = nft_ruleset(proof_uid=1201, port=None)
        ruleset["nftables"].append({"chain": {"family": "inet", "table": "other",
                                                "name": "output", "type": "filter",
                                                "hook": "output", "prio": -10,
                                                "policy": "accept"}})
        with self.assertRaises(policy.PolicyError):
            policy.parse_effective_ruleset(ruleset, proof_uid=1201)

    def test_deny_all_cleanup_shape_has_no_proof_exception(self):
        state = policy.parse_effective_ruleset(nft_ruleset(proof_uid=1201, port=None),
                                               proof_uid=1201, deny_all=True)
        self.assertIsNone(state["proof_allow"])
        with self.assertRaises(policy.PolicyError):
            policy.parse_effective_ruleset(nft_ruleset(proof_uid=1201, port=43210),
                                           proof_uid=1201, proof_port=43210, deny_all=True)

    def test_policy_removal_verifier_accepts_only_absence_of_the_dedicated_table(self):
        self.assertTrue(policy.verify_table_absent({"nftables": [{"metainfo": {"version": "test"}}]}))
        with self.assertRaises(policy.PolicyError):
            policy.verify_table_absent({"nftables": [{"table": {"family": "inet", "name": "symphony_h100"}}]})


class PreflightOrderingTests(unittest.TestCase):
    def test_live_verifier_receives_kernel_snapshot_without_policy_capabilities(self):
        snapshot = b'{"nftables":[]}'
        results = [
            subprocess.CompletedProcess(["nft"], 0, stdout=snapshot),
            subprocess.CompletedProcess(
                ["setpriv"], 0,
                stdout=b'{"verified":true,"verifier_uid":1201,"verifier_cap_eff":0}',
            ),
        ]
        with patch.object(qualification.subprocess, "run", side_effect=results) as run:
            self.assertEqual(qualification._run_verifier(["--table-absent"]), {
                "verified": True, "verifier_uid": 1201, "verifier_cap_eff": 0,
            })

        read_command = run.call_args_list[0].args[0]
        verifier_command = run.call_args_list[1].args[0]
        self.assertEqual(read_command, ["nft", "-a", "-j", "list", "ruleset"])
        self.assertIn("--reuid=1201", verifier_command)
        self.assertIn("--bounding-set=-all", verifier_command)
        self.assertIn("--no-new-privs", verifier_command)
        self.assertNotIn("nft", verifier_command)
        self.assertEqual(run.call_args_list[1].kwargs["input"], snapshot)

    def test_preflight_precedes_beam_spawn_and_ready_starts_relay_then_verifies_policy(self):
        events = []
        ready = {"type": "READY", "provider_request_id": "req", "listen_host": "127.0.0.1",
                 "bound_port": 43210, "python_version": "3.12.0", "script_blob_sha256": "a" * 64,
                 "environment_names": []}

        class Backend:
            def install_stage_a(self): events.append(("install_a",)); return False
            def verify_stage_a(self): events.append(("verify_a",)); return True
            def start_relay(self): events.append(("relay",)); return {"host": "127.0.0.1", "port": 43210, "ready": ready}
            def install_stage_b(self, pid, uid, port): events.append(("install_b", pid, uid, port)); return False
            def verify_stage_b(self, pid, uid, port): events.append(("verify_b", pid, uid, port)); return True
            def revoke_stage_b(self, uid, port): events.append(("revoke_b", uid, port))
            def verify_deny_all(self): events.append(("verify_deny_all",)); return True
            def stop_relay(self): events.append(("stop_relay",))

        session = qualification.preflight(Backend())
        events.append(("spawn_beam",))
        self.assertEqual(session.ready(pid=410, uid=1201, request_id="req"), ready)
        self.assertEqual([item[0] for item in events],
                         ["install_a", "verify_a", "spawn_beam", "relay", "install_b", "verify_b"])

    def test_live_backend_retains_independent_stage_evidence_and_verifies_removal(self):
        backend = qualification.LinuxPolicyBackend(
            proof_uid=1201, relay_uid=1202, fixture_port=44321,
            relay_start=lambda: None, relay_stop=lambda: None,
        )
        stage_a = {"verified": True, "stage": "A", "proof_drop": True, "proof_drop_packets": 2,
                   "proof_drop_bytes": 88, "proof_allow": None,
                   "relay_allow": {"uid": 1202, "port": 44321},
                   "relay_established_return": {"uid": 1202, "destination": "127.0.0.1",
                                                 "flow": "established"},
                   "relay_drop": True, "relay_drop_packets": 0, "relay_drop_bytes": 0,
                   "netns_inode": 99}
        stage_b = {"verified": True, "stage": "B", "pid": 410, "uid": 1201,
                   "netns_inode": 99, "proof_drop": True, "proof_drop_packets": 2,
                   "proof_allow": {"uid": 1201, "port": 43210},
                   "relay_allow": {"uid": 1202, "port": 44321}, "relay_drop": True,
                   "relay_established_return": {"uid": 1202, "destination": "127.0.0.1",
                                                 "flow": "established"},
                   "relay_drop_packets": 0}
        removed = {"verified": True, "stage": "REMOVED", "policy_table_absent": True}
        with patch.object(qualification, "_run_verifier", side_effect=[stage_a, stage_b, removed]):
            self.assertTrue(backend.verify_stage_a())
            self.assertEqual(backend.last_stage_a_evidence, stage_a)
            self.assertTrue(backend.verify_stage_b(410, 1201, 43210))
            self.assertEqual(backend.last_stage_b_evidence, stage_b)
            self.assertTrue(backend.verify_policy_removed())

    def test_stage_b_verifier_failure_revokes_exception_and_verifies_deny_before_stopping_relay(self):
        events = []
        ready = {"type": "READY", "provider_request_id": "req", "listen_host": "127.0.0.1",
                 "bound_port": 43210, "python_version": "3.12.0", "script_blob_sha256": "a" * 64,
                 "environment_names": []}

        class Backend:
            def install_stage_a(self): events.append(("install_a",))
            def verify_stage_a(self): events.append(("verify_a",)); return True
            def start_relay(self): events.append(("relay",)); return {"host": "127.0.0.1", "port": 43210, "ready": ready}
            def install_stage_b(self, pid, uid, port): events.append(("install_b",))
            def verify_stage_b(self, pid, uid, port): events.append(("verify_b",)); return False
            def revoke_stage_b(self, uid, port): events.append(("revoke_b", uid, port))
            def verify_deny_all(self): events.append(("verify_deny_all",)); return True
            def stop_relay(self): events.append(("stop_relay",))

        session = qualification.preflight(Backend())
        with self.assertRaises(qualification.QualificationError):
            session.ready(pid=410, uid=1201, request_id="req")
        self.assertEqual([item[0] for item in events],
                         ["install_a", "verify_a", "relay", "install_b", "verify_b",
                          "revoke_b", "verify_deny_all", "stop_relay"])

    def test_stage_b_session_claim_is_atomic_under_concurrent_ready_calls(self):
        session = qualification.HostQualificationSession(object())
        barrier = threading.Barrier(16)

        def claim(_index):
            barrier.wait(timeout=2)
            return session._claim_ready()

        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
            outcomes = list(pool.map(claim, range(16)))
        self.assertEqual(outcomes.count(True), 1)
        self.assertEqual(outcomes.count(False), 15)


class ProcessIdentityTests(unittest.TestCase):
    def test_process_identity_includes_user_namespace_inode(self):
        identity = policy.read_process_identity(__import__("os").getpid())
        self.assertIsInstance(identity["userns_inode"], int)
        self.assertGreater(identity["userns_inode"], 0)

    def test_stage_b_rejects_process_in_different_user_namespace(self):
        mappings = [{"inside": 0, "outside": 100_000, "length": 65_536}]
        verifier = {"uid": 0, "uid_map": mappings, "netns_inode": 21, "userns_inode": 31}
        proof = {"uid": 1201, "uid_map": mappings, "netns_inode": 21, "userns_inode": 32}
        with (patch.object(policy, "read_process_identity", side_effect=[verifier, proof]),
              patch.object(policy, "read_nft_ruleset", return_value=nft_ruleset(1201, 43210))):
            with self.assertRaises(policy.PolicyError):
                policy.verify_live_stage_b(pid=410, proof_uid=1201, proof_port=43210)


if __name__ == "__main__":
    unittest.main()
