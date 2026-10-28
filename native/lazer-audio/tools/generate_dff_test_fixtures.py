"""Generate tiny stereo DSDIFF 1.5 DSD64–DSD1024 smoke-test fixtures.

Each DFF contains uncompressed, MSB-first DSD bytes interleaved as SLFT, SRGT.
The matching DSF file stores the same channel bitstreams in DSF block-planar order,
so a decoder probe can compare PCM output from the two containers.
"""

from __future__ import annotations

import argparse
import math
import struct
from pathlib import Path


BLOCK_BYTES_PER_CHANNEL = 4096
CHANNEL_IDS = (b"SLFT", b"SRGT")
DSD_MULTIPLIERS = (64, 128, 256, 512, 1024)
TONE_HZ = 997
AMPLITUDE = 0.35


def make_channel_bits(bit_rate: int, bit_count: int, channel: int) -> bytes:
    """Make a deterministic first-order sigma-delta tone, MSB first in each byte."""
    payload = bytearray((bit_count + 7) // 8)
    integrator = 0.0
    previous = -1.0
    phase = 0.0
    phase_step = 2.0 * math.pi * TONE_HZ / bit_rate
    for index in range(bit_count):
        target = AMPLITUDE * math.sin(phase + channel * math.pi / 2.0)
        integrator += target - previous
        one = integrator >= 0.0
        previous = 1.0 if one else -1.0
        if one:
            payload[index // 8] |= 1 << (7 - index % 8)
        phase += phase_step
        if phase >= 2.0 * math.pi:
            phase -= 2.0 * math.pi
    return bytes(payload)


def make_interleaved_dsd(left: bytes, right: bytes) -> bytes:
    if len(left) != len(right):
        raise ValueError("stereo DSD channels must have equal lengths")
    interleaved = bytearray(len(left) * 2)
    for index, (left_byte, right_byte) in enumerate(zip(left, right)):
        interleaved[index * 2] = left_byte
        interleaved[index * 2 + 1] = right_byte
    return bytes(interleaved)


def dff_chunk(chunk_id: bytes, payload: bytes) -> bytes:
    if len(chunk_id) != 4:
        raise ValueError("DSDIFF chunk IDs must contain exactly four bytes")
    # DSDIFF uses 64-bit big-endian sizes. Odd-sized chunks get a zero pad byte;
    # that byte is outside ckDataSize.
    return chunk_id + struct.pack(">Q", len(payload)) + payload + (b"\0" if len(payload) & 1 else b"")


def make_dff(bit_rate: int, channels: tuple[bytes, bytes], odd_extension: bool = False) -> bytes:
    left, right = channels
    interleaved = make_interleaved_dsd(left, right)

    fver = dff_chunk(b"FVER", struct.pack(">I", 0x01050000))
    fs = dff_chunk(b"FS  ", struct.pack(">I", bit_rate))
    chnl = dff_chunk(b"CHNL", struct.pack(">H", 2) + b"".join(CHANNEL_IDS))
    compression_name = b"not compressed"
    cmpr_payload = b"DSD " + bytes((len(compression_name),)) + compression_name
    cmpr = dff_chunk(b"CMPR", cmpr_payload)
    prop = dff_chunk(b"PROP", b"SND " + fs + chnl + cmpr)

    # This optional unknown chunk exercises the mandatory skip-and-pad behavior
    # for readers without complicating the five canonical format fixtures.
    extension = dff_chunk(b"XTRA", b"\xA5\x5A\x01") if odd_extension else b""
    sound = dff_chunk(b"DSD ", interleaved)
    local_chunks = fver + extension + prop + sound
    form_data = b"DSD " + local_chunks
    return b"FRM8" + struct.pack(">Q", len(form_data)) + form_data


def make_mono_odd_dff(bit_rate: int, payload: bytes) -> bytes:
    if len(payload) % 2 != 1:
        raise ValueError("the mono payload fixture must exercise an odd DSD chunk size")
    fver = dff_chunk(b"FVER", struct.pack(">I", 0x01050000))
    fs = dff_chunk(b"FS  ", struct.pack(">I", bit_rate))
    chnl = dff_chunk(b"CHNL", struct.pack(">H", 1) + b"C   ")
    compression_name = b"not compressed"
    cmpr = dff_chunk(b"CMPR", b"DSD " + bytes((len(compression_name),)) + compression_name)
    prop = dff_chunk(b"PROP", b"SND " + fs + chnl + cmpr)
    sound = dff_chunk(b"DSD ", payload)
    form_data = b"DSD " + fver + prop + sound
    return b"FRM8" + struct.pack(">Q", len(form_data)) + form_data


def write_dsf(path: Path, bit_rate: int, bit_count: int,
              channels: tuple[bytes, bytes]) -> None:
    left, right = channels
    audio_bytes_per_channel = bit_count // 8
    blocks = (audio_bytes_per_channel + BLOCK_BYTES_PER_CHANNEL - 1) // BLOCK_BYTES_PER_CHANNEL
    padded_channel_bytes = blocks * BLOCK_BYTES_PER_CHANNEL
    audio_payload_size = padded_channel_bytes * 2
    data_chunk_size = 12 + audio_payload_size
    file_size = 28 + 52 + data_chunk_size

    dsd_header = b"DSD " + struct.pack("<QQQ", 28, file_size, 0)
    fmt_chunk = b"fmt " + struct.pack(
        "<QIIIIIIQI", 52, 1, 0, 2, 2, bit_rate, 8, bit_count, BLOCK_BYTES_PER_CHANNEL
    ) + struct.pack("<I", 0)
    data_header = b"data" + struct.pack("<Q", data_chunk_size)

    with path.open("wb") as output:
        output.write(dsd_header)
        output.write(fmt_chunk)
        output.write(data_header)
        for block in range(blocks):
            start = block * BLOCK_BYTES_PER_CHANNEL
            end = start + BLOCK_BYTES_PER_CHANNEL
            for channel in (left, right):
                data = channel[start:end]
                output.write(data)
                output.write(b"\x69" * (BLOCK_BYTES_PER_CHANNEL - len(data)))


def parse_dff_chunks(data: bytes, start: int, end: int) -> list[tuple[bytes, bytes]]:
    chunks: list[tuple[bytes, bytes]] = []
    offset = start
    while offset < end:
        if offset + 12 > end:
            raise ValueError("truncated DSDIFF chunk header")
        chunk_id, size = struct.unpack_from(">4sQ", data, offset)
        payload_start = offset + 12
        payload_end = payload_start + size
        padded_end = payload_end + (size & 1)
        if payload_end > end or padded_end > end:
            raise ValueError(f"chunk {chunk_id!r} extends beyond its parent")
        if size & 1 and data[payload_end] != 0:
            raise ValueError(f"chunk {chunk_id!r} has a nonzero pad byte")
        chunks.append((chunk_id, data[payload_start:payload_end]))
        offset = padded_end
    if offset != end:
        raise ValueError("chunk list does not end at its parent boundary")
    return chunks


def validate_pair(dff_path: Path, dsf_path: Path, bit_rate: int, bit_count: int,
                  odd_extension: bool = False) -> None:
    dff = dff_path.read_bytes()
    if len(dff) < 16 or dff[:4] != b"FRM8" or dff[12:16] != b"DSD ":
        raise ValueError(f"{dff_path}: invalid FRM8 DSD form header")
    declared_form_size = struct.unpack_from(">Q", dff, 4)[0]
    if declared_form_size != len(dff) - 12:
        raise ValueError(f"{dff_path}: FRM8 size does not match file length")

    root_chunks = parse_dff_chunks(dff, 16, len(dff))
    ids = [chunk_id for chunk_id, _ in root_chunks]
    expected_ids = [b"FVER"] + ([b"XTRA"] if odd_extension else []) + [b"PROP", b"DSD "]
    if ids != expected_ids:
        raise ValueError(f"{dff_path}: unexpected top-level chunk sequence {ids!r}")
    if root_chunks[0][1] != struct.pack(">I", 0x01050000):
        raise ValueError(f"{dff_path}: FVER is not DSDIFF 1.5.0.0")
    if odd_extension and root_chunks[1][1] != b"\xA5\x5A\x01":
        raise ValueError(f"{dff_path}: odd-sized optional extension payload changed")

    prop_payload = root_chunks[-2][1]
    if prop_payload[:4] != b"SND ":
        raise ValueError(f"{dff_path}: PROP type is not SND")
    prop_chunks = parse_dff_chunks(prop_payload, 4, len(prop_payload))
    props = {chunk_id: payload for chunk_id, payload in prop_chunks}
    if len(props) != len(prop_chunks) or set(props) != {b"FS  ", b"CHNL", b"CMPR"}:
        raise ValueError(f"{dff_path}: PROP must contain exactly one FS, CHNL, and CMPR")
    if props[b"FS  "] != struct.pack(">I", bit_rate):
        raise ValueError(f"{dff_path}: FS does not contain the DSD bit rate")
    if props[b"CHNL"] != struct.pack(">H", 2) + b"SLFTSRGT":
        raise ValueError(f"{dff_path}: CHNL is not ordered stereo SLFT/SRGT")
    compression_name = b"not compressed"
    expected_cmpr = b"DSD " + bytes((len(compression_name),)) + compression_name
    if props[b"CMPR"] != expected_cmpr:
        raise ValueError(f"{dff_path}: CMPR is not uncompressed DSD")
    sound_data = root_chunks[-1][1]
    if len(sound_data) != 2 * (bit_count // 8):
        raise ValueError(f"{dff_path}: DSD payload has an unexpected length")

    dsf = dsf_path.read_bytes()
    if len(dsf) < 92 or dsf[:4] != b"DSD " or dsf[28:32] != b"fmt " or dsf[80:84] != b"data":
        raise ValueError(f"{dsf_path}: invalid DSF header")
    dsf_file_size = struct.unpack_from("<Q", dsf, 12)[0]
    data_chunk_size = struct.unpack_from("<Q", dsf, 84)[0]
    dsf_rate = struct.unpack_from("<I", dsf, 56)[0]
    dsf_count = struct.unpack_from("<Q", dsf, 64)[0]
    block_size = struct.unpack_from("<I", dsf, 72)[0]
    if dsf_file_size != len(dsf) or data_chunk_size != len(dsf) - 80:
        raise ValueError(f"{dsf_path}: DSF size fields do not match file length")
    if dsf_rate != bit_rate or dsf_count != bit_count or block_size != BLOCK_BYTES_PER_CHANNEL:
        raise ValueError(f"{dsf_path}: DSF format fields do not match the DFF source")

    audio_bytes_per_channel = bit_count // 8
    blocks = (audio_bytes_per_channel + BLOCK_BYTES_PER_CHANNEL - 1) // BLOCK_BYTES_PER_CHANNEL
    payload_offset = 92
    channels: list[bytearray] = [bytearray(), bytearray()]
    for block in range(blocks):
        valid = min(BLOCK_BYTES_PER_CHANNEL, audio_bytes_per_channel - block * BLOCK_BYTES_PER_CHANNEL)
        for channel_index in range(2):
            channels[channel_index].extend(dsf[payload_offset:payload_offset + valid])
            payload_offset += BLOCK_BYTES_PER_CHANNEL
    if payload_offset != len(dsf):
        raise ValueError(f"{dsf_path}: unexpected trailing DSF data")
    reference_interleaved = make_interleaved_dsd(bytes(channels[0]), bytes(channels[1]))
    if reference_interleaved != sound_data:
        raise ValueError(f"{dff_path} and {dsf_path}: DSD channel bits differ")


def validate_mono_odd(dff_path: Path, bit_rate: int, payload: bytes) -> None:
    data = dff_path.read_bytes()
    if data[:4] != b"FRM8" or data[12:16] != b"DSD ":
        raise ValueError(f"{dff_path}: invalid mono DSDIFF header")
    if struct.unpack_from(">Q", data, 4)[0] != len(data) - 12:
        raise ValueError(f"{dff_path}: mono FRM8 size does not match its file length")
    chunks = parse_dff_chunks(data, 16, len(data))
    if [chunk_id for chunk_id, _ in chunks] != [b"FVER", b"PROP", b"DSD "]:
        raise ValueError(f"{dff_path}: unexpected mono chunk sequence")
    props = parse_dff_chunks(chunks[1][1], 4, len(chunks[1][1]))
    values = {chunk_id: body for chunk_id, body in props}
    expected_cmpr = b"DSD " + bytes((len(b"not compressed"),)) + b"not compressed"
    if values.get(b"FS  ") != struct.pack(">I", bit_rate) or \
            values.get(b"CHNL") != struct.pack(">H", 1) + b"C   " or \
            values.get(b"CMPR") != expected_cmpr:
        raise ValueError(f"{dff_path}: mono PROP metadata is invalid")
    if len(chunks[2][1]) % 2 != 1 or chunks[2][1] != payload:
        raise ValueError(f"{dff_path}: mono DSD payload or odd pad is invalid")


def generate(directory: Path, duration_ms: int, multipliers: list[int]) -> list[Path]:
    if duration_ms <= 0:
        raise ValueError("duration must be positive")
    if not multipliers:
        raise ValueError("at least one DSD multiplier is required")
    unsupported = [value for value in multipliers if value not in DSD_MULTIPLIERS]
    if unsupported:
        raise ValueError(f"unsupported DSD multiplier(s): {unsupported}; choose from {DSD_MULTIPLIERS}")

    directory.mkdir(parents=True, exist_ok=True)
    paths: list[Path] = []
    generated: dict[int, tuple[int, int, tuple[bytes, bytes]]] = {}
    for multiplier in multipliers:
        bit_rate = 44_100 * multiplier
        bit_count = bit_rate * duration_ms // 1000
        bit_count -= bit_count % 8
        if bit_count < 8:
            raise ValueError("duration is too short to produce one complete DSD byte")
        channels = (
            make_channel_bits(bit_rate, bit_count, 0),
            make_channel_bits(bit_rate, bit_count, 1),
        )

        dff_path = directory / f"dff{multiplier}_test.dff"
        dsf_path = directory / f"dsd{multiplier}_reference.dsf"
        dff_path.write_bytes(make_dff(bit_rate, channels))
        write_dsf(dsf_path, bit_rate, bit_count, channels)
        validate_pair(dff_path, dsf_path, bit_rate, bit_count)
        generated[multiplier] = (bit_rate, bit_count, channels)
        paths.extend((dff_path, dsf_path))

    # One extra standards-valid fixture makes readers exercise unknown-chunk
    # skipping and odd-sized chunk padding. It shares audio with the lowest requested rate.
    multiplier = min(multipliers)
    bit_rate, bit_count, channels = generated[multiplier]
    odd_path = directory / f"dff{multiplier}_odd_optional_chunk_test.dff"
    odd_path.write_bytes(make_dff(bit_rate, channels, odd_extension=True))
    validate_pair(odd_path, directory / f"dsd{multiplier}_reference.dsf", bit_rate, bit_count,
                  odd_extension=True)
    paths.append(odd_path)

    mono_payload = make_channel_bits(44_100 * 64, 353 * 8, 0)
    mono_path = directory / "dff64_mono_odd_payload_test.dff"
    mono_path.write_bytes(make_mono_odd_dff(44_100 * 64, mono_payload))
    validate_mono_odd(mono_path, 44_100 * 64, mono_payload)
    paths.append(mono_path)
    return paths


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--duration-ms", type=int, default=250)
    parser.add_argument("--rates", type=int, nargs="+", default=list(DSD_MULTIPLIERS))
    args = parser.parse_args()
    for path in generate(args.directory, args.duration_ms, args.rates):
        print(path)


if __name__ == "__main__":
    main()
