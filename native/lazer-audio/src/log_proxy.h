#ifndef LAZER_AUDIO_LOG_PROXY_H
#define LAZER_AUDIO_LOG_PROXY_H

#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <utility>

#include "lazer_audio_api.h"

namespace lazer::audio {

class LogProxy {
public:
    void install(LazerAudioLogHandler handler, bool retain = true) {
        handler_ = handler;
        retain_ = retain;
    }

    void write(LazerAudioLogLevel level, const char *message) const {
        if (message == nullptr) return;
        if (retain_ && level >= LazerAudioLogWarning) {
            std::string copy(message, boundedLength(message));
            std::lock_guard guard(mutex_);
            if (pending_.size() == kMaximumEntries) pending_.pop_front();
            pending_.emplace_back(static_cast<int32_t>(level), std::move(copy));
        }
        // Legacy synchronous clients retain the existing callback contract.
        if (handler_.on_log != nullptr) {
            handler_.on_log(handler_.context, static_cast<int32_t>(level), message);
        }
    }

    void write(LazerAudioLogLevel level, const std::string &message) const {
        write(level, message.c_str());
    }

    int32_t read(int32_t *level, char *message, uint32_t capacity) {
        if (level == nullptr || message == nullptr || capacity == 0) return LazerAudioErrorInvalidArgument;
        std::lock_guard guard(mutex_);
        message[0] = '\0';
        if (pending_.empty()) return 0;
        const auto &entry = pending_.front();
        if (capacity <= entry.second.size()) return LazerAudioErrorBufferTooSmall;
        *level = entry.first;
        std::memcpy(message, entry.second.c_str(), entry.second.size() + 1);
        const auto count = static_cast<int32_t>(entry.second.size() + 1);
        pending_.pop_front();
        return count;
    }

private:
    static constexpr size_t kMaximumEntries = 128;
    static constexpr size_t kMaximumBytes = 2047;
    static size_t boundedLength(const char *message) {
        size_t length = 0;
        while (length < kMaximumBytes && message[length] != '\0') ++length;
        return length;
    }
    LazerAudioLogHandler handler_{};
    bool retain_ = true;
    mutable std::mutex mutex_;
    mutable std::deque<std::pair<int32_t, std::string>> pending_;
};
}  // namespace lazer::audio
#endif
