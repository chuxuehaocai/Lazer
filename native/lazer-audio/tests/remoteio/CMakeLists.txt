cmake_minimum_required(VERSION 3.21)
project(lazer_remoteio_contract LANGUAGES CXX)
enable_testing()

# Compile the production iOS backend against a fake AudioUnit and a fake
# AVAudioSession shim. No iOS SDK, no FFmpeg SDK and no audio device are
# needed, which is the only way this backend's state machine can be checked on
# every commit instead of only on a device.
add_executable(lazer-remoteio-contract
    remoteio_contract.cpp
    ../../src/output_remoteio.cpp)
target_include_directories(lazer-remoteio-contract PRIVATE
    fake ../../src ../../include)
target_compile_features(lazer-remoteio-contract PRIVATE cxx_std_20)
find_package(Threads REQUIRED)
target_link_libraries(lazer-remoteio-contract PRIVATE Threads::Threads)
if(MSVC)
    target_compile_options(lazer-remoteio-contract PRIVATE /W4 /WX /EHsc /utf-8)
else()
    target_compile_options(lazer-remoteio-contract PRIVATE -Wall -Wextra -Werror)
endif()
add_test(NAME lazer-remoteio-contract COMMAND lazer-remoteio-contract)
set_tests_properties(lazer-remoteio-contract PROPERTIES TIMEOUT 15)
