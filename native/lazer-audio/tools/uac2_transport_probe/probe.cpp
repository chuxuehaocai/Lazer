#include "android_uac2_iso_transport.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#if defined(_WIN32)
#include <fcntl.h>
#include <io.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif

namespace lazer::uac2_transport_probe {
void ResetFakeLibusbState();
int CloseCount();
int ExitCount();
int ClosedFdCount();
void SetCancelFailures(int count);
void SetEventFailures(int count);
int FreedTransferCount();
int LiveTransferCount();
int CallbackCount();
int EventErrorCount();
int CancelErrorCount();
int PendingTransferCount();
int WrappedFd();
void SetFakeStreamingFormat(std::uint8_t subslot_size, std::uint8_t bit_resolution);
void SetFakeFeedbackSampleRate(std::uint32_t sample_rate_hz);
void SetFakeDataTransferCompletionBudget(int completions);
int PendingDataTransferCount();
std::vector<unsigned char> CapturedOutputBytes();
} // namespace lazer::uac2_transport_probe

namespace {

using lazer::android_uac2::IsoTransportSession;
using lazer::android_uac2::NativeStreamConfig;

int OpenDummyFd() {
#if defined(_WIN32)
    return _open("NUL", _O_RDONLY);
#else
    return open("/dev/null", O_RDONLY | O_CLOEXEC);
#endif
}

bool IsFdOpen(const int fd) {
    if (fd < 0) return false;
#if defined(_WIN32)
    return _get_osfhandle(fd) != -1;
#else
    return fcntl(fd, F_GETFD) != -1;
#endif
}

int CloseDummyFd(const int fd) {
#if defined(_WIN32)
    return _close(fd);
#else
    return close(fd);
#endif
}

bool Check(const bool condition, const char* message) {
    if (condition) return true;
    std::cerr << message << '\n';
    return false;
}

template <typename Predicate>
bool WaitFor(Predicate predicate, const std::chrono::milliseconds timeout) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (std::chrono::steady_clock::now() < deadline) {
        if (predicate()) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return predicate();
}

NativeStreamConfig TestStreamConfig() {
    NativeStreamConfig config{};
    config.configuration_value = 1;
    config.interface_number = 1;
    config.alternate_setting = 1;
    config.sample_rate_hz = 48000;
    config.channel_count = 2;
    config.channel_config = 3;
    config.subslot_size_bytes = 2;
    config.valid_bit_resolution = 16;
    config.data_endpoint_address = 0x01;
    config.data_synchronization_type = 1; // Asynchronous; feedback is mandatory.
    config.data_maximum_packet_size_bytes = 1024;
    config.data_transactions_per_interval = 1;
    config.data_interval = 1;
    config.feedback_endpoint_address = 0x81;
    config.feedback_maximum_packet_size_bytes = 4;
    config.feedback_transactions_per_interval = 1;
    config.feedback_interval = 1;
    return config;
}

NativeStreamConfig TestDopStreamConfig() {
    NativeStreamConfig config = TestStreamConfig();
    config.sample_rate_hz = 176400;
    config.subslot_size_bytes = 3;
    config.valid_bit_resolution = 24;
    config.doP = true;
    return config;
}

bool HasValidDopMarkers(const std::vector<unsigned char>& bytes) {
    if (bytes.empty() || bytes.size() % 6u != 0) return false;
    std::uint8_t expected = 0x05;
    for (std::size_t offset = 0; offset < bytes.size(); offset += 6u) {
        if (bytes[offset + 2] != expected || bytes[offset + 5] != expected) return false;
        expected = expected == 0x05 ? 0xFA : 0x05;
    }
    return true;
}

bool ContainsDopPayloadFrames(const std::vector<unsigned char>& bytes) {
    constexpr unsigned char frames[][6] = {
        {0x11, 0x22, 0x05, 0x33, 0x44, 0x05},
        {0x55, 0x66, 0xFA, 0x77, 0x88, 0xFA},
        {0x99, 0xAA, 0x05, 0xBB, 0xCC, 0x05},
    };
    if (bytes.size() < sizeof(frames)) return false;
    for (std::size_t offset = 0; offset + sizeof(frames) <= bytes.size(); offset += 6u) {
        bool matches = true;
    constexpr std::size_t frame_count = sizeof(frames) / sizeof(frames[0]);
    for (std::size_t frame = 0; frame < frame_count; ++frame) {
            const auto* actual = bytes.data() + offset + frame * 6u;
            if (actual[0] != frames[frame][0] || actual[1] != frames[frame][1] ||
                actual[3] != frames[frame][3] || actual[4] != frames[frame][4]) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

bool HasDopIdlePayloadFrames(const std::vector<unsigned char>& bytes, const std::size_t first_frame) {
    if (bytes.size() % 6u != 0 || first_frame > bytes.size() / 6u) return false;
    for (std::size_t frame = first_frame; frame < bytes.size() / 6u; ++frame) {
        const auto* carrier = bytes.data() + frame * 6u;
        if (carrier[0] != 0x69 || carrier[1] != 0x69 ||
            carrier[3] != 0x69 || carrier[4] != 0x69) return false;
    }
    return true;
}

} // namespace

int main() {
    using namespace lazer::uac2_transport_probe;
    ResetFakeLibusbState();
    std::cout << "phase: normal stream" << std::endl;

    std::string error;
    const int original_fd = OpenDummyFd();
    std::cout << "normal: opened original fd" << std::endl;
    if (!Check(original_fd >= 0, "Could not create a dummy authorized device descriptor")) return 1;
    auto session = IsoTransportSession::Open(original_fd, &error);
    std::cout << "normal: wrapped duplicate" << std::endl;
    if (!Check(session != nullptr, error.empty() ? "Could not wrap borrowed USB descriptor" : error.c_str())) return 1;

    const auto config = TestStreamConfig();
    if (!Check(session->Start(config, &error) == 0,
               error.empty() ? "Could not start USB 2.0 async PCM stream" : error.c_str())) return 1;
    std::cout << "normal: started stream" << std::endl;

    // The transport starts paused. Writes are accepted into its bounded queue but no queued frame
    // may become audible or advance the playhead before SetPlaying(true).
    std::vector<std::uint8_t> first_audio(400u * 4u, 0x55u);
    const int first_write = session->Write(first_audio.data(), first_audio.size(), 0);
    if (!Check(first_write == static_cast<int>(first_audio.size()),
               "Paused stream should accept complete PCM frames into its queue")) return 1;
    std::cout << "normal: wrote paused frames" << std::endl;
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    if (!Check(session->played_frames_since_flush() == 0,
               "Paused stream must not report queued frames as played")) return 1;

    session->SetPlaying(true);
    if (!Check(WaitFor([&] { return session->played_frames_since_flush() > 0; },
                       std::chrono::milliseconds(500)),
               "Playing stream did not complete PCM data packets")) return 1;
    std::cout << "normal: played frames" << std::endl;
    session->SetPlaying(false);
    if (!Check(session->Flush(1000), "Flush should wait for submitted packets and reset the epoch")) return 1;
    std::cout << "normal: flushed" << std::endl;
    if (!Check(session->played_frames_since_flush() == 0,
               "Flush should reset the completed-frame playhead")) return 1;

    // A paused writer cannot outrun the device queue. A further frame is rejected once the
    // configured queue is full, proving the write path applies backpressure.
    const std::size_t queue_bytes = session->buffer_size_frames() * 4u;
    std::vector<std::uint8_t> bulk_audio(queue_bytes + 4096u, 0x22u);
    const int bulk_write = session->Write(bulk_audio.data(), bulk_audio.size(), 0);
    if (!Check(bulk_write == static_cast<int>(queue_bytes),
               "Paused PCM write should be capped at the bounded queue capacity")) return 1;
    const std::uint8_t one_frame[4] = {0, 0, 0, 0};
    if (!Check(session->Write(one_frame, sizeof(one_frame), 0) == 0,
               "A full PCM queue should report zero accepted frames")) return 1;
    std::cout << "normal: filled queue" << std::endl;

    // Stop-after-drain must transmit all accepted payload frames, and the same wrapped session
    // must support a later start/flush cycle without reopening or reconfiguring the USB device.
    if (!Check(session->Stop(true, 2000), "Drain stop did not complete all queued PCM frames")) return 1;
    std::cout << "normal: drained" << std::endl;
    if (!Check(session->played_frames_since_flush() == queue_bytes / 4u,
               "Drain stop playhead should count every queued PCM frame exactly once")) return 1;
    if (!Check(session->Start(config, &error) == 0,
               error.empty() ? "Could not restart after a completed drain" : error.c_str())) return 1;
    std::cout << "normal: restarted" << std::endl;
    if (!Check(session->Flush(1000), "Restarted stream flush should succeed")) return 1;
    if (!Check(session->played_frames_since_flush() == 0,
               "Restarted stream flush should leave a fresh frame epoch")) return 1;
    if (!Check(session->Stop(false, 1000), "Immediate stop should cancel and drain callbacks")) return 1;
    std::cout << "normal: stopped" << std::endl;

    std::cout << "normal: closing native session" << std::endl;
    if (!Check(session->Close(1000), "Native close should quiesce the normal fake stream")) return 1;
    std::cout << "normal: native session closed" << std::endl;
    if (!Check(CloseCount() == 1 && ExitCount() == 1,
               "Native close should release its libusb handle and context once")) return 1;
    std::cout << "normal: counters" << std::endl;
    if (!Check(ClosedFdCount() == 0,
               "libusb_close must leave the Java-owned USB file descriptor open")) return 1;
    std::cout << "normal: libusb fd ownership" << std::endl;
    const int normal_wrapped_fd = WrappedFd();
    if (!Check(IsFdOpen(original_fd) && normal_wrapped_fd != original_fd,
               "Healthy native close should leave the Java-owned original FD open")) return 1;
    session.reset();
    std::cout << "normal: native pointer released" << std::endl;
    if (!Check(CloseDummyFd(original_fd) == 0,
               "Java should be able to close its original FD after native close")) return 1;

    std::cout << "phase: DoP carrier and idle markers" << std::endl;
    SetFakeStreamingFormat(3, 24);
    SetFakeFeedbackSampleRate(176400);
    const std::size_t captured_before_dop = CapturedOutputBytes().size();
    const int dop_original_fd = OpenDummyFd();
    if (!Check(dop_original_fd >= 0, "Could not create a descriptor for the DoP transport test")) return 1;
    auto dop_session = IsoTransportSession::Open(dop_original_fd, &error);
    if (!Check(dop_session != nullptr,
               error.empty() ? "Could not open DoP transport session" : error.c_str())) return 1;
    const auto dop_config = TestDopStreamConfig();
    if (!Check(dop_session->Start(dop_config, &error) == 0,
               error.empty() ? "Could not start the stereo PCM24 DoP carrier" : error.c_str())) return 1;
    const unsigned char dop_frames[] = {
        0x11, 0x22, 0x05, 0x33, 0x44, 0x05,
        0x55, 0x66, 0xFA, 0x77, 0x88, 0xFA,
        0x99, 0xAA, 0x05, 0xBB, 0xCC, 0x05,
    };
    if (!Check(dop_session->Write(dop_frames, sizeof(dop_frames), 0) ==
                   static_cast<int>(sizeof(dop_frames)),
               "DoP queue should accept complete packed 24-bit carrier frames")) return 1;
    dop_session->SetPlaying(true);
    if (!Check(WaitFor([&] { return dop_session->played_frames_since_flush() >= 3; },
                       std::chrono::milliseconds(500)),
               "DoP transport did not submit queued carrier frames")) return 1;
    dop_session->SetPlaying(false);
    if (!Check(dop_session->Close(1000), "DoP transport should close after marker verification")) return 1;
    dop_session.reset();
    if (!Check(CloseDummyFd(dop_original_fd) == 0,
               "Java should close its original DoP USB descriptor after native close")) return 1;
    const auto all_captured = CapturedOutputBytes();
    const std::vector<unsigned char> dop_capture(
        all_captured.begin() + static_cast<std::ptrdiff_t>(captured_before_dop), all_captured.end());
    if (!Check(HasValidDopMarkers(dop_capture),
               "DoP packets must carry identical alternating markers on both channels, including idle frames")) return 1;
    if (!Check(ContainsDopPayloadFrames(dop_capture),
               "DoP transport must preserve queued channel payload bytes while rewriting marker phase")) return 1;

    std::cout << "phase: DoP marker continuity across flush" << std::endl;
    SetFakeDataTransferCompletionBudget(0);
    const std::size_t captured_before_dop_flush = CapturedOutputBytes().size();
    const int dop_flush_original_fd = OpenDummyFd();
    if (!Check(dop_flush_original_fd >= 0, "Could not create a descriptor for the DoP flush test")) return 1;
    auto dop_flush_session = IsoTransportSession::Open(dop_flush_original_fd, &error);
    if (!Check(dop_flush_session != nullptr,
               error.empty() ? "Could not open DoP flush session" : error.c_str())) return 1;
    if (!Check(dop_flush_session->Start(dop_config, &error) == 0,
               error.empty() ? "Could not start DoP flush session" : error.c_str())) return 1;
    if (!Check(WaitFor([] { return PendingDataTransferCount() >= 4; }, std::chrono::milliseconds(500)),
               "DoP data transfers were not queued for deterministic flush")) return 1;

    std::atomic<bool> flush_entered{false};
    bool dop_flush_succeeded = false;
    std::thread dop_flush_thread([&] {
        flush_entered.store(true, std::memory_order_release);
        dop_flush_succeeded = dop_flush_session->Flush(1000);
    });
    const bool flush_thread_started = WaitFor(
        [&] { return flush_entered.load(std::memory_order_acquire); },
        std::chrono::milliseconds(500));
    if (!flush_thread_started) {
        SetFakeDataTransferCompletionBudget(-1);
        dop_flush_thread.join();
        if (!Check(false, "DoP flush thread did not start")) return 1;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    SetFakeDataTransferCompletionBudget(4);
    dop_flush_thread.join();
    if (!Check(dop_flush_succeeded, "DoP flush should complete after submitted packets return")) return 1;

    const auto dop_flush_boundary = CapturedOutputBytes();
    const std::size_t pre_flush_bytes = dop_flush_boundary.size() - captured_before_dop_flush;
    if (!Check(pre_flush_bytes > 0 && pre_flush_bytes % 6u == 0,
               "DoP flush fixture should end on a carrier-frame boundary")) return 1;
    if (!Check(((pre_flush_bytes / 6u) % 2u) == 1u,
               "DoP flush fixture must leave the next marker at 0xFA")) return 1;
    if (!Check(WaitFor([&] { return PendingDataTransferCount() >= 4; }, std::chrono::milliseconds(500)),
               "Flush should restart idle DoP transfers on the same session")) return 1;
    SetFakeDataTransferCompletionBudget(1);
    if (!Check(WaitFor([&] { return CapturedOutputBytes().size() > dop_flush_boundary.size(); },
                       std::chrono::milliseconds(500)),
               "DoP idle carrier did not resume after flush")) return 1;
    SetFakeDataTransferCompletionBudget(-1);
    if (!Check(dop_flush_session->Close(1000), "DoP flush session should close after marker verification")) return 1;
    dop_flush_session.reset();
    if (!Check(CloseDummyFd(dop_flush_original_fd) == 0,
               "Java should close its original DoP flush descriptor after native close")) return 1;
    const auto dop_flush_capture_all = CapturedOutputBytes();
    const std::vector<unsigned char> dop_flush_capture(
        dop_flush_capture_all.begin() + static_cast<std::ptrdiff_t>(captured_before_dop_flush),
        dop_flush_capture_all.end());
    if (!Check(HasValidDopMarkers(dop_flush_capture),
               "DoP markers must alternate continuously across a successful flush on the same session")) return 1;
    if (!Check(HasDopIdlePayloadFrames(dop_flush_capture, pre_flush_bytes / 6u),
               "Post-flush DoP idle frames must contain 0x69 payload bytes and continuous markers")) return 1;
    SetFakeDataTransferCompletionBudget(-1);
    SetFakeStreamingFormat(2, 16);
    SetFakeFeedbackSampleRate(48000);

    std::cout << "phase: transient cancellation errors" << std::endl;
    const int cancel_failure_fd = OpenDummyFd();
    if (!Check(cancel_failure_fd >= 0, "Could not create a descriptor for cancellation retry test")) return 1;
    auto cancel_failure_session = IsoTransportSession::Open(cancel_failure_fd, &error);
    if (!Check(cancel_failure_session != nullptr,
               error.empty() ? "Could not open cancellation retry session" : error.c_str())) return 1;
    if (!Check(cancel_failure_session->Start(config, &error) == 0,
               error.empty() ? "Could not start cancellation retry stream" : error.c_str())) return 1;
    if (!Check(WaitFor([&] { return PendingTransferCount() >= 5; }, std::chrono::milliseconds(500)),
               "Cancellation retry stream did not submit feedback and PCM transfers")) return 1;
    SetCancelFailures(2);
    const int frees_before_cancel_retry = FreedTransferCount();
    if (!Check(cancel_failure_session->Close(1000),
               "Transient cancellation errors should still close after callbacks quiesce")) return 1;
    if (!Check(CancelErrorCount() == 2 && FreedTransferCount() - frees_before_cancel_retry >= 5,
               "Cancel return failures should be observed while completed callbacks release transfers safely")) return 1;
    const int cancel_retry_duplicate_fd = WrappedFd();
    cancel_failure_session.reset();
    if (!Check(IsFdOpen(cancel_failure_fd) && cancel_retry_duplicate_fd != cancel_failure_fd,
               "Clean close after transient cancellation errors should preserve Java's original FD")) return 1;
    if (!Check(CloseDummyFd(cancel_failure_fd) == 0,
               "Java should be able to close its original FD after cancellation retries")) return 1;

    std::cout << "phase: persistent event/cancel errors" << std::endl;
    // Simulate a kernel/libusb failure where cancellation itself fails and the event pump keeps
    // returning errors. Close must return by its deadline, quarantine every callback-owned object,
    // and retain a duplicate of the Android-owned descriptor after Java closes its original.
    const int fault_original_fd = OpenDummyFd();
    if (!Check(fault_original_fd >= 0, "Could not create a descriptor for fault injection")) return 1;
    auto fault_session = IsoTransportSession::Open(fault_original_fd, &error);
    if (!Check(fault_session != nullptr, error.empty() ? "Could not open fault-injection session" : error.c_str())) return 1;
    if (!Check(fault_session->Start(config, &error) == 0,
               error.empty() ? "Could not start fault-injection stream" : error.c_str())) return 1;
    if (!Check(WaitFor([&] { return PendingTransferCount() > 0; }, std::chrono::milliseconds(200)),
               "Fault-injection stream did not submit a transfer")) return 1;

    SetCancelFailures(-1);
    SetEventFailures(-1);
    if (!Check(WaitFor([&] { return EventErrorCount() > 0; }, std::chrono::milliseconds(200)),
               "Fake libusb event-error injection was not observed")) return 1;

    const int frees_before_quarantine = FreedTransferCount();
    const auto close_started = std::chrono::steady_clock::now();
    const bool fault_closed = fault_session->Close(150);
    const auto close_elapsed = std::chrono::steady_clock::now() - close_started;
    if (!Check(!fault_closed && close_elapsed < std::chrono::milliseconds(500),
               "Close should return within its bounded callback-quiescence deadline")) return 1;
    fault_session.reset(); // The custom deleter transfers ownership to process-lifetime quarantine.
    if (!Check(IsoTransportSession::QuarantinedSessionCount() == 1,
               "Unquiesced native session should be retained in quarantine")) return 1;
    if (!Check(FreedTransferCount() == frees_before_quarantine && LiveTransferCount() > 0,
               "Quarantine must preserve all transfer allocations and buffers")) return 1;
    if (!Check(CloseCount() == 4 && ExitCount() == 4,
               "Quarantined session must keep its libusb handle and context open")) return 1;

    const int quarantined_duplicate_fd = WrappedFd();
    const int original_close_result = CloseDummyFd(fault_original_fd); // Model Java closing UsbDeviceConnection.
    if (!Check(original_close_result == 0 && IsFdOpen(quarantined_duplicate_fd),
               "Closing Java's original FD must not invalidate quarantined libusb's duplicate")) return 1;

    // Once the injected event error is removed, callbacks may quiesce, but the last-resort policy
    // still retains their storage until process exit. The open-session cap prevents unbounded
    // accumulation across repeated hardware failures.
    SetCancelFailures(0);
    SetEventFailures(0);
    std::cout << "phase: callback recovery" << std::endl;
    if (!Check(WaitFor([&] { return PendingTransferCount() == 0; }, std::chrono::milliseconds(1000)),
               "Event pump did not resume after clearing the injected failure")) return 1;
    if (!Check(FreedTransferCount() == frees_before_quarantine && IsFdOpen(quarantined_duplicate_fd),
               "Quarantined storage and duplicate FD must remain retained after callbacks quiesce")) return 1;

    const int cap_original_fd = OpenDummyFd();
    std::cout << "phase: quarantine cap" << std::endl;
    if (!Check(cap_original_fd >= 0, "Could not create descriptor for quarantine-cap test")) return 1;
    std::vector<IsoTransportSession::Pointer> capacity_sessions;
    for (std::size_t index = 1; index < IsoTransportSession::MaximumSessionCount(); ++index) {
        auto capacity_session = IsoTransportSession::Open(cap_original_fd, &error);
        if (!Check(capacity_session != nullptr,
                   error.empty() ? "Session cap rejected an available quarantine slot" : error.c_str())) return 1;
        capacity_sessions.push_back(std::move(capacity_session));
    }
    auto over_capacity = IsoTransportSession::Open(cap_original_fd, &error);
    if (!Check(over_capacity == nullptr && IsoTransportSession::QuarantinedSessionCount() == 1,
               "Open must fail once active plus quarantined sessions reach the configured cap")) return 1;
    for (auto& capacity_session : capacity_sessions) {
        if (!Check(capacity_session->Close(200), "Idle capped session should close cleanly")) return 1;
        capacity_session.reset();
    }
    if (!Check(CloseDummyFd(cap_original_fd) == 0,
               "Java should be able to close the cap-test original FD")) return 1;

    std::cout << "UAC2 transport lifecycle, bounded teardown, quarantine and FD ownership checks passed\n";
    return 0;
}
