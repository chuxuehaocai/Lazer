cmake_minimum_required(VERSION 3.21)
project(lazer_aaudio_contract LANGUAGES CXX)
enable_testing()

# Compile the production backend against a controllable AAudio implementation.
# No Android device, FFmpeg SDK or platform audio endpoint is needed.
add_executable(lazer-aaudio-contract
    aaudio_contract.cpp
    ../../src/output_aaudio.cpp)
target_include_directories(lazer-aaudio-contract PRIVATE
    fake ../../src ../../include)
target_compile_features(lazer-aaudio-contract PRIVATE cxx_std_20)
if(MSVC)
    target_compile_options(lazer-aaudio-contract PRIVATE /W4 /WX /EHsc)
else()
    target_compile_options(lazer-aaudio-contract PRIVATE -Wall -Wextra -Werror)
endif()
add_test(NAME lazer-aaudio-contract COMMAND lazer-aaudio-contract)
set_tests_properties(lazer-aaudio-contract PROPERTIES TIMEOUT 15)

add_executable(lazer-log-contract log_contract.cpp)
target_include_directories(lazer-log-contract PRIVATE ../../src ../../include)
target_compile_features(lazer-log-contract PRIVATE cxx_std_20)
find_package(Threads REQUIRED)
target_link_libraries(lazer-log-contract PRIVATE Threads::Threads)
add_test(NAME lazer-log-contract COMMAND lazer-log-contract)
set_tests_properties(lazer-log-contract PROPERTIES TIMEOUT 15)
