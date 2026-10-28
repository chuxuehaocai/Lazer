"""Generate tiny stereo DSF DSD64–DSD1024 fixtures for native decoder/seek smoke tests.

The payload is a deterministic first-order sigma-delta tone. It is test data only; the engine probe
decodes it offline and never starts playback, so it is safe to run on speakers.
"""

from __future__ import annotations

import argparse
import math
import struct
from pathlib import Path


BLOCK_BYTES_PER_CHANNEL = 4096
TONE_HZ = 997
AMPLITUDE = 0.35


def make_channel_bits(bit_rate: int, bit_count: int, channel: int) -> bytes:
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


def write_dsf(path: Path, multiplier: int, duration_ms: int) -> None:
    if multiplier not in (64, 128, 256, 512, 1024):
        raise ValueError("DSD multiplier must be 64, 128, 256, 512 or 1024")
    if duration_ms <= 0:
        raise ValueError("duration must be positive")

    bit_rate = 44_100 * multiplier
    bit_count = bit_rate * duration_ms // 1000
    bit_count -= bit_count % 8
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

    channels = [make_channel_bits(bit_rate, bit_count, ch) for ch in range(2)]
    pad_byte = b"\x69"
    with path.open("wb") as output:
        output.write(dsd_header)
        output.write(fmt_chunk)
        output.write(data_header)
        for block in range(blocks):
            start = block * BLOCK_BYTES_PER_CHANNEL
            end = start + BLOCK_BYTES_PER_CHANNEL
            for channel in channels:
                data = channel[start:end]
                output.write(data)
                output.write(pad_byte * (BLOCK_BYTES_PER_CHANNEL - len(data)))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--duration-ms", type=int, default=250)
    parser.add_argument("--rates", type=int, nargs="+", default=[64, 128])
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    for multiplier in args.rates:
        path = args.directory / f"dsd{multiplier}_test.dsf"
        write_dsf(path, multiplier, args.duration_ms)
        print(path)


if __name__ == "__main__":
    main()
