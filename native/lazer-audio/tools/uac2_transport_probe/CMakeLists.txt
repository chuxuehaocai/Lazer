cmake_minimum_required(VERSION 3.21)
project(lazer_uac2_transport_probe LANGUAGES CXX)

include(FetchContent)
if(POLICY CMP0169)
    cmake_policy(SET CMP0169 OLD)
endif()
FetchContent_Declare(libusb
    URL "https://codeload.github.com/libusb/libusb/tar.gz/87a55632db62c9bdc58cd31d3ccfa673f1bb017f"
    URL_HASH SHA256=26733c3eee2475c062e14f80a62ece4b33ee3b33fc0c88b2758964412a42b7e0
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_GetProperties(libusb)
if(NOT libusb_POPULATED)
    FetchContent_Populate(libusb)
endif()

enable_testing()
find_package(Threads REQUIRED)
add_executable(lazer-uac2-transport-probe
    probe.cpp
    fake_libusb.cpp
    "${CMAKE_CURRENT_LIST_DIR}/../../src/android_uac2_control.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/../../src/android_uac2_iso_transport.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/../../src/android_uac2_packetizer.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/../../src/dop_packer.cpp")
target_include_directories(lazer-uac2-transport-probe PRIVATE
    "${CMAKE_CURRENT_LIST_DIR}/../../src"
    "${libusb_SOURCE_DIR}/libusb")
target_compile_features(lazer-uac2-transport-probe PRIVATE cxx_std_20)
if(WIN32)
    target_compile_definitions(lazer-uac2-transport-probe PRIVATE NOMINMAX)
endif()
if(UNIX)
    target_link_libraries(lazer-uac2-transport-probe PRIVATE Threads::Threads)
endif()
add_test(NAME lazer-uac2-transport COMMAND lazer-uac2-transport-probe)
set_tests_properties(lazer-uac2-transport PROPERTIES TIMEOUT 20)

add_executable(lazer-uac2-output-probe
    output_probe.cpp fake_libusb.cpp
    "${CMAKE_CURRENT_LIST_DIR}/../../src/android_uac2_output.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/../../src/android_uac2_control.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/../../src/android_uac2_iso_transport.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/../../src/android_uac2_packetizer.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/../../src/dop_packer.cpp")
target_include_directories(lazer-uac2-output-probe PRIVATE
    "${CMAKE_CURRENT_LIST_DIR}/../../src"
    "${CMAKE_CURRENT_LIST_DIR}/../../include"
    "${libusb_SOURCE_DIR}/libusb")
target_compile_features(lazer-uac2-output-probe PRIVATE cxx_std_20)
target_link_libraries(lazer-uac2-output-probe PRIVATE Threads::Threads)
if(WIN32)
    target_compile_definitions(lazer-uac2-output-probe PRIVATE NOMINMAX)
endif()
if(NOT MSVC)
    target_compile_options(lazer-uac2-output-probe PRIVATE -Wall -Wextra -Werror)
endif()
add_test(NAME lazer-uac2-output COMMAND lazer-uac2-output-probe)
set_tests_properties(lazer-uac2-output PROPERTIES TIMEOUT 20)

if(MSVC)
    foreach(probe lazer-uac2-transport-probe lazer-uac2-output-probe)
        target_compile_options(${probe} PRIVATE /EHsc /utf-8)
    endforeach()
endif()
