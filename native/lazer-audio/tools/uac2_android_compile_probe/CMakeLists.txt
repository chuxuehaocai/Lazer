cmake_minimum_required(VERSION 3.21)
project(lazer_android_output_compile_probe LANGUAGES C CXX)
if(NOT ANDROID)
    message(FATAL_ERROR "This link check requires the Android NDK toolchain")
endif()
# Link the actual routed backend without requiring the independent FFmpeg SDK.
# This proves Android ABI/API/link compatibility, not on-device audio behavior.
set(LAZER_ANDROID_BUILD_ENGINE ON)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/AndroidUac2.cmake")
add_library(lazer-android-output-contract SHARED
    ../../src/output_aaudio.cpp
    ../../src/android_uac2_output.cpp
    ../../src/android_uac2_control.cpp
    ../../src/android_uac2_iso_transport.cpp
    ../../src/android_uac2_packetizer.cpp
    ../../src/dop_packer.cpp)
target_include_directories(lazer-android-output-contract PRIVATE
    ../../src ../../include "${libusb_SOURCE_DIR}/libusb")
target_compile_features(lazer-android-output-contract PRIVATE cxx_std_20)
target_compile_definitions(lazer-android-output-contract PRIVATE LAZER_ANDROID_UAC2=1)
target_compile_options(lazer-android-output-contract PRIVATE -Wall -Wextra -Werror)
target_link_libraries(lazer-android-output-contract PRIVATE usb-1.0 Threads::Threads aaudio android log)
target_link_options(lazer-android-output-contract PRIVATE "-Wl,-z,max-page-size=16384")
