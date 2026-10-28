cmake_minimum_required(VERSION 3.21)
project(lazer_uac2_packetizer_probe LANGUAGES CXX)

enable_testing()
add_executable(lazer-uac2-packetizer-probe
    probe.cpp
    "${CMAKE_CURRENT_LIST_DIR}/../../src/android_uac2_packetizer.cpp")
target_include_directories(lazer-uac2-packetizer-probe PRIVATE
    "${CMAKE_CURRENT_LIST_DIR}/../../src")
target_compile_features(lazer-uac2-packetizer-probe PRIVATE cxx_std_20)
if(MSVC)
    target_compile_options(lazer-uac2-packetizer-probe PRIVATE /W4 /WX /permissive- /EHsc)
endif()
add_test(NAME lazer-uac2-packetizer COMMAND lazer-uac2-packetizer-probe)
set_tests_properties(lazer-uac2-packetizer PROPERTIES TIMEOUT 15)
