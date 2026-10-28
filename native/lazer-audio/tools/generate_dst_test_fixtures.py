"""Generate small synthetic DSDIFF DST fixtures for local decoder regression tests.

The DSTF payloads use FFmpeg's supported verbatim-DSD frame mode (a zero header byte followed by
interleaved MSB-first DSD bytes). This is a deterministic parser/decoder fixture, not a DST encoder
and not representative of compressed DST coding profiles found in every commercial DFF file.
"""

from __future__ import annotations

import argparse
import struct
from pathlib import Path

from generate_dff_test_fixtures import dff_chunk, make_channel_bits


FRAME_RATE = 75
CHANNEL_IDS = b"SLFTSRGT"


def make_dst_file(
    frame_count: int,
    *,
    multiplier: int = 64,
    frame_rate: int = FRAME_RATE,
    declared_frame_count: int | None = None,
    include_crc: bool = False,
) -> bytes:
    if frame_count <= 0:
        raise ValueError("frame count must be positive")
    if multiplier not in (64, 128, 256, 512, 1024):
        raise ValueError("DSD rate must be 64, 128, 256, 512 or 1024")
    bit_rate = 44_100 * multiplier
    samples_per_frame = (bit_rate // 8) // FRAME_RATE
    bit_count = frame_count * samples_per_frame * 8
    if multiplier == 64:
        left = make_channel_bits(bit_rate, bit_count, 0)
        right = make_channel_bits(bit_rate, bit_count, 1)
    else:
        # Keep high-rate boundary fixtures cheap to generate. The constant DSD patterns are for
        # decoder/rate coverage only; the DSD64 fixture provides the musical-shape smoke test.
        byte_count = bit_count // 8
        left = b"\xff" * byte_count
        right = b"\x00" * byte_count

    fver = dff_chunk(b"FVER", struct.pack(">I", 0x01050000))
    fs = dff_chunk(b"FS  ", struct.pack(">I", bit_rate))
    chnl = dff_chunk(b"CHNL", struct.pack(">H", 2) + CHANNEL_IDS)
    compression_name = b"DST Encoded"
    cmpr = dff_chunk(b"CMPR", b"DST " + bytes((len(compression_name),)) + compression_name)
    prop = dff_chunk(b"PROP", b"SND " + fs + chnl + cmpr)

    frte = dff_chunk(b"FRTE", struct.pack(
        ">IH", frame_count if declared_frame_count is None else declared_frame_count, frame_rate))
    dst_frames = bytearray(frte)
    raw_bytes_per_channel = samples_per_frame
    for frame_index in range(frame_count):
        start = frame_index * raw_bytes_per_channel
        end = start + raw_bytes_per_channel
        interleaved = bytearray(raw_bytes_per_channel * 2)
        left_slice = left[start:end]
        right_slice = right[start:end]
        for byte_index in range(raw_bytes_per_channel):
            interleaved[byte_index * 2] = left_slice[byte_index]
            interleaved[byte_index * 2 + 1] = right_slice[byte_index]
        dst_frames.extend(dff_chunk(b"DSTF", b"\x00" + interleaved))
        if include_crc:
            # Intentionally a structural placeholder. The product must refuse CRC-bearing input
            # until the decoded raw DSD bytes are available for real checksum verification.
            dst_frames.extend(dff_chunk(b"DSTC", b"\0\0\0\0"))
    sound = dff_chunk(b"DST ", bytes(dst_frames))

    form_data = b"DSD " + fver + prop + sound
    return b"FRM8" + struct.pack(">Q", len(form_data)) + form_data


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--frames", type=int, default=75)
    parser.add_argument("--rate", type=int, default=64, choices=(64, 128, 256, 512, 1024))
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    variants = {
        f"dst{args.rate}_verbatim.dff": make_dst_file(args.frames, multiplier=args.rate),
    }
    if args.rate == 64:
        variants.update({
            "dst64_verbatim_crc.dff": make_dst_file(args.frames, include_crc=True),
            "dst64_bad_frame_count.dff": make_dst_file(
                args.frames, declared_frame_count=args.frames + 1),
            "dst64_bad_frame_rate.dff": make_dst_file(args.frames, frame_rate=74),
        })
    for name, contents in variants.items():
        path = args.directory / name
        path.write_bytes(contents)
        print(path)


if __name__ == "__main__":
    main()
