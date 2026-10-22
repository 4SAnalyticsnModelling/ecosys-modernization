#!/usr/bin/env python3
"""Rewrite an ecosys-ng restart.manifest canonical_root for a replay deck copy.

Parses the manifest binary layout written by
ecosys-ng/src/io/checkpoint/manifest.zig write():
  magic ECOSBNDL | u32 version | u64 generation | i32 year | u16 doy | u8 hour |
  u64 execution_iteration | u64 scenario_index | u64 scenario_iteration |
  u64 scene_index | u64 completed_scene_hours |
  u32 canonical_root_len | canonical_root | u64 run_identity | u64 fingerprint | ...
Fingerprints are computed by a Zig helper that calls std.hash.Wyhash with the same
seed/update sequence as outputIdentityFingerprint (verified against the stored value
of the source manifest before any write).
"""
import struct, subprocess, sys, os
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
TOOL = REPO / ".tmp/manifest-tool"
HDR = 8 + 4 + 8 + 4 + 2 + 1 + 5 * 8  # 67 bytes before root length


def fingerprint(run_identity: int, root: str) -> int:
    src = TOOL / "gen_fingerprint.zig"
    src.write_text(
        "const std = @import(\"std\");\n"
        "pub fn main() void {\n"
        f"    const rid: u64 = {run_identity};\n"
        f'    const root: []const u8 = "{root}";\n'
        "    var run_bytes: [@sizeOf(u64)]u8 = undefined;\n"
        "    std.mem.writeInt(u64, &run_bytes, rid, .little);\n"
        "    var hasher = std.hash.Wyhash.init(0x4f5554524f4f5433);\n"
        "    hasher.update(&run_bytes);\n"
        "    hasher.update(root);\n"
        "    std.debug.print(\"{d}\\n\", .{hasher.final()});\n"
        "}\n"
    )
    out = subprocess.run(
        ["zig", "run", str(src), "--cache-dir", str(TOOL / ".zcache")],
        capture_output=True, text=True, check=True,
    )
    return int(out.stderr.strip())


def patch(manifest_path: Path, new_root: str) -> None:
    data = manifest_path.read_bytes()
    assert data[:8] == b"ECOSBNDL", "magic"
    version, = struct.unpack_from("<I", data, 8)
    assert version == 3, f"version {version}"
    (root_len,) = struct.unpack_from("<I", data, HDR)
    root = data[HDR + 4: HDR + 4 + root_len].decode()
    off = HDR + 4 + root_len
    (run_identity,) = struct.unpack_from("<Q", data, off)
    (stored_fp,) = struct.unpack_from("<Q", data, off + 8)
    control = fingerprint(run_identity, root)
    if control != stored_fp:
        sys.exit(f"control fingerprint mismatch: computed {control} stored {stored_fp}")
    new_fp = fingerprint(run_identity, new_root)
    nb = bytearray()
    nb += data[:HDR]
    nb += struct.pack("<I", len(new_root.encode()))
    nb += new_root.encode()
    nb += struct.pack("<Q", run_identity)
    nb += struct.pack("<Q", new_fp)
    nb += data[off + 16:]
    manifest_path.write_bytes(bytes(nb))
    print(f"patched {manifest_path}\n  old_root={root}\n  new_root={new_root}\n  run_identity={run_identity} fp={new_fp}")


if __name__ == "__main__":
    patch(Path(sys.argv[1]), sys.argv[2])
