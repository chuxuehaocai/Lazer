#include "android_uac2_iso_transport.h"
#include "android_uac2_packetizer.h"

#include <jni.h>
#include <libusb.h>

#include <atomic>
#include <cstdint>
#include <exception>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

using lazer::android_uac2::IsoTransportSession;
using lazer::android_uac2::NativeStreamConfig;
using lazer::android_uac2::PcmPacketizer;
using lazer::android_uac2::SynchronizationType;
using lazer::android_uac2::UsbSpeed;

struct BridgeSession final {
    explicit BridgeSession(IsoTransportSession::Pointer value) noexcept
        : session(std::move(value)) {}

    std::mutex api_mutex;
    IsoTransportSession::Pointer session;
};

std::mutex g_sessions_mutex;
std::unordered_map<jlong, std::shared_ptr<BridgeSession>> g_sessions;
std::atomic<jlong> g_next_session_id{1};

void Throw(JNIEnv* env, const char* class_name, const std::string& message) noexcept {
    if (env->ExceptionCheck()) return;
    jclass exception_class = env->FindClass(class_name);
    if (exception_class != nullptr) {
        env->ThrowNew(exception_class, message.c_str());
        env->DeleteLocalRef(exception_class);
    }
}

std::shared_ptr<BridgeSession> FindSession(JNIEnv* env, const jlong id) {
    std::lock_guard<std::mutex> lock(g_sessions_mutex);
    const auto found = g_sessions.find(id);
    if (found == g_sessions.end()) {
        Throw(env, "java/lang/IllegalStateException", "Native UAC2 session is closed");
        return nullptr;
    }
    return found->second;
}

bool ReadConfig(JNIEnv* env, const jintArray input, NativeStreamConfig* output) {
    if (input == nullptr || output == nullptr || env->GetArrayLength(input) != 18) {
        Throw(env, "java/lang/IllegalArgumentException", "UAC2 stream config must contain exactly 18 integers");
        return false;
    }
    jint values[18]{};
    env->GetIntArrayRegion(input, 0, 18, values);
    if (env->ExceptionCheck()) return false;
    const auto fits_u8 = [](const jint value) { return value >= 0 && value <= 0xff; };
    const auto fits_u16 = [](const jint value) { return value >= 0 && value <= 0xffff; };
    if (!fits_u8(values[0]) || !fits_u8(values[1]) || !fits_u8(values[2]) ||
        values[3] < 0 || !fits_u8(values[4]) || !fits_u8(values[6]) ||
        !fits_u8(values[7]) || !fits_u8(values[8]) || !fits_u8(values[9]) ||
        !fits_u16(values[10]) || !fits_u8(values[11]) || !fits_u8(values[12]) ||
        !fits_u8(values[13]) || !fits_u16(values[14]) ||
        !fits_u8(values[15]) || !fits_u8(values[16]) || (values[17] != 0 && values[17] != 1)) {
        Throw(env, "java/lang/IllegalArgumentException", "UAC2 stream config contains out-of-range fields");
        return false;
    }
    output->configuration_value = static_cast<std::uint8_t>(values[0]);
    output->interface_number = static_cast<std::uint8_t>(values[1]);
    output->alternate_setting = static_cast<std::uint8_t>(values[2]);
    output->sample_rate_hz = static_cast<std::uint32_t>(values[3]);
    output->channel_count = static_cast<std::uint8_t>(values[4]);
    output->channel_config = static_cast<std::uint32_t>(values[5]);
    output->subslot_size_bytes = static_cast<std::uint8_t>(values[6]);
    output->valid_bit_resolution = static_cast<std::uint8_t>(values[7]);
    output->data_endpoint_address = static_cast<std::uint8_t>(values[8]);
    output->data_synchronization_type = static_cast<std::uint8_t>(values[9]);
    output->data_maximum_packet_size_bytes = static_cast<std::uint16_t>(values[10]);
    output->data_transactions_per_interval = static_cast<std::uint8_t>(values[11]);
    output->data_interval = static_cast<std::uint8_t>(values[12]);
    output->feedback_endpoint_address = static_cast<std::uint8_t>(values[13]);
    output->feedback_maximum_packet_size_bytes = static_cast<std::uint16_t>(values[14]);
    output->feedback_transactions_per_interval = static_cast<std::uint8_t>(values[15]);
    output->feedback_interval = static_cast<std::uint8_t>(values[16]);
    output->doP = values[17] == 1;
    return true;
}

bool CountPacketFrames(PcmPacketizer* packetizer, const std::uint32_t packet_count, std::uint64_t* total) {
    if (packetizer == nullptr || total == nullptr) return false;
    *total = 0;
    for (std::uint32_t index = 0; index < packet_count; ++index) {
        std::uint32_t frames = 0;
        if (!packetizer->NextPacketFrameCount(&frames)) return false;
        *total += frames;
    }
    return true;
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_dev_naominet_lazer_AndroidUac2NativeIsoBridge_libusbVersion(JNIEnv* env, jobject) {
    const auto* version = libusb_get_version();
    const std::string text = version == nullptr || version->major != 1 || version->minor != 0
        ? "unknown"
        : std::to_string(version->major) + "." + std::to_string(version->minor) + "." +
              std::to_string(version->micro);
    return env->NewStringUTF(text.c_str());
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_naominet_lazer_AndroidUac2NativeIsoBridge_packetizerSelfTest(JNIEnv*, jobject) {
    PcmPacketizer full_speed_adaptive;
    if (!full_speed_adaptive.Configure(
            44100, 4, 1024, UsbSpeed::Full, SynchronizationType::Adaptive, 1, false)) return JNI_FALSE;
    std::uint64_t total = 0;
    if (!CountPacketFrames(&full_speed_adaptive, 1000, &total) || total != 44100) return JNI_FALSE;

    PcmPacketizer high_speed_adaptive;
    if (!high_speed_adaptive.Configure(
            44100, 4, 1024, UsbSpeed::High, SynchronizationType::Adaptive, 1, false)) return JNI_FALSE;
    if (!CountPacketFrames(&high_speed_adaptive, 8000, &total) || total != 44100) return JNI_FALSE;

    PcmPacketizer high_speed_async;
    if (high_speed_async.Configure(
            44100, 4, 1024, UsbSpeed::High, SynchronizationType::Asynchronous, 1, false)) return JNI_FALSE;
    if (!high_speed_async.Configure(
            44100, 4, 1024, UsbSpeed::High, SynchronizationType::Asynchronous, 1, true)) return JNI_FALSE;
    const std::uint8_t hs_feedback[4] = {0x33u, 0x83u, 0x05u, 0x00u}; // 5.5125 samples/microframe.
    if (!high_speed_async.UpdateFeedback(hs_feedback, sizeof(hs_feedback))) return JNI_FALSE;
    if (!CountPacketFrames(&high_speed_async, 8000, &total) || total < 44099 || total > 44100) return JNI_FALSE;

    PcmPacketizer full_speed_async;
    if (!full_speed_async.Configure(
            44100, 4, 1024, UsbSpeed::Full, SynchronizationType::Asynchronous, 1, true)) return JNI_FALSE;
    const std::uint8_t fs_feedback[3] = {0x66u, 0x06u, 0x0bu}; // 44.1 samples/frame in 10.14.
    if (!full_speed_async.UpdateFeedback(fs_feedback, sizeof(fs_feedback))) return JNI_FALSE;
    if (!CountPacketFrames(&full_speed_async, 1000, &total) || total < 44099 || total > 44100) return JNI_FALSE;

    PcmPacketizer superspeed;
    return superspeed.Configure(
        44100, 4, 1024, static_cast<UsbSpeed>(3), SynchronizationType::Adaptive, 1, false)
        ? JNI_FALSE
        : JNI_TRUE;
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_naominet_lazer_AndroidUac2NativeIsoBridge_openNative(JNIEnv* env, jobject, const jint fd) {
    try {
        std::string error;
        auto session = IsoTransportSession::Open(fd, &error);
        if (!session) {
            Throw(env, "java/lang/IllegalArgumentException", error.empty() ? "Could not wrap USB connection FD" : error);
            return 0;
        }
        const jlong id = g_next_session_id.fetch_add(1, std::memory_order_relaxed);
        if (id <= 0) {
            session->Close();
            Throw(env, "java/lang/IllegalStateException", "Native UAC2 session handle space is exhausted");
            return 0;
        }
        std::lock_guard<std::mutex> lock(g_sessions_mutex);
        g_sessions.emplace(id, std::make_shared<BridgeSession>(std::move(session)));
        return id;
    } catch (const std::exception& error) {
        Throw(env, "java/lang/IllegalStateException", error.what());
    } catch (...) {
        Throw(env, "java/lang/IllegalStateException", "Unexpected native UAC2 open failure");
    }
    return 0;
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_naominet_lazer_AndroidUac2NativeIsoBridge_startNative(
    JNIEnv* env,
    jobject,
    const jlong id,
    const jintArray config_values) {
    NativeStreamConfig config{};
    if (!ReadConfig(env, config_values, &config)) return LIBUSB_ERROR_INVALID_PARAM;
    auto bridge_session = FindSession(env, id);
    if (!bridge_session) return LIBUSB_ERROR_NO_DEVICE;
    std::lock_guard<std::mutex> lock(bridge_session->api_mutex);
    std::string error;
    const int result = bridge_session->session->Start(config, &error);
    if (result < 0) Throw(env, "java/lang/IllegalStateException", error.empty()
        ? bridge_session->session->LastError()
        : error);
    return result;
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_naominet_lazer_AndroidUac2NativeIsoBridge_writeNative(
    JNIEnv* env,
    jobject,
    const jlong id,
    jobject buffer,
    const jint offset,
    const jint length,
    const jint timeout_ms) {
    if (buffer == nullptr || offset < 0 || length < 0 || timeout_ms < 0) {
        Throw(env, "java/lang/IllegalArgumentException", "Invalid direct PCM buffer range or timeout");
        return LIBUSB_ERROR_INVALID_PARAM;
    }
    const auto capacity = env->GetDirectBufferCapacity(buffer);
    auto* address = static_cast<std::uint8_t*>(env->GetDirectBufferAddress(buffer));
    if (address == nullptr || capacity < 0 || static_cast<jlong>(offset) + length > capacity) {
        Throw(env, "java/lang/IllegalArgumentException", "PCM input must be a direct ByteBuffer with an in-range byte slice");
        return LIBUSB_ERROR_INVALID_PARAM;
    }
    auto bridge_session = FindSession(env, id);
    if (!bridge_session) return LIBUSB_ERROR_NO_DEVICE;
    std::lock_guard<std::mutex> lock(bridge_session->api_mutex);
    const int result = bridge_session->session->Write(
        address + offset,
        static_cast<std::size_t>(length),
        static_cast<std::uint32_t>(timeout_ms));
    if (result < 0) Throw(env, "java/lang/IllegalStateException", bridge_session->session->LastError());
    return result;
}

extern "C" JNIEXPORT void JNICALL
Java_dev_naominet_lazer_AndroidUac2NativeIsoBridge_setPlayingNative(
    JNIEnv* env,
    jobject,
    const jlong id,
    const jboolean playing) {
    auto bridge_session = FindSession(env, id);
    if (!bridge_session) return;
    std::lock_guard<std::mutex> lock(bridge_session->api_mutex);
    bridge_session->session->SetPlaying(playing == JNI_TRUE);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_naominet_lazer_AndroidUac2NativeIsoBridge_flushNative(
    JNIEnv* env,
    jobject,
    const jlong id,
    const jint timeout_ms) {
    if (timeout_ms < 0) {
        Throw(env, "java/lang/IllegalArgumentException", "Flush timeout must not be negative");
        return JNI_FALSE;
    }
    auto bridge_session = FindSession(env, id);
    if (!bridge_session) return JNI_FALSE;
    std::lock_guard<std::mutex> lock(bridge_session->api_mutex);
    return bridge_session->session->Flush(static_cast<std::uint32_t>(timeout_ms)) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_naominet_lazer_AndroidUac2NativeIsoBridge_stopNative(
    JNIEnv* env,
    jobject,
    const jlong id,
    const jboolean drain,
    const jint timeout_ms) {
    if (timeout_ms < 0) {
        Throw(env, "java/lang/IllegalArgumentException", "Stop timeout must not be negative");
        return JNI_FALSE;
    }
    auto bridge_session = FindSession(env, id);
    if (!bridge_session) return JNI_FALSE;
    std::lock_guard<std::mutex> lock(bridge_session->api_mutex);
    return bridge_session->session->Stop(
        drain == JNI_TRUE,
        static_cast<std::uint32_t>(timeout_ms)) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_naominet_lazer_AndroidUac2NativeIsoBridge_underrunPacketsNative(
    JNIEnv* env,
    jobject,
    const jlong id) {
    auto bridge_session = FindSession(env, id);
    if (!bridge_session) return 0;
    std::lock_guard<std::mutex> lock(bridge_session->api_mutex);
    return bridge_session->session->underrun_packets();
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_naominet_lazer_AndroidUac2NativeIsoBridge_errorCodeNative(
    JNIEnv* env,
    jobject,
    const jlong id) {
    auto bridge_session = FindSession(env, id);
    if (!bridge_session) return LIBUSB_ERROR_NO_DEVICE;
    std::lock_guard<std::mutex> lock(bridge_session->api_mutex);
    return bridge_session->session->error_code();
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_naominet_lazer_AndroidUac2NativeIsoBridge_playedFramesNative(
    JNIEnv* env,
    jobject,
    const jlong id) {
    auto bridge_session = FindSession(env, id);
    if (!bridge_session) return 0;
    std::lock_guard<std::mutex> lock(bridge_session->api_mutex);
    return static_cast<jlong>(bridge_session->session->played_frames_since_flush());
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_naominet_lazer_AndroidUac2NativeIsoBridge_bufferSizeFramesNative(
    JNIEnv* env,
    jobject,
    const jlong id) {
    auto bridge_session = FindSession(env, id);
    if (!bridge_session) return 0;
    std::lock_guard<std::mutex> lock(bridge_session->api_mutex);
    return static_cast<jlong>(bridge_session->session->buffer_size_frames());
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_naominet_lazer_AndroidUac2NativeIsoBridge_isStalledNative(
    JNIEnv* env,
    jobject,
    const jlong id) {
    auto bridge_session = FindSession(env, id);
    if (!bridge_session) return JNI_TRUE;
    std::lock_guard<std::mutex> lock(bridge_session->api_mutex);
    return bridge_session->session->is_stalled() ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_naominet_lazer_AndroidUac2NativeIsoBridge_lastErrorNative(
    JNIEnv* env,
    jobject,
    const jlong id) {
    auto bridge_session = FindSession(env, id);
    if (!bridge_session) return nullptr;
    std::lock_guard<std::mutex> lock(bridge_session->api_mutex);
    const std::string error = bridge_session->session->LastError();
    return env->NewStringUTF(error.c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_dev_naominet_lazer_AndroidUac2NativeIsoBridge_closeNative(
    JNIEnv*,
    jobject,
    const jlong id) {
    std::shared_ptr<BridgeSession> bridge_session;
    {
        std::lock_guard<std::mutex> lock(g_sessions_mutex);
        const auto found = g_sessions.find(id);
        if (found == g_sessions.end()) return;
        bridge_session = std::move(found->second);
        g_sessions.erase(found);
    }
    std::lock_guard<std::mutex> lock(bridge_session->api_mutex);
    bridge_session->session->Close();
}
