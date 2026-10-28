/* Pure byte-layout tests for ALSA output packing. Passing these tests does not verify an ALSA
 * device, driver negotiation, sample clock, or DAC input. */
#include <cstdint>
#include <cstdio>
#include <initializer_list>
#include <string>
#include <vector>

#include "alsa_pcm_packing.h"

namespace {

bool expectBytes(const char *name, const std::vector<uint8_t> &actual,
    std::initializer_list<uint8_t> expected) {
    if (actual == std::vector<uint8_t>(expected)) return true;

    std::fprintf(stderr, "FAIL: %s byte mismatch; got", name);
    for (const uint8_t byte : actual) std::fprintf(stderr, " %02x", byte);
    std::fprintf(stderr, "; expected");
    for (const uint8_t byte : expected) std::fprintf(stderr, " %02x", byte);
    std::fputc('\n', stderr);
    return false;
}

bool testS24In32LowAlignmentAndSignExtension() {
    const std::vector<uint8_t> source{
        0x00, 0x00, 0x00, 0x80,  // -8388608, left-aligned in 32 bits
        0x00, 0xff, 0xff, 0x7f,  // +8388607, left-aligned in 32 bits
        0x34, 0x12, 0x80, 0xff,  // -524,746, left-aligned in 32 bits
        0xcc, 0xed, 0x7f, 0x00,  // +8,383,436, left-aligned in 32 bits
    };
    std::vector<uint8_t> output;
    lazer::audio::appendAlsaOutputFrames(output, source.data(), 2, 2, 8, false, true);
    return expectBytes("S24_LE low alignment and sign extension", output, {
        0x00, 0x00, 0x80, 0xff,
        0xff, 0xff, 0x7f, 0x00,
        0x12, 0x80, 0xff, 0xff,
        0xed, 0x7f, 0x00, 0x00,
    });
}

bool testPackedS24PassThrough() {
    const std::vector<uint8_t> source{
        0x00, 0x00, 0x80, 0xff, 0xff, 0x7f,
        0x34, 0x12, 0x80, 0xcc, 0xed, 0x7f,
    };
    std::vector<uint8_t> output{0xaa, 0xbb};
    lazer::audio::appendAlsaOutputFrames(output, source.data(), 2, 2, 6, false, false);
    return expectBytes("packed S24 pass-through with existing queue prefix", output, {
        0xaa, 0xbb,
        0x00, 0x00, 0x80, 0xff, 0xff, 0x7f,
        0x34, 0x12, 0x80, 0xcc, 0xed, 0x7f,
    });
}

bool testMultichannelFrameStride() {
    /* Three interleaved channels over two frames exercise the channel-count × frame-count stride. */
    const std::vector<uint8_t> source{
        0x11, 0x22, 0x33, 0x00,  0x44, 0x55, 0x66, 0x80,  0x77, 0x88, 0x99, 0xff,
        0xaa, 0xbb, 0xcc, 0x7f,  0xdd, 0xee, 0xff, 0x00,  0x10, 0x20, 0x30, 0x80,
    };
    std::vector<uint8_t> output;
    lazer::audio::appendAlsaOutputFrames(output, source.data(), 2, 3, 12, false, true);
    return expectBytes("three-channel frame stride", output, {
        0x22, 0x33, 0x00, 0x00,  0x55, 0x66, 0x80, 0xff,  0x88, 0x99, 0xff, 0xff,
        0xbb, 0xcc, 0x7f, 0x00,  0xee, 0xff, 0x00, 0x00,  0x20, 0x30, 0x80, 0xff,
    });
}

bool testDopMarkerAndPayloadTransparency() {
    const std::vector<uint8_t> carrier{
        0x11, 0x22, 0x05, 0xa1, 0xb2, 0x05,
        0x33, 0x44, 0xfa, 0xc3, 0xd4, 0xfa,
        0x55, 0x66, 0x05, 0xe5, 0xf6, 0x05,
    };
    std::vector<uint8_t> output;
    /* shift24ToLow=true here proves DoP bypass takes precedence over PCM S24 conversion. */
    lazer::audio::appendAlsaOutputFrames(output, carrier.data(), 3, 2, 6, true, true);
    return output == carrier || expectBytes("DoP marker/payload transparency", output, {
        0x11, 0x22, 0x05, 0xa1, 0xb2, 0x05,
        0x33, 0x44, 0xfa, 0xc3, 0xd4, 0xfa,
        0x55, 0x66, 0x05, 0xe5, 0xf6, 0x05,
    });
}

}  // namespace

int main() {
    const bool lowAlignment = testS24In32LowAlignmentAndSignExtension();
    const bool packed = testPackedS24PassThrough();
    const bool stride = testMultichannelFrameStride();
    const bool dop = testDopMarkerAndPayloadTransparency();
    if (lowAlignment && packed && stride && dop) {
        std::puts("PASS: ALSA output byte packing for S24_LE, packed S24, multichannel and DoP");
        return 0;
    }
    return 1;
}
