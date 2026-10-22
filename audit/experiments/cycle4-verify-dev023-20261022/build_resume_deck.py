#!/usr/bin/env python3
"""Build a resume deck from a completed terms deck (checkpoints at hour H).

Usage: build_resume_deck.py <src_deck> <dst_deck>
- Copies the deck tree.
- Sets scene option record 6 (resume_from_checkpoint) to YES in the
  climate_forcing_and_simulation_controls file referenced by the 1998 grid
  (f25y98 in the Ottawa deck).
- Rewrites restart.manifest canonical_root (+Wyhash fingerprint) to
  <dst_deck>/runottawa_output_files, verified against the stored fingerprint.
"""
import re, struct, subprocess, sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
TOOL = REPO / ".tmp/manifest-tool"
HDR = 67
SEED_ROOT_REL = "runottawa_input_files/climate_forcing_and_simulation_controls"


def fingerprint(run_identity: int, root: str) -> int:
    src = TOOL / "gen_fingerprint.zig"
    prev = src.read_text() if src.exists() else None
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
    out = subprocess.run(["zig", "run", str(src), "--cache-dir", str(TOOL / ".zcache")],
                         capture_output=True, text=True, check=True, cwd=str(TOOL))
    return int(out.stderr.strip())


def main() -> None:
    src_deck = Path(sys.argv[1]).resolve()
    dst_deck = Path(sys.argv[2]).resolve()
    if dst_deck.exists():
        sys.exit(f"refusing to overwrite existing {dst_deck}")
    import shutil
    shutil.copytree(src_deck, dst_deck)

    # 1) resume=YES in scene options (record 6 of f25y98)
    opts = dst_deck / SEED_ROOT_REL / "f25y98"
    lines = opts.read_text().splitlines()
    yes_no = [i for i, l in enumerate(lines) if l.strip() in {"YES", "NO"}]
    if len(yes_no) < 3:
        sys.exit("options file: fewer than 3 YES/NO records than expected")
    third = yes_no[2]  # 1=visualization, 2=checkpoint_output, 3=resume
    print(f"resume record at line {third+1}: {lines[third]!r} -> 'YES'")
    lines[third] = "YES"
    opts.write_text("\n".join(lines) + "\n")

    # 2) manifest canonical_root patch with control verification
    mp = dst_deck / "restart.manifest"
    d = mp.read_bytes()
    assert d[:8] == b"ECOSBNDL"
    (rl,) = struct.unpack_from("<I", d, HDR)
    root = d[HDR + 4:HDR + 4 + rl].decode()
    off = HDR + 4 + rl
    (rid,) = struct.unpack_from("<Q", d, off)
    (stored,) = struct.unpack_from("<Q", d, off + 8)
    control = fingerprint(rid, root)
    if control != stored:
        sys.exit(f"control fingerprint mismatch {control} != {stored}; manifest layout drift")
    new_root = str(dst_deck / "runottawa_output_files")
    new_fp = fingerprint(rid, new_root)
    nb = bytearray(d[:HDR])
    nb += struct.pack("<I", len(new_root.encode())) + new_root.encode()
    nb += struct.pack("<Q", rid) + struct.pack("<Q", new_fp) + d[off + 16:]
    mp.write_bytes(bytes(nb))
    (yr,) = struct.unpack_from("<i", d, 20)
    (doy,) = struct.unpack_from("<H", d, 24)
    print(f"manifest instant year={yr} doy={doy} hour={d[26]}")
    print(f"root {root} -> {new_root}")
    print("resume deck ready")


if __name__ == "__main__":
    main()
