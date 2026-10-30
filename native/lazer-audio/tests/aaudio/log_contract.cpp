#include "log_proxy.h"
#include <array>
#include <iostream>
#include <stdexcept>
#include <thread>

using namespace lazer::audio;

void require(bool value, const char *message) {
    if (!value) throw std::runtime_error(message);
}

int main() {
    try {
        LogProxy log;
        std::array<char, 2048> buffer{};
        int32_t level = 0;
        std::thread producer([&] {
            std::string temporary = "warning from decoder thread";
            log.write(LazerAudioLogWarning, temporary);
            temporary.assign(4096, 'x');
        });
        producer.join();
        require(log.read(&level, buffer.data(), 4) == LazerAudioErrorBufferTooSmall, "short buffer consumed log");
        require(log.read(&level, buffer.data(), static_cast<uint32_t>(buffer.size())) > 0, "missing log copy");
        require(std::string(buffer.data()) == "warning from decoder thread", "callback string lifetime escaped");
        require(level == LazerAudioLogWarning, "wrong severity");
        for (int i = 0; i < 1000; ++i) log.write(LazerAudioLogError, "message " + std::to_string(i));
        int count = 0;
        while (log.read(&level, buffer.data(), static_cast<uint32_t>(buffer.size())) > 0) ++count;
        require(count == 128 && std::string(buffer.data()).empty(), "log queue is not bounded");
        log.write(LazerAudioLogInfo, "ignored debug traffic");
        require(log.read(&level, buffer.data(), static_cast<uint32_t>(buffer.size())) == 0, "verbose logs filled queue");
        log.write(LazerAudioLogError, std::string(10000, 'x'));
        require(log.read(&level, buffer.data(), static_cast<uint32_t>(buffer.size())) == 2048, "long log must be bounded");
        std::cout << "Owned native log queue: all checks passed\n";
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
