# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""First-divergence report between a legacy and a Zig hourly state dump (plan P2.3).

Dump format (evidence/schema/state-dump-v1.md): text records, one per line,
    <key> <VAR> <index> <value>
key = "init" or "S.R.Y.D.H" (scene, repeat, year, day, hour; integers); index = comma-joined
integers in LEGACY index space (lower bounds per schema, 0 allowed); value = f64 printed with
17 significant digits. Keys must appear in nondecreasing chronological order ("init" first).

A difference is material when |a-b| > abs + rel*max(|a|,|b|) under the variable's rule
(default: exact). Non-finite values and records present on one side only are always material.
Exit 0 = within rules, 1 = divergent, 2 = error. A PASS under unapproved rules is provisional.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import random
import sys
import tempfile

LIMITATIONS = ("Compares only the curated dump variables; agreement does not prove agreement of undumped "
               "state. Tolerances come from the rule table; unapproved rules make the result provisional.")


class DumpError(Exception):
    pass


def parse_key(token: str):
    if token == "init":
        return (-1,)
    parts = token.split(".")
    if len(parts) != 5:
        raise DumpError(f"bad time key {token!r}")
    try:
        return tuple(int(p) for p in parts)
    except ValueError as e:
        raise DumpError(f"bad time key {token!r}") from e


def key_text(key) -> str:
    return "init" if key == (-1,) else ".".join(str(k) for k in key)


def files_of(path: Path) -> list[Path]:
    if path.is_file():
        return [path]
    if not path.is_dir():
        raise DumpError(f"dump path not found: {path}")
    files = [p for p in path.iterdir() if p.is_file() and p.suffix == ".txt"]

    def first_key(p: Path):
        with p.open(encoding="ascii", errors="replace") as f:
            for line in f:
                if line.strip() and not line.startswith("#"):
                    return parse_key(line.split(None, 1)[0])
        return (10**9,)
    return sorted(files, key=first_key)


def hours(path: Path):
    """Yield (key, {(var, index): value}) one time key at a time, enforcing order."""
    current, block, last = None, {}, None
    for f in files_of(path):
        with f.open(encoding="ascii", errors="replace") as fh:
            for n, line in enumerate(fh, 1):
                if not line.strip() or line.startswith("#"):
                    continue
                parts = line.split()
                if len(parts) != 4:
                    raise DumpError(f"{f.name}:{n}: expected 4 fields, got {len(parts)}")
                key = parse_key(parts[0])
                try:
                    value = float(parts[3].replace("D", "E").replace("d", "e"))
                except ValueError as e:
                    raise DumpError(f"{f.name}:{n}: bad value {parts[3]!r}") from e
                if key != current:
                    if current is not None:
                        yield current, block
                    if last is not None and key < last:
                        raise DumpError(f"{f.name}:{n}: key {parts[0]} out of chronological order")
                    current, block, last = key, {}, key
                rec = (parts[1], parts[2])
                if rec in block:
                    raise DumpError(f"{f.name}:{n}: duplicate record {parts[1]}[{parts[2]}] at {parts[0]}")
                block[rec] = value
    if current is not None:
        yield current, block


def load_rules(path: Path | None) -> dict:
    if path is None:
        return {"approved_by": None, "default": {"abs": 0.0, "rel": 0.0}, "variables": {}, "groups": {}}
    rules = json.loads(path.read_text(encoding="utf-8-sig"))
    for name in ("default", "variables"):
        if name not in rules:
            raise DumpError(f"rules missing {name!r}")
    rules.setdefault("groups", {})
    return rules


def group_of(var: str, schema: dict, rules: dict) -> str:
    v = schema.get("variables", {}).get(var, {})
    return v.get("group") or rules.get("groups", {}).get(var) or "ungrouped"


def material(a: float, b: float, rule: dict) -> tuple[bool, float, float]:
    if not (math.isfinite(a) and math.isfinite(b)):
        return True, math.inf, math.inf
    diff = abs(a - b)
    scale = max(abs(a), abs(b))
    rel = diff / scale if scale else 0.0
    return diff > rule.get("abs", 0.0) + rule.get("rel", 0.0) * scale, diff, rel


def compare(legacy: Path, zig: Path, schema: dict, rules: dict, clusters=5, max_examples=10) -> dict:
    groups: dict[str, dict] = {}
    first = None
    compared_keys = compared_records = 0
    last_within = None
    li, zi = hours(legacy), hours(zig)
    lnext, znext = next(li, None), next(zi, None)
    while lnext is not None or znext is not None:
        if znext is None or (lnext is not None and lnext[0] < znext[0]):
            key, lblock, zblock = lnext[0], lnext[1], {}
            lnext = next(li, None)
        elif lnext is None or znext[0] < lnext[0]:
            key, lblock, zblock = znext[0], {}, znext[1]
            znext = next(zi, None)
        else:
            key, lblock, zblock = lnext[0], lnext[1], znext[1]
            lnext, znext = next(li, None), next(zi, None)
        compared_keys += 1
        bad = []
        for rec in sorted(set(lblock) | set(zblock)):
            var, index = rec
            compared_records += 1
            if rec not in lblock or rec not in zblock:
                bad.append({"var": var, "index": index, "kind": "missing_in_" + ("zig" if rec not in zblock else "legacy"),
                            "legacy": lblock.get(rec), "zig": zblock.get(rec), "abs": None, "rel": None})
                continue
            rule = rules["variables"].get(var, rules["default"])
            is_bad, d, r = material(lblock[rec], zblock[rec], rule)
            if is_bad:
                bad.append({"var": var, "index": index, "kind": "value", "legacy": lblock[rec],
                            "zig": zblock[rec], "abs": d, "rel": r})
        if not bad:
            if first is None:
                last_within = key
            continue
        if first is None:
            first = {"key": key_text(key), **bad[0]}
        for item in bad:
            g = group_of(item["var"], schema, rules)
            c = groups.setdefault(g, {"group": g, "first_key": key_text(key), "_key": key, "count_at_first_key": 0,
                                      "worst": None, "examples": []})
            if c["_key"] != key:
                continue  # clusters are characterised at their first divergent key only
            c["count_at_first_key"] += 1
            if len(c["examples"]) < max_examples:
                c["examples"].append(item)
            score = math.inf if item["abs"] is None else item["abs"]
            if c["worst"] is None or score > (math.inf if c["worst"]["abs"] is None else c["worst"]["abs"]):
                c["worst"] = item
    ordered = sorted(groups.values(), key=lambda c: c["_key"])[:clusters]
    for c in ordered:
        c.pop("_key")

    def jsonable(x):
        if isinstance(x, float) and not math.isfinite(x):
            return str(x)
        if isinstance(x, dict):
            return {k: jsonable(v) for k, v in x.items()}
        if isinstance(x, list):
            return [jsonable(v) for v in x]
        return x
    return jsonable({
        "status": "WITHIN_RULES" if first is None else "DIVERGENT",
        "rules_approved": bool(rules.get("approved_by")),
        "provisional": not rules.get("approved_by"),
        "first_divergence": first,
        "last_key_within_rules_before_first_divergence": None if last_within is None else key_text(last_within),
        "earliest_clusters": ordered,
        "compared_keys": compared_keys,
        "compared_records": compared_records,
        "limitations": LIMITATIONS,
    })


# ---------------------------------------------------------------- self-test

def write_dump(path: Path, days: int, variables: dict, perturb=None, init=True, seed=7):
    rng = random.Random(seed)
    base = {(v, i): rng.uniform(-1e3, 1e3) for v, n in variables.items() for i in range(n)}
    with path.open("w", encoding="ascii", newline="\n") as f:
        keys = (["init"] if init else []) + [f"1.1.1.{d}.{h}" for d in range(1, days + 1) for h in range(1, 25)]
        for t, key in enumerate(keys):
            for (v, i), b in base.items():
                val = b * (1 + 1e-4 * t)
                if perturb and perturb["key"] == key and perturb["var"] == v and perturb["index"] == i:
                    val += perturb["delta"]
                f.write(f"{key} {v} {i} {val:.17e}\n")


def selftest() -> dict:
    variables = {"THETA": 12, "TKS": 12, "ORGC": 12, "ZNH4S": 12, "CA": 12}
    schema = {"variables": {"THETA": {"group": "water"}, "TKS": {"group": "heat"}, "ORGC": {"group": "carbon"},
                            "ZNH4S": {"group": "nitrogen"}, "CA": {"group": "salts"}}}
    rules = {"approved_by": "selftest", "default": {"abs": 0.0, "rel": 1e-12},
             "variables": {"TKS": {"abs": 1e-9, "rel": 0.0}}, "groups": {}}
    cases = [
        ("clean", None, "WITHIN_RULES"),
        ("hour_perturbation", {"key": "1.1.1.17.9", "var": "ZNH4S", "index": 5, "delta": 1e-6}, "DIVERGENT"),
        ("init_perturbation", {"key": "init", "var": "CA", "index": 0, "delta": 1e-3}, "DIVERGENT"),
        ("below_tolerance", {"key": "1.1.1.3.3", "var": "TKS", "index": 2, "delta": 1e-10}, "WITHIN_RULES"),
        ("last_hour", {"key": "1.1.1.30.24", "var": "THETA", "index": 11, "delta": 1e-9}, "DIVERGENT"),
    ]
    out = []
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        write_dump(tmp / "legacy.txt", 30, variables)
        for name, p, expected in cases:
            write_dump(tmp / f"{name}.txt", 30, variables, perturb=p)
            r = compare(tmp / "legacy.txt", tmp / f"{name}.txt", schema, rules)
            ok = r["status"] == expected
            if ok and p and expected == "DIVERGENT":
                fd = r["first_divergence"]
                ok = (fd["key"], fd["var"], fd["index"]) == (p["key"], p["var"], str(p["index"]))
                ok = ok and r["earliest_clusters"][0]["group"] == schema["variables"][p["var"]]["group"]
            out.append({"case": name, "expected": expected, "status": r["status"], "ok": ok,
                        "first_divergence": r["first_divergence"]})
        # structural negatives: missing record, out-of-order keys
        (tmp / "missing.txt").write_text("".join(l for l in (tmp / "legacy.txt").read_text().splitlines(True)
                                                 if not l.startswith("1.1.1.2.5 ORGC 3 ")))
        r = compare(tmp / "legacy.txt", tmp / "missing.txt", schema, rules)
        out.append({"case": "missing_record", "ok": r["status"] == "DIVERGENT" and
                    r["first_divergence"]["kind"] == "missing_in_zig" and r["first_divergence"]["key"] == "1.1.1.2.5"})
        (tmp / "order.txt").write_text("1.1.1.2.1 THETA 0 1.0\n1.1.1.1.1 THETA 0 1.0\n")
        try:
            compare(tmp / "order.txt", tmp / "order.txt", schema, rules)
            out.append({"case": "out_of_order_rejected", "ok": False})
        except DumpError:
            out.append({"case": "out_of_order_rejected", "ok": True})
    return {"status": "PASS" if all(c["ok"] for c in out) else "FAIL", "cases": out,
            "window": "30 simulated days x 24 h + init (bounded synthetic)",
            "limitations": "Synthetic dumps only; proves the comparator, not either model's writer."}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("compare")
    c.add_argument("--legacy", type=Path, required=True)
    c.add_argument("--zig", type=Path, required=True)
    c.add_argument("--schema", type=Path, default=Path("evidence/schema/state-dump-v1.json"))
    c.add_argument("--rules", type=Path, default=Path("validation/rules/divcheck-rules.json"))
    c.add_argument("--clusters", type=int, default=5)
    c.add_argument("--out", type=Path)
    sub.add_parser("selftest")
    a = ap.parse_args()
    try:
        if a.cmd == "selftest":
            r = selftest()
            print(json.dumps(r, indent=2))
            return 0 if r["status"] == "PASS" else 1
        schema = json.loads(a.schema.read_text(encoding="utf-8-sig")) if a.schema.exists() else {"variables": {}}
        rules = load_rules(a.rules if a.rules.exists() else None)
        r = compare(a.legacy, a.zig, schema, rules, a.clusters)
        text = json.dumps(r, indent=2)
        if a.out:
            a.out.parent.mkdir(parents=True, exist_ok=True)
            a.out.write_text(text + "\n", encoding="utf-8")
        print(text)
        return 0 if r["status"] == "WITHIN_RULES" else 1
    except (OSError, ValueError, DumpError) as e:
        print(json.dumps({"status": "ERROR", "error": str(e)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
