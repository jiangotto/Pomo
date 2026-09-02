#!python3
"""
Convert epdiy waveform header files to Pomo/caster .mi BRAM format.

epdiy format:
  luts[phase][target][from_packed]
  - phase: waveform frame index
  - target: 0-15 (target grayscale)
  - from_packed: 4 bytes, each packs 4 source values
    byte[b] bits[7:6]=source[b*4], [5:4]=source[b*4+1],
            [3:2]=source[b*4+2], [1:0]=source[b*4+3]

Pomo/caster format:
  BRAM: 4096 x 8-bit
  address = {fseq[5:0], target[3:0], source[3:2]}
  within byte: source[1:0]=0→bits[1:0], 1→bits[3:2], 2→bits[5:4], 3→bits[7:6]
  2-bit: 00=NO_DRIVE, 01=DRIVE_BLACK, 10=DRIVE_WHITE

Usage:
  python epdiy_to_mi.py <input_dir_or_file> [-o output_dir] [-r range_index]
"""

import argparse
import os
import re
import sys
from pathlib import Path

# epdiy 2-bit value → caster 2-bit value
# epdiy: 0=NO_DRIVE, 1=DRIVE_BLACK, 2=DRIVE_WHITE, 3=NO_DRIVE/unused
# caster: 0=NO_DRIVE, 1=DRIVE_BLACK, 2=DRIVE_WHITE
EPDIY_TO_CASTER = {0: 0, 1: 1, 2: 2, 3: 0}

# Mode ID → display name
MODE_DISPLAY = {
    0x00: "INIT",
    0x01: "DU",
    0x02: "GC16",
    0x03: "GC16_FAST",
    0x04: "A2",
    0x05: "GL16",
    0x06: "GL16_FAST",
    0x07: "DU4",
    0x0A: "GL4",
    0x10: "WHITE_TO_GL16",
    0x11: "BLACK_TO_GL16",
}

# Mode ID → output filename (used by Pomo)
MODE_FILENAME = {
    0x01: "du",
    0x02: "gc16",
    0x04: "a2",
    0x07: "du4",
    0x05: "gl16",
    0x10: "w2gl16",
    0x11: "b2gl16",
}

BRAM_DEPTH = 4096
DRIVE_NAMES = {0: "--", 1: "BK", 2: "WT", 3: "??"}


def parse_c_header(filepath):
    """Parse an epdiy waveform C header, extracting all data arrays and mode info.

    Returns:
        arrays: dict name → (phases, data) where data is a flat list of bytes
        modes:  dict name → mode_type
        array_modes: dict data_array_name → (mode_type, range_index)
        temp_ranges: list of (min, max) tuples
    """
    # Waveform Studio emits UTF-8 source.  Using the platform default encoding
    # breaks on Windows installations whose default code page is GBK.
    with open(filepath, "r", encoding="utf-8-sig") as f:
        content = f.read()

    # --- Extract data arrays: name[phases][16][4] = {{{...}}} ---
    # Find declarations and extract the brace-enclosed literal
    # Use brace counting to handle nested braces on potentially one very long line
    arrays = {}
    decl_pattern = r"(\w+)\[(\d+)\]\[16\]\[4\]\s*=\s*"
    for m in re.finditer(decl_pattern, content):
        name, phases_str = m.group(1), m.group(2)
        phases = int(phases_str)
        start = m.end()

        # Brace-count to find matching closing }}}
        if start >= len(content) or content[start] != "{":
            continue
        depth = 0
        end = start
        for i in range(start, len(content)):
            if content[i] == "{":
                depth += 1
            elif content[i] == "}":
                depth -= 1
                if depth == 0:
                    end = i + 1
                    break
        literal = content[start:end]
        hex_bytes = [int(v, 16) for v in re.findall(r"0x([0-9a-fA-F]{2})", literal)]
        expected = phases * 16 * 4
        if len(hex_bytes) < expected:
            # C zero-initializes missing aggregate members.  Mirror that
            # behavior so a partially initialized final phase is converted in
            # exactly the same way as epdiy compiles it.
            missing = expected - len(hex_bytes)
            print(
                f"  WARNING: {name}: expected {expected} bytes, got "
                f"{len(hex_bytes)}; padding {missing} trailing zero bytes"
            )
            hex_bytes.extend([0] * missing)
        elif len(hex_bytes) > expected:
            raise ValueError(
                f"{name}: expected {expected} bytes, got {len(hex_bytes)}"
            )
        arrays[name] = (phases, hex_bytes)

    # --- Extract mode type from EpdWaveformMode structs ---
    mode_pattern = r"(\w+)\s*=\s*\{\s*\.type\s*=\s*(\d+)\s*,"
    modes = {}
    for m in re.findall(mode_pattern, content):
        name, type_str = m
        modes[name] = int(type_str)

    # Resolve the actual C object graph instead of guessing the mode from an
    # array name.  Waveform Studio names such as my_gc_25_0 use "25" as a
    # temperature label, whereas older epdiy exports often put the numeric
    # mode ID in that position.
    phase_to_array = {}
    phase_pattern = (
        r"(?:const\s+)?EpdWaveformPhases\s+(\w+)\s*=\s*\{(.*?)\};"
    )
    for phase_name, body in re.findall(phase_pattern, content, re.DOTALL):
        lut_match = re.search(
            r"\.luts\s*=\s*[^;]*?&?(\w+_data)(?:\[0\])?", body
        )
        if lut_match:
            phase_to_array[phase_name] = lut_match.group(1)

    range_members = {}
    range_pattern = (
        r"(?:const\s+)?EpdWaveformPhases\s*\*\s*(\w+)\s*\[\s*\d+\s*\]"
        r"\s*=\s*\{(.*?)\};"
    )
    for range_name, body in re.findall(range_pattern, content, re.DOTALL):
        range_members[range_name] = re.findall(r"&\s*(\w+)", body)

    array_modes = {}
    mode_struct_pattern = (
        r"(?:const\s+)?EpdWaveformMode\s+(\w+)\s*=\s*\{(.*?)\};"
    )
    for mode_name, body in re.findall(mode_struct_pattern, content, re.DOTALL):
        type_match = re.search(r"\.type\s*=\s*(\d+)", body)
        range_match = re.search(
            r"\.range_data\s*=\s*&\s*(\w+)(?:\[0\])?", body
        )
        if not type_match or not range_match:
            continue
        mode_id = int(type_match.group(1))
        for range_idx, phase_name in enumerate(
            range_members.get(range_match.group(1), [])
        ):
            array_name = phase_to_array.get(phase_name)
            if array_name:
                array_modes[array_name] = (mode_id, range_idx)

    # --- Extract temperature intervals ---
    temp_pattern = r"\.min\s*=\s*(-?\d+)\s*,\s*\.max\s*=\s*(-?\d+)"
    temp_ranges = [(int(a), int(b)) for a, b in re.findall(temp_pattern, content)]

    return arrays, modes, array_modes, temp_ranges


def group_by_mode(arrays, array_modes=None):
    """Group data arrays by mode ID.

    Array naming convention: epd_wp_{panel}_{mode_id}_{range_index}_data
    Returns: dict mode_id → list of (range_idx, name, phases, data)
    """
    by_mode = {}
    array_modes = array_modes or {}
    for name, (phases, data) in arrays.items():
        if name in array_modes:
            mode_id, range_idx = array_modes[name]
            by_mode.setdefault(mode_id, []).append(
                (range_idx, name, phases, data)
            )
            continue

        # Strip _data suffix if present
        base = name.replace("_data", "") if name.endswith("_data") else name
        parts = base.rsplit("_", 2)
        if len(parts) >= 3 and parts[-1].isdigit() and parts[-2].isdigit():
            mode_id = int(parts[-2])
            range_idx = int(parts[-1])
        else:
            # Try to parse mode from the mode structs (handled separately)
            continue

        by_mode.setdefault(mode_id, []).append((range_idx, name, phases, data))
    return by_mode


def extract_epdiy_value(data, phase, target, source):
    """Extract 2-bit value from epdiy flat data array.

    data is a flat list: [phases][16][4] → index = phase*64 + target*4 + source//4
    """
    byte_idx = phase * 64 + target * 4 + (source >> 2)
    # bits[7:6] for source%4=0, [5:4] for 1, [3:2] for 2, [1:0] for 3
    shift = 6 - 2 * (source & 3)
    return (data[byte_idx] >> shift) & 0x3


def convert_to_caster(data, num_phases):
    """Convert epdiy waveform data to caster BRAM format.

    Args:
        data: flat list of bytes [phases * 16 * 4]
        num_phases: number of waveform phases

    Returns:
        bytearray of 4096 bytes in caster BRAM layout
    """
    if not 0 <= num_phases <= 64:
        raise ValueError(
            f"waveform has {num_phases} phases; FPGA LUT supports at most 64"
        )

    bram = bytearray(BRAM_DEPTH)

    for p in range(num_phases):
        for t in range(16):
            for s_hi in range(4):  # source[3:2]
                caster_byte = 0
                for s_lo in range(4):  # source[1:0]
                    s = (s_hi << 2) | s_lo

                    epd_val = extract_epdiy_value(data, p, t, s)
                    caster_val = EPDIY_TO_CASTER[epd_val]
                    # source[1:0] determines bit position in caster byte
                    caster_byte |= caster_val << (2 * s_lo)

                # BRAM address = {fseq[5:0], target[3:0], source[3:2]}
                addr = (p << 6) | (t << 2) | s_hi
                bram[addr] = caster_byte

    return bram


def convert_combined_wb(black_data, black_phases, white_data, white_phases):
    """Merge BLACK_TO_GL16 and WHITE_TO_GL16 into one BRAM via OR.

    BLACK data occupies source=0 (byte[0] bits[7:6]).
    WHITE data occupies source=15 (byte[3] bits[1:0]).
    No overlap — safe to OR.
    """
    black_bram = convert_to_caster(black_data, black_phases)
    white_bram = convert_to_caster(white_data, white_phases)
    bram = bytearray(BRAM_DEPTH)
    for i in range(BRAM_DEPTH):
        bram[i] = black_bram[i] | white_bram[i]
    return bram


def read_mi(filepath):
    """Read .mi file, return list of byte values."""
    bram = []
    with open(filepath, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            bram.append(int(line, 16))
    return bram


def extract_drive_from_bram(bram, phase, target, source):
    """Extract 2-bit drive value from caster BRAM layout."""
    s_hi = source >> 2
    s_lo = source & 3
    addr = (phase << 6) | (target << 2) | s_hi
    if addr >= len(bram):
        return 0
    return (bram[addr] >> (2 * s_lo)) & 3


def read_csv_to_bram(csv_path):
    """Read CSV (source,target,phase0,...) back to caster BRAM format."""
    bram = bytearray(BRAM_DEPTH)
    phases = 0
    with open(csv_path, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split(",")
            if len(parts) < 3:
                continue
            src = int(parts[0])
            tgt = int(parts[1])
            vals = [int(v) for v in parts[2:]]
            phases = len(vals)
            s_hi = src >> 2
            s_lo = src & 3
            for p in range(phases):
                addr = (p << 6) | (tgt << 2) | s_hi
                bram[addr] = (bram[addr] & ~(3 << (2 * s_lo))) | (vals[p] << (2 * s_lo))
    return bram, phases


def write_csv(bram, path, num_phases):
    """Write bram to CSV: source,target,phase0,phase1,...,phaseN-1"""
    with open(path, "w") as f:
        for s in range(16):
            for t in range(16):
                vals = [str(extract_drive_from_bram(bram, p, t, s)) for p in range(num_phases)]
                f.write(f"{s},{t},{','.join(vals)}\n")
    print(f"  -> {path}")


def write_mi(bram, path, comment=""):
    """Write bytearray to Gowin .mi (Memory Initialization) file."""
    with open(path, "w") as f:
        f.write("#File_format=Hex\n")
        f.write("#Address_depth=4096\n")
        f.write("#Data_width=8\n")
        if comment:
            f.write(f"# {comment}\n")
        f.write("\n".join(f"{b:02x}" for b in bram))
        f.write("\n")
    print(f"  -> {path}")

def select_range_entry(entries, requested):
    """Select a mode entry by actual suffix first, then by sorted ordinal."""
    entries = sorted(entries, key=lambda e: e[0])

    for entry in entries:
        if entry[0] == requested:
            return entry, f"suffix {requested}"

    if 0 <= requested < len(entries):
        entry = entries[requested]
        return entry, f"ordinal {requested} -> suffix {entry[0]}"

    available = ", ".join(str(e[0]) for e in entries)
    raise ValueError(
        f"range {requested} not found; available suffixes: {available}; "
        f"or use ordinal 0..{len(entries) - 1}"
    )


def format_temp_interval(range_idx, temp_ranges):
    if 0 <= range_idx < len(temp_ranges):
        tmin, tmax = temp_ranges[range_idx]
        return f", temp {tmin}C..{tmax}C"
    return ""


def main():
    parser = argparse.ArgumentParser(
        description="Convert epdiy waveform C headers to Pomo .mi BRAM files"
    )
    parser.add_argument(
        "input", nargs="?", default=None,
        help="Input .h file or directory containing .h files",
    )
    parser.add_argument(
        "-o", "--output", default="./output",
        help="Output directory for .mi files (default: ./output)",
    )
    parser.add_argument(
        "-r", "--range", type=int, default=0,
        help=(
            "Temperature range selector. Exact array suffix wins; otherwise "
            "0..N-1 selects the sorted entry ordinal (default: 0)."
        ),
    )
    parser.add_argument(
        "-l", "--list", action="store_true",
        help="List all modes and temperature ranges found, then exit",
    )
    parser.add_argument(
        "-d", "--dump", default=None, metavar="MI_FILE",
        help="Dump a .mi file to readable CSV, then exit",
    )
    parser.add_argument(
        "-p", "--phases", type=int, default=30,
        help="Number of phases when dumping .mi (default: 30)",
    )
    parser.add_argument(
        "--csv2mi", default=None, metavar="CSV_FILE",
        help="Convert a CSV file back to .mi, then exit",
    )
    args = parser.parse_args()

    # --- CSV→MI mode ---
    if args.csv2mi:
        csv_path = Path(args.csv2mi)
        if not csv_path.exists():
            print(f"ERROR: {args.csv2mi} not found")
            sys.exit(1)
        bram, phases = read_csv_to_bram(str(csv_path))
        print(f"Read {phases} phases from {csv_path.name}")
        mi_path = csv_path.with_suffix(".mi")
        write_mi(bram, str(mi_path), f"Converted from {csv_path.name}, {phases} phases")
        sys.exit(0)

    # --- Dump mode: convert .mi → .csv and exit ---
    if args.dump:
        mi_path = Path(args.dump)
        if not mi_path.exists():
            print(f"ERROR: {args.dump} not found")
            sys.exit(1)
        bram = read_mi(str(mi_path))
        print(f"Read {len(bram)} bytes from {mi_path.name}")
        csv_path = mi_path.with_suffix(".csv")
        write_csv(bram, str(csv_path), args.phases)
        sys.exit(0)

    if not args.input:
        parser.print_help()
        sys.exit(1)

    input_path = Path(args.input)
    if input_path.is_file():
        h_files = [input_path]
    elif input_path.is_dir():
        h_files = sorted(
            list(input_path.glob("*.h")) + list(input_path.glob("*.c"))
        )
    else:
        print(f"ERROR: {args.input} not found")
        sys.exit(1)

    if not h_files:
        print(f"No .h files found")
        sys.exit(1)

    # Collect all data across files
    all_arrays = {}
    all_modes = {}
    all_array_modes = {}
    all_temp_ranges = []

    for h_file in h_files:
        print(f"Parsing: {h_file.name}")
        arrays, modes, array_modes, temp_ranges = parse_c_header(str(h_file))
        all_arrays.update(arrays)
        all_modes.update(modes)
        all_array_modes.update(array_modes)
        if temp_ranges:
            all_temp_ranges = temp_ranges  # use last one

        for name, (phases, _) in arrays.items():
            print(f"  {name}: {phases} phases")

    if not all_arrays:
        print("No waveform data found")
        sys.exit(1)

    # Print temperature ranges from the header, if present.
    if all_temp_ranges:
        print(f"\nTemperature intervals in header:")
        for i, (tmin, tmax) in enumerate(all_temp_ranges):
            print(f"  [{i}] {tmin}C to {tmax}C")

    # Group data by mode ID
    by_mode = group_by_mode(all_arrays, all_array_modes)

    if args.list:
        print(f"\nModes found:")
        for mode_id, entries in sorted(by_mode.items()):
            mode_name = MODE_DISPLAY.get(mode_id, f"UNKNOWN({mode_id})")
            ranges = [e[0] for e in entries]
            print(f"  Mode 0x{mode_id:02X} ({mode_name}): ranges {ranges}")
        sys.exit(0)

    # Convert each mode
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    print(f"\nConverting (range selector [{args.range}]):")

    for mode_id, entries in sorted(by_mode.items()):
        mode_name = MODE_DISPLAY.get(mode_id, f"UNKNOWN")
        out_base = MODE_FILENAME.get(mode_id, f"mode_{mode_id:02X}")

        try:
            selected_entry, range_note = select_range_entry(entries, args.range)
        except ValueError as exc:
            print(f"ERROR: Mode 0x{mode_id:02X} ({mode_name}): {exc}")
            sys.exit(1)

        range_idx, name, phases, data = selected_entry
        temp_note = format_temp_interval(range_idx, all_temp_ranges)
        print(f"  Mode 0x{mode_id:02X} ({mode_name}): "
              f"{phases} phases, {range_note}{temp_note} -> {out_base}.mi")

        bram = convert_to_caster(data, phases)
        write_mi(
            bram,
            output_dir / f"{out_base}.mi",
            f"{mode_name}, {phases} phases, range suffix [{range_idx}]{temp_note}",
        )
        write_csv(bram, str(output_dir / f"{out_base}.csv"), phases)

    # Generate combined BLACK+WHITE LUT for AUTO_LUT mode
    if 0x10 in by_mode and 0x11 in by_mode:
        print(f"\n  Generating combined WHITE+BLACK LUT for AUTO_LUT...")
        try:
            w_entry, _ = select_range_entry(by_mode[0x10], args.range)
            b_entry, _ = select_range_entry(by_mode[0x11], args.range)
        except ValueError as exc:
            print(f"  WARNING: cannot generate combined LUT: {exc}")
        else:
            _, _, w_phases, w_data = w_entry
            _, _, b_phases, b_data = b_entry
            combined = convert_combined_wb(b_data, b_phases, w_data, w_phases)
            combined_phases = max(b_phases, w_phases)
            write_mi(
                combined,
                output_dir / "autolut.mi",
                f"Combined BLACK_TO_GL16({b_phases}p) + WHITE_TO_GL16({w_phases}p) for AUTO_LUT",
            )
            write_csv(combined, str(output_dir / "autolut.csv"), combined_phases)

    print(f"\nDone. Output in: {output_dir}")
    print(
        "Copy the selected .mi file to Firmware/V2/waveform, update "
        "gowin_prom_lut16.ipc MEM_FILE, and set LUT_FRAMES to its phase count."
    )


if __name__ == "__main__":
    main()
