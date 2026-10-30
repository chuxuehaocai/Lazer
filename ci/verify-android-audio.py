#!/usr/bin/env python3
"""Verify the native engine that will actually ship, not just CMake output."""

import argparse
import struct
import zipfile
from pathlib import Path

# e_machine values. armeabi-v7a is ELF32; the other two are ELF64.
ABIS = {"arm64-v8a": (2, 183), "armeabi-v7a": (1, 40), "x86_64": (2, 62)}
LIBRARIES = ("liblazer-audio.so", "liblazer-audio-bridge.so")
SYSTEM_LIBRARIES = {
    "libc.so", "libm.so", "libdl.so", "liblog.so", "libandroid.so",
    "libaaudio.so", "libmediandk.so", "libz.so",
}
ENGINE_EXPORTS = {
    "lazer_audio_abi_version", "lazer_audio_create", "lazer_audio_destroy",
    "lazer_audio_open_file_utf8", "lazer_audio_open_reader", "lazer_audio_queue_reader",
    "lazer_audio_clear_queued_reader", "lazer_audio_play", "lazer_audio_pause",
    "lazer_audio_stop", "lazer_audio_seek", "lazer_audio_set_volume",
    "lazer_audio_set_dsp", "lazer_audio_set_device", "lazer_audio_snapshot",
    "lazer_audio_stream_info", "lazer_audio_last_error", "lazer_audio_build_information",
    "lazer_audio_read_log",
}
BRIDGE_EXPORTS = {
    f"lazer_bridge_reader_{name}" for name in (
        "create", "notify", "finish", "destroy", "bytes_available", "read",
        "seek", "length", "close", "cancel",
    )
}


def check(condition, message):
    if not condition:
        raise ValueError(message)


def verify_elf(data, abi, library, bundled=()):
    elf_class, machine_id = ABIS[abi]
    ident = b"\x7fELF" + bytes((elf_class, 1))
    check(len(data) >= 64 and data[:6] == ident, "expected little-endian ELF for " + abi)
    if elf_class == 2:
        header = struct.unpack_from("<HHIQQQIHHHHHH", data, 16)
        section_format, section_size = "<IIQQQQIIQQ", 64
        program_format = "<IIQQQQQQ"
        dynamic_format = "<qQ"
        symbol_format = "<IBBHQQ"
    else:
        header = struct.unpack_from("<HHIIIIIHHHHHH", data, 16)
        section_format, section_size = "<IIIIIIIIII", 40
        program_format = "<IIIIIIII"
        dynamic_format = "<iI"
        symbol_format = "<IIIBBH"
    kind, machine = header[:2]
    check(kind == 3 and machine == machine_id, f"wrong ELF type/architecture: {kind}/{machine}")
    phoff, shoff, phsize, phcount, shsize, shcount = (
        header[4], header[5], header[8], header[9], header[10], header[11]
    )
    # ELF64 stores p_offset before p_vaddr; ELF32 stores p_offset after p_type.
    offset_field, address_field = (2, 3) if elf_class == 2 else (1, 2)
    loads = 0
    for i in range(phcount):
        segment = struct.unpack_from(program_format, data, phoff + phsize * i)
        if segment[0] == 1:
            loads += 1
            check(segment[7] >= 16384, "LOAD segment is not 16KB aligned")
            check(segment[offset_field] % 16384 == segment[address_field] % 16384,
                  "LOAD offset/address alignment mismatch")
    check(loads > 0, "ELF has no loadable segments")
    sections = [struct.unpack_from(section_format, data, shoff + shsize * i)
                for i in range(shcount)]
    check(section_size == shsize, f"unexpected section header size {shsize}")

    def section_bytes(section):
        return data[section[4]:section[4] + section[5]]

    def text(table, index):
        return table[index:].split(b"\0", 1)[0].decode("utf-8")

    exports, dependencies = set(), set()
    for section in sections:
        if section[1] not in (6, 11):
            continue
        strings = section_bytes(sections[section[6]])
        entries = section_bytes(section)
        check(section[9] > 0, "dynamic section has zero-sized entries")
        for offset in range(0, len(entries), section[9]):
            if section[1] == 6:
                tag, value = struct.unpack_from(dynamic_format, entries, offset)
                check(tag != 22 and not (tag == 30 and value & 4), "ELF contains text relocations")
                if tag == 1:
                    dependencies.add(text(strings, value))
            else:
                if elf_class == 2:
                    name, info, _, index, _, _ = struct.unpack_from(symbol_format, entries, offset)
                else:
                    name, _, _, info, _, index = struct.unpack_from(symbol_format, entries, offset)
                if name and index and info >> 4 in (1, 2):
                    exports.add(text(strings, name))
    required = ENGINE_EXPORTS if library == LIBRARIES[0] else BRIDGE_EXPORTS
    check(required <= exports, f"missing ABI exports: {sorted(required - exports)}")
    check(not (dependencies - SYSTEM_LIBRARIES - set(bundled)),
          f"missing runtime dependencies: {sorted(dependencies - SYSTEM_LIBRARIES - set(bundled))}")
    check(not any(name.startswith(("av_", "avcodec_", "avformat_", "swr_", "ff_")) for name in exports),
          "private FFmpeg symbols leaked into the process")
    return f"{abi}/{library}: ABI exports, system dependencies, ELF and 16KB alignment verified"


def main():
    parser = argparse.ArgumentParser()
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--directory", type=Path)
    inputs.add_argument("--apk", type=Path)
    parser.add_argument("--abi", choices=ABIS)
    args = parser.parse_args()
    if args.directory:
        check(args.abi, "--directory requires --abi")
        files = {path.name for path in args.directory.glob("*.so")}
        for library in LIBRARIES:
            print(verify_elf((args.directory / library).read_bytes(), args.abi, library, files))
        return
    with zipfile.ZipFile(args.apk) as apk, args.apk.open("rb") as raw:
        for abi in ABIS:
            files = {Path(name).name for name in apk.namelist() if name.startswith(f"lib/{abi}/")}
            for library in LIBRARIES:
                name = f"lib/{abi}/{library}"
                print(verify_elf(apk.read(name), abi, library, files))
                info = apk.getinfo(name)
                if info.compress_type == zipfile.ZIP_STORED:
                    raw.seek(info.header_offset + 26)
                    filename_size, extra_size = struct.unpack("<HH", raw.read(4))
                    data_offset = info.header_offset + 30 + filename_size + extra_size
                    check(data_offset % 16384 == 0, f"uncompressed APK entry not 16KB aligned: {name}")
            for notice in ("COPYING.LGPLv2.1", "BUILDINFO.txt"):
                check(len(apk.read(f"assets/licenses/lazer-ffmpeg/{abi}/{notice}")) > 0,
                      f"missing FFmpeg notice for {abi}")


if __name__ == "__main__":
    main()
