#!/usr/bin/env python3
"""Zero only validated BSD archive TOC string-table alignment padding."""

import argparse
import os
from pathlib import Path
import stat
import struct
import tempfile


class ArchiveError(ValueError):
    """An archive cannot be safely normalized."""


def require(condition, message):
    if not condition:
        raise ArchiveError(message)


def decimal(field, label):
    value = field.strip()
    require(bool(value) and value.isdigit(), "Invalid " + label)
    return int(value)


def thin_padding(data, base, size):
    end = base + size
    require(data[base:base + 8] == b"!<arch>\n", "Unsupported archive slice")
    members = []
    position = base + 8
    while position < end:
        require(position + 60 <= end, "Truncated member header")
        header = data[position:position + 60]
        require(header[58:60] == b"`\n", "Invalid member header terminator")
        for field, label in ((header[16:28], "date"), (header[28:34], "uid"),
                             (header[34:40], "gid")):
            decimal(field, label)
        mode = header[40:48].strip()
        require(bool(mode) and all(c in b"01234567" for c in mode), "Invalid member mode")
        length = decimal(header[48:58], "member size")
        payload = position + 60
        following = payload + length
        require(following <= end, "Member extends beyond archive")
        name = header[:16].rstrip(b" ")
        if name.startswith(b"#1/"):
            name_length = decimal(name[3:], "extended name size")
            require(0 < name_length <= length, "Invalid extended member name")
            name = data[payload:payload + name_length].rstrip(b"\0")
            payload += name_length
        else:
            require(name not in (b"/", b"//") and not name.startswith(b"/"),
                    "GNU archive names and TOCs are unsupported")
            name = name.removesuffix(b"/")
        require(bool(name) and b"\0" not in name, "Invalid member name")
        members.append((name, position - base, payload, following))
        if length % 2:
            require(following < end and data[following] == 10, "Invalid member alignment byte")
            following += 1
        position = following
    require(position == end and len(members) >= 2, "Archive requires a TOC and object members")
    toc_name, _, start, stop = members[0]
    require(toc_name in (b"__.SYMDEF", b"__.SYMDEF SORTED"),
            "Only 32-bit BSD TOCs are supported")
    objects = set()
    for name, offset, payload, following in members[1:]:
        require(not name.startswith(b"__.SYMDEF"), "Duplicate or unsupported TOC")
        require(following - payload >= 28 and
                data[payload:payload + 4] in (b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe"),
                "Only little-endian Mach-O object members are supported")
        objects.add(offset)
    require(stop - start >= 8, "Truncated TOC")
    ranlib_bytes = struct.unpack_from("<I", data, start)[0]
    require(ranlib_bytes % 8 == 0 and start + 8 + ranlib_bytes <= stop,
            "Invalid ranlib table size")
    string_start = start + 8 + ranlib_bytes
    string_size = struct.unpack_from("<I", data, start + 4 + ranlib_bytes)[0]
    require(string_start + string_size == stop, "Invalid TOC string-table extent")
    intervals = set()
    for position in range(start + 4, start + 4 + ranlib_bytes, 8):
        string_index, member_offset = struct.unpack_from("<II", data, position)
        require(member_offset in objects, "Ranlib reference does not name an object member")
        require(string_index < string_size, "String reference extends beyond TOC")
        require(string_index == 0 or data[string_start + string_index - 1] == 0,
                "String reference starts inside another string")
        terminator = data.find(b"\0", string_start + string_index, stop)
        require(terminator > string_start + string_index, "Empty or unterminated TOC symbol")
        intervals.add((string_index, terminator + 1 - string_start))
    referenced_end = 0
    for left, right in sorted(intervals):
        require(left == referenced_end, "Unreferenced or overlapping TOC strings")
        referenced_end = right
    require(string_size == (referenced_end + 7) // 8 * 8,
            "TOC tail is not at most seven alignment bytes")
    return [(string_start + referenced_end, stop)]


def normalize_bytes(data):
    """Validate all slices first, returning a copy with only TOC tails zeroed."""
    require(len(data) >= 8, "Truncated archive")
    if data[:8] == b"!<arch>\n":
        ranges = thin_padding(data, 0, len(data))
    else:
        formats = {b"\xca\xfe\xba\xbe": (">", False),
                   b"\xbe\xba\xfe\xca": ("<", False),
                   b"\xca\xfe\xba\xbf": (">", True),
                   b"\xbf\xba\xfe\xca": ("<", True)}
        require(data[:4] in formats, "Unsupported archive magic")
        endian, wide = formats[data[:4]]
        count = struct.unpack_from(endian + "I", data, 4)[0]
        entry_size = 32 if wide else 20
        table_end = 8 + count * entry_size
        require(count > 0 and table_end <= len(data), "Invalid fat architecture table")
        slices = []
        architectures = set()
        for index in range(count):
            entry = 8 + index * entry_size
            if wide:
                cpu, subtype, offset, size, alignment, reserved = struct.unpack_from(
                    endian + "IIQQII", data, entry)
                require(reserved == 0, "Nonzero fat64 reserved field")
            else:
                cpu, subtype, offset, size, alignment = struct.unpack_from(endian + "IIIII", data, entry)
            require((cpu, subtype) not in architectures, "Duplicate fat architecture")
            architectures.add((cpu, subtype))
            require(alignment <= 63 and offset % (1 << alignment) == 0,
                    "Invalid fat slice alignment")
            require(offset >= table_end and size >= 8 and offset + size <= len(data),
                    "Fat slice extends beyond archive")
            slices.append((offset, size))
        previous_end = table_end
        for offset, size in sorted(slices):
            require(offset >= previous_end, "Overlapping fat slices")
            previous_end = offset + size
        ranges = []
        for offset, size in slices:
            ranges.extend(thin_padding(data, offset, size))
    output = bytearray(data)
    for start, stop in ranges:
        output[start:stop] = b"\0" * (stop - start)
    return bytes(output)


def normalize_file(path):
    """Replace a fully validated regular file atomically, preserving its mode."""
    path = Path(path)
    original_stat = path.lstat()
    require(stat.S_ISREG(original_stat.st_mode), "Archive must be a regular file")
    original = path.read_bytes()
    normalized = normalize_bytes(original)
    if normalized == original:
        return False
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            os.fchmod(output.fileno(), stat.S_IMODE(original_stat.st_mode))
            output.write(normalized)
            output.flush()
            os.fsync(output.fileno())
        current = path.lstat()
        require((current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns) ==
                (original_stat.st_dev, original_stat.st_ino, original_stat.st_size, original_stat.st_mtime_ns),
                "Archive changed during normalization")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    try:
        normalize_file(args.archive)
    except (ArchiveError, OSError) as error:
        parser.exit(1, "Archive normalization failed: " + str(error) + "\n")


if __name__ == "__main__":
    main()
