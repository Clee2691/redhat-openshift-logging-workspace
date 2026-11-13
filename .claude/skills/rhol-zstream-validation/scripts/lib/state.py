"""Persistent state for z-stream QE validation.

Every phase of the validation workflow records its progress here so the run
can resume where it left off and gates are never re-asked. State lives in
``.zstream-validation/state-<target>.json`` (one file per z-stream target).

Library use::

    from scripts.lib.state import load_state, save_state

CLI use (from .sh wrappers; prints JSON to stdout; ``record`` is silent so recorded
values — which may be token-bearing — are never echoed)::

    python3 scripts/lib/state.py <target> get-phase
    python3 scripts/lib/state.py <target> set-phase <phase>
    python3 scripts/lib/state.py <target> record <key> <json>
    python3 scripts/lib/state.py <target> record --replace <key> <json>
    python3 scripts/lib/state.py <target> get <key>
"""

import argparse
import json
import os
import sys
import tempfile

DEFAULT_STATE_DIR = ".zstream-validation"


def _state_path(target, state_dir):
    return os.path.join(state_dir, "state-%s.json" % target)


def _fresh_state(target):
    product, _, z = target.rpartition(".")
    return {
        "target": target,
        "product": product,
        "z": z,
        "phase": "preflight",
        "gates": {},
        "builds": [],
        "comparisons": [],
        "maxosv": [],
        "kubeconfig": None,
        "gangway": [],
        "failures": [],
        "repros": [],
    }


def load_state(target, state_dir=DEFAULT_STATE_DIR):
    """Return saved state for ``target``, or a fresh skeleton if none exists."""
    path = _state_path(target, state_dir)
    if not os.path.exists(path):
        return _fresh_state(target)
    with open(path) as f:
        return json.load(f)


def save_state(state, state_dir=DEFAULT_STATE_DIR):
    """Atomically write ``state`` to ``state-<target>.json``."""
    os.makedirs(state_dir, exist_ok=True)
    path = _state_path(state["target"], state_dir)
    fd, tmp_path = tempfile.mkstemp(dir=state_dir, prefix=".state-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(state, f, indent=2, sort_keys=True)
            f.write("\n")
        os.replace(tmp_path, path)
    except BaseException:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise


def set_phase(state, phase):
    state["phase"] = phase


def record_gate(state, gate, decision):
    """Store a gate decision so it is never re-asked on resume."""
    state["gates"][gate] = decision


def gate_decision(state, gate):
    """Return the stored decision for ``gate``, or None if never asked."""
    return state["gates"].get(gate)


def record_result(state, key, value, replace=False):
    """Append ``value`` under a top-level list key, or set it for scalar keys.

    With ``replace`` and a non-empty list key, the MOST RECENT entry is
    swapped instead — the sanctioned way to correct a bad record without
    hand-editing the state file (re-recording appends, so a plain record
    correction leaves both the wrong and the right entry rendered).
    """
    if isinstance(state.get(key), list):
        if replace and state[key]:
            state[key][-1] = value
        else:
            state[key].append(value)
    else:
        state[key] = value


def record_failure(state, phase, command, error):
    state["failures"].append({"phase": phase, "command": command, "error": error})


def main(argv=None):
    parser = argparse.ArgumentParser(description="z-stream validation state CLI")
    parser.add_argument("target", help="z-stream target, e.g. 6.2.14")
    parser.add_argument(
        "--state-dir",
        default=DEFAULT_STATE_DIR,
        help="state directory (default: %(default)s)",
    )
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("get-phase", help="print the current phase as JSON")
    sub_p = sub.add_parser("set-phase", help="transition to a phase")
    sub_p.add_argument("phase")
    record_p = sub.add_parser("record", help="record a result under a top-level key")
    record_p.add_argument(
        "--replace",
        action="store_true",
        help="replace the most recent entry under a list key instead of "
        "appending (correct a bad record; scalars always replace)",
    )
    record_p.add_argument("key")
    record_p.add_argument("value", help="JSON-encoded value")
    get_p = sub.add_parser("get", help="print the value stored under a key")
    get_p.add_argument("key")
    args = parser.parse_args(argv)

    state = load_state(args.target, state_dir=args.state_dir)

    if args.command == "get-phase":
        print(json.dumps(state["phase"]))
    elif args.command == "set-phase":
        set_phase(state, args.phase)
        save_state(state, state_dir=args.state_dir)
        print(json.dumps(state["phase"]))
    elif args.command == "record":
        try:
            value = json.loads(args.value)
        except json.JSONDecodeError as exc:
            print(
                "record: invalid JSON for key %r: %s" % (args.key, exc), file=sys.stderr
            )
            return 1
        record_result(state, args.key, value, replace=args.replace)
        save_state(state, state_dir=args.state_dir)
    elif args.command == "get":
        print(json.dumps(state.get(args.key)))


if __name__ == "__main__":
    sys.exit(main())
