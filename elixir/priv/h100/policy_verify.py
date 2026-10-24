"""Read effective nftables and process identity without changing policy."""

import json
import os
import argparse
import subprocess
import sys


TABLE = "symphony_h100"
CHAIN = "output"
MAX_RULESET_BYTES = 1_048_576
SYSTEM_PATH = "/usr/sbin:/usr/bin:/sbin:/bin"


class PolicyError(ValueError):
    """The observed effective policy or process identity is invalid."""


def _match(expr, left, right):
    return expr == {"match": {"op": "==", "left": left, "right": right}}


def _parse_rule(rule):
    exprs = rule.get("expr")
    if not isinstance(exprs, list) or len(exprs) < 3 or len(exprs) > 6:
        raise PolicyError("unsupported nftables rule expression")
    handle = rule.get("handle")
    if not isinstance(handle, int) or isinstance(handle, bool) or handle <= 0:
        raise PolicyError("policy rule has no effective nftables handle")
    if not isinstance(exprs[-2], dict) or exprs[-2].get("counter") is None:
        raise PolicyError("policy rules must count matched packets")
    counter = exprs[-2]["counter"]
    if not isinstance(counter, dict) or set(counter) - {"packets", "bytes"}:
        raise PolicyError("malformed nftables counter")
    packets = counter.get("packets", 0)
    byte_count = counter.get("bytes", 0)
    if any(not isinstance(value, int) or value < 0 for value in (packets, byte_count)):
        raise PolicyError("malformed nftables counter values")
    verdict_expr = exprs[-1]
    if verdict_expr not in ({"accept": None}, {"drop": None}):
        raise PolicyError("unsupported nftables verdict")
    verdict = "accept" if "accept" in verdict_expr else "drop"
    tests = exprs[:-2]
    uid = None
    destination = None
    protocol = None
    port = None
    if not tests or not isinstance(tests[0].get("match"), dict):
        raise PolicyError("rule does not begin with a UID match")
    uid_match = tests.pop(0)["match"]
    if (uid_match.get("op") != "==" or
            uid_match.get("left") != {"meta": {"key": "skuid"}} or
            not isinstance(uid_match.get("right"), int) or isinstance(uid_match.get("right"), bool)):
        raise PolicyError("rule has an unsupported UID condition")
    uid = uid_match["right"]
    if tests:
        if not all(isinstance(expr, dict) and isinstance(expr.get("match"), dict) for expr in tests):
            raise PolicyError("allow rule has unsupported match conditions")
        if len(tests) == 2:
            ip_match = tests[0]["match"]
            tcp_match = tests[1]["match"]
            if (ip_match.get("op") != "==" or
                    ip_match.get("left") != {"payload": {"protocol": "ip", "field": "daddr"}} or
                    ip_match.get("right") != "127.0.0.1" or
                    tcp_match.get("op") != "==" or
                    tcp_match.get("left") != {"payload": {"protocol": "tcp", "field": "dport"}} or
                    not isinstance(tcp_match.get("right"), int) or isinstance(tcp_match.get("right"), bool) or
                    not 1 <= tcp_match["right"] <= 65535):
                raise PolicyError("allow rule is wider than exact IPv4 loopback TCP port")
            destination = "127.0.0.1"
            protocol = "tcp"
            port = tcp_match["right"]
            flow = "new"
        elif len(tests) == 3:
            state_match = tests[0]["match"]
            ip_match = tests[1]["match"]
            protocol_match = tests[2]["match"]
            if (state_match.get("op") != "in" or
                    state_match.get("left") != {"ct": {"key": "state"}} or
                    state_match.get("right") != "established" or
                    ip_match.get("op") != "==" or
                    ip_match.get("left") != {"payload": {"protocol": "ip", "field": "daddr"}} or
                    ip_match.get("right") != "127.0.0.1" or
                    protocol_match.get("op") != "==" or
                    protocol_match.get("left") != {"meta": {"key": "l4proto"}} or
                    protocol_match.get("right") != "tcp"):
                raise PolicyError("established return rule is wider than IPv4 loopback TCP")
            destination = "127.0.0.1"
            protocol = "tcp"
            flow = "established"
        else:
            raise PolicyError("allow rule has unsupported match conditions")
    else:
        flow = "all"
    return {"handle": handle, "uid": uid, "destination": destination, "protocol": protocol,
            "port": port, "verdict": verdict, "flow": flow, "packets": packets, "bytes": byte_count}


def parse_effective_ruleset(ruleset, *, proof_uid, proof_port=None, relay_uid=None,
                            fixture_port=None, deny_all=False):
    """Parse the dedicated table and reject unknown rules or policy bypasses."""
    if not isinstance(ruleset, dict) or not isinstance(ruleset.get("nftables"), list):
        raise PolicyError("malformed nftables JSON ruleset")
    tables = [row["table"] for row in ruleset["nftables"] if isinstance(row, dict) and "table" in row
              and row["table"].get("name") == TABLE]
    if (len(tables) != 1 or tables[0].get("family") != "inet" or
            tables[0].get("name") != TABLE):
        raise PolicyError("dedicated inet policy table is missing or ambiguous")
    chains = [row["chain"] for row in ruleset["nftables"] if isinstance(row, dict) and "chain" in row
              and row["chain"].get("table") == TABLE]
    output_chains = [row["chain"] for row in ruleset["nftables"] if isinstance(row, dict) and
                     "chain" in row and row["chain"].get("hook") == "output"]
    if (len(output_chains) != 1 or output_chains[0].get("family") != "inet" or
            output_chains[0].get("table") != TABLE or output_chains[0].get("name") != CHAIN):
        raise PolicyError("another output base chain could change effective policy")
    if (len(chains) != 1 or chains[0].get("family") != "inet" or chains[0].get("name") != CHAIN or
            chains[0].get("type") != "filter" or chains[0].get("hook") != "output" or
            chains[0].get("prio") != 0 or
            chains[0].get("policy") != "accept"):
        raise PolicyError("dedicated output chain is missing or has an unsafe shape")
    raw_rules = [row["rule"] for row in ruleset["nftables"] if isinstance(row, dict) and "rule" in row
                 and row["rule"].get("table") == TABLE]
    if any(rule.get("family") != "inet" or rule.get("chain") != CHAIN for rule in raw_rules):
        raise PolicyError("policy contains rules outside the expected output chain")
    rules = [_parse_rule(rule) for rule in raw_rules]
    expected = []
    if deny_all and proof_port is not None:
        raise PolicyError("deny-all verification cannot allow a proof port")
    if proof_port is not None:
        expected.append({"uid": proof_uid, "destination": "127.0.0.1", "protocol": "tcp",
                         "port": proof_port, "verdict": "accept", "flow": "new"})
    expected.append({"uid": proof_uid, "destination": None, "protocol": None,
                     "port": None, "verdict": "drop", "flow": "all"})
    if relay_uid is not None:
        if relay_uid == proof_uid or (not deny_all and
                                      (fixture_port is None or not 1 <= fixture_port <= 65535)):
            raise PolicyError("invalid relay identity or fixture port")
        if not deny_all:
            expected.append({"uid": relay_uid, "destination": "127.0.0.1", "protocol": "tcp",
                             "port": fixture_port, "verdict": "accept", "flow": "new"})
            expected.append({"uid": relay_uid, "destination": "127.0.0.1", "protocol": "tcp",
                             "port": None, "verdict": "accept", "flow": "established"})
        expected.append({"uid": relay_uid, "destination": None, "protocol": None,
                         "port": None, "verdict": "drop", "flow": "all"})
    observed_shapes = [{key: rule[key] for key in ("uid", "destination", "protocol", "port", "verdict", "flow")}
                       for rule in rules]
    if observed_shapes != expected:
        raise PolicyError("effective policy differs from the exact proof and relay scope")
    proof_drop = next(rule for rule in rules if rule["uid"] == proof_uid and rule["verdict"] == "drop")
    proof_allow = next((rule for rule in rules if rule["uid"] == proof_uid and rule["verdict"] == "accept"), None)
    relay_allow = next((rule for rule in rules if relay_uid is not None and
                        rule["uid"] == relay_uid and rule["verdict"] == "accept" and
                        rule["flow"] == "new"), None)
    relay_return = next((rule for rule in rules if relay_uid is not None and
                         rule["uid"] == relay_uid and rule["flow"] == "established"), None)
    relay_drop = next((rule for rule in rules if relay_uid is not None and
                       rule["uid"] == relay_uid and rule["verdict"] == "drop"), None)
    return {
        "proof_drop": True,
        "proof_drop_rule_handle": proof_drop["handle"],
        "proof_drop_packets": proof_drop["packets"],
        "proof_drop_bytes": proof_drop["bytes"],
        "proof_allow": None if proof_allow is None else {
            "uid": proof_uid, "family": "ipv4", "protocol": "tcp",
            "rule_handle": proof_allow["handle"],
            "destination": "127.0.0.1", "port": proof_allow["port"],
            "packets": proof_allow["packets"], "bytes": proof_allow["bytes"]},
        "relay_allow": None if relay_allow is None else {
            "uid": relay_uid, "family": "ipv4", "protocol": "tcp",
            "rule_handle": relay_allow["handle"],
            "destination": "127.0.0.1", "port": relay_allow["port"],
            "packets": relay_allow["packets"], "bytes": relay_allow["bytes"]},
        "relay_established_return": None if relay_return is None else {
            "uid": relay_uid, "family": "ipv4", "protocol": "tcp", "flow": "established",
            "rule_handle": relay_return["handle"], "destination": "127.0.0.1",
            "packets": relay_return["packets"], "bytes": relay_return["bytes"]},
        "relay_drop": relay_drop is not None,
        "relay_drop_rule_handle": None if relay_drop is None else relay_drop["handle"],
        "relay_drop_packets": None if relay_drop is None else relay_drop["packets"],
        "relay_drop_bytes": None if relay_drop is None else relay_drop["bytes"],
    }


def read_nft_ruleset():
    """Read nftables JSON in the verifier's current network namespace."""
    try:
        result = subprocess.run(["nft", "-a", "-j", "list", "ruleset"], check=True,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=2, env={"PATH": SYSTEM_PATH})
        if len(result.stdout) > MAX_RULESET_BYTES:
            raise PolicyError("nftables state exceeds verifier bound")
        return json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        raise PolicyError("cannot read effective nftables state") from exc


def read_process_identity(pid):
    """Read effective UID, UID map, and network namespace inode from procfs."""
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        raise PolicyError("invalid process PID")
    directory_fd = None
    try:
        directory_fd = os.open(f"/proc/{pid}", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        status_fd = os.open("status", os.O_RDONLY | os.O_CLOEXEC, dir_fd=directory_fd)
        with os.fdopen(status_fd, "r", encoding="ascii") as file:
            status = file.read(16_384)
        uid_map_fd = os.open("uid_map", os.O_RDONLY | os.O_CLOEXEC, dir_fd=directory_fd)
        with os.fdopen(uid_map_fd, "r", encoding="ascii") as file:
            raw_map = file.read(4096)
        netns_inode = os.stat("ns/net", dir_fd=directory_fd).st_ino
        userns_inode = os.stat("ns/user", dir_fd=directory_fd).st_ino
        cgroup_fd = os.open("cgroup", os.O_RDONLY | os.O_CLOEXEC, dir_fd=directory_fd)
        with os.fdopen(cgroup_fd, "r", encoding="ascii") as file:
            cgroup = file.read(4096)
        if len(cgroup) >= 4096:
            raise PolicyError("process cgroup identity exceeds its bound")
    except OSError as exc:
        raise PolicyError("cannot inspect process identity") from exc
    finally:
        if directory_fd is not None:
            os.close(directory_fd)
    uid_line = next((line for line in status.splitlines() if line.startswith("Uid:")), None)
    if uid_line is None:
        raise PolicyError("process status has no UID")
    try:
        values = uid_line.split()
        if len(values) != 5:
            raise ValueError("bad Uid field")
        effective_uid = int(values[2])
        mappings = []
        for line in raw_map.splitlines():
            fields = line.split()
            if len(fields) != 3:
                raise ValueError("bad UID map")
            mappings.append({"inside": int(fields[0]), "outside": int(fields[1]), "length": int(fields[2])})
    except ValueError as exc:
        raise PolicyError("malformed process identity") from exc
    return {"uid": effective_uid, "uid_map": mappings, "netns_inode": netns_inode,
            "userns_inode": userns_inode, "cgroup": cgroup.strip()}


def _mapped_uid(uid, mappings):
    if not isinstance(uid, int) or isinstance(uid, bool) or uid < 0:
        return False
    return sum(1 for entry in mappings
               if entry["inside"] <= uid < entry["inside"] + entry["length"]) == 1


def verify_live_stage_a(*, proof_uid, relay_uid=None, fixture_port=None):
    """Independently inspect deny rules and mapped namespace identity pre-spawn."""
    verifier = read_process_identity(os.getpid())
    if not _mapped_uid(proof_uid, verifier["uid_map"]):
        raise PolicyError("proof UID is not mapped in this network namespace")
    if relay_uid is not None and not _mapped_uid(relay_uid, verifier["uid_map"]):
        raise PolicyError("relay UID is not mapped in this network namespace")
    parsed = parse_effective_ruleset(read_nft_ruleset(), proof_uid=proof_uid,
                                    relay_uid=relay_uid, fixture_port=fixture_port)
    return {"verified": True, "stage": "A", **parsed, "verifier_uid": verifier["uid"],
            "verifier_uid_map": verifier["uid_map"], "netns_inode": verifier["netns_inode"],
            "userns_inode": verifier["userns_inode"], "cgroup": verifier["cgroup"]}


def verify_live_stage_b(*, pid, proof_uid, proof_port, relay_uid=None, fixture_port=None):
    """Independently bind effective rules to the live proof PID and netns."""
    verifier = read_process_identity(os.getpid())
    proof = read_process_identity(pid)
    if proof["uid"] != proof_uid:
        raise PolicyError("proof PID effective UID does not match the policy UID")
    if proof["uid_map"] != verifier["uid_map"]:
        raise PolicyError("proof PID is in a different user namespace")
    if proof["userns_inode"] != verifier["userns_inode"]:
        raise PolicyError("proof PID is in a different user namespace")
    if proof["netns_inode"] != verifier["netns_inode"]:
        raise PolicyError("proof PID is in a different network namespace")
    parsed = parse_effective_ruleset(read_nft_ruleset(), proof_uid=proof_uid, proof_port=proof_port,
                                    relay_uid=relay_uid, fixture_port=fixture_port)
    return {"verified": True, "stage": "B", "pid": pid, "uid": proof_uid,
            "proof_uid_map": proof["uid_map"], "netns_inode": proof["netns_inode"],
            "userns_inode": proof["userns_inode"], "cgroup": proof["cgroup"], **parsed}


def verify_live_deny_all(*, proof_uid, relay_uid=None):
    """Verify that the disposable namespace has no egress exceptions."""
    verifier = read_process_identity(os.getpid())
    if not _mapped_uid(proof_uid, verifier["uid_map"]):
        raise PolicyError("proof UID is not mapped in this network namespace")
    if relay_uid is not None and not _mapped_uid(relay_uid, verifier["uid_map"]):
        raise PolicyError("relay UID is not mapped in this network namespace")
    parsed = parse_effective_ruleset(read_nft_ruleset(), proof_uid=proof_uid,
                                    relay_uid=relay_uid, deny_all=True)
    return {"verified": True, "stage": "DENY_ALL", **parsed,
            "netns_inode": verifier["netns_inode"]}


def verify_table_absent(ruleset):
    """Independently prove that the temporary qualification table is absent."""
    if not isinstance(ruleset, dict) or not isinstance(ruleset.get("nftables"), list):
        raise PolicyError("malformed nftables JSON ruleset")
    for row in ruleset["nftables"]:
        if not isinstance(row, dict):
            continue
        for kind in ("table", "chain", "rule", "set", "map", "element"):
            value = row.get(kind)
            if isinstance(value, dict) and (value.get("table") == TABLE or
                                             kind == "table" and value.get("name") == TABLE):
                raise PolicyError("temporary qualification policy table remains installed")
    return True


def verify_live_table_absent():
    """Read current nftables state without modifying it and require full removal."""
    verify_table_absent(read_nft_ruleset())
    return {"verified": True, "stage": "REMOVED", "policy_table_absent": True}


def main(argv=None):
    parser = argparse.ArgumentParser(add_help=False)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--stage-a", action="store_true")
    group.add_argument("--stage-b", action="store_true")
    group.add_argument("--deny-all", action="store_true")
    group.add_argument("--table-absent", action="store_true")
    parser.add_argument("--proof-uid", type=int)
    parser.add_argument("--relay-uid", type=int)
    parser.add_argument("--fixture-port", type=int)
    parser.add_argument("--proof-pid", type=int)
    parser.add_argument("--proof-port", type=int)
    args = parser.parse_args(argv)
    try:
        if args.stage_a:
            if args.proof_uid is None:
                raise PolicyError("Stage A requires the proof UID")
            result = verify_live_stage_a(proof_uid=args.proof_uid,
                                         relay_uid=args.relay_uid,
                                         fixture_port=args.fixture_port)
        elif args.stage_b:
            if args.proof_uid is None or args.proof_pid is None or args.proof_port is None:
                raise PolicyError("Stage B requires proof PID and port")
            result = verify_live_stage_b(pid=args.proof_pid, proof_uid=args.proof_uid,
                                         proof_port=args.proof_port, relay_uid=args.relay_uid,
                                         fixture_port=args.fixture_port)
        elif args.deny_all:
            if args.proof_uid is None or args.fixture_port is not None:
                raise PolicyError("deny-all verification accepts no fixture exception")
            result = verify_live_deny_all(proof_uid=args.proof_uid, relay_uid=args.relay_uid)
        else:
            if any(value is not None for value in (args.proof_uid, args.relay_uid,
                                                    args.fixture_port, args.proof_pid, args.proof_port)):
                raise PolicyError("table absence verification takes no process or scope arguments")
            result = verify_live_table_absent()
        encoded = json.dumps(result, sort_keys=True, separators=(",", ":")).encode("ascii") + b"\n"
        if len(encoded) > 8192:
            raise PolicyError("verification result exceeds bound")
        sys.stdout.buffer.write(encoded)
        return 0
    except (PolicyError, OSError, ValueError):
        sys.stderr.write("effective host policy verification failed\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
