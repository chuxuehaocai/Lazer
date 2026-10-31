cmake_minimum_required(VERSION 3.21)
project(lazer_audio LANGUAGES C CXX)

option(LAZER_AUDIO_BUILD_PROBE "Build the lazer-audio-probe console harness" OFF)
option(LAZER_AUDIO_TEST_ALLOW_ALSA_NULL
    "Allow the test-only ALSA null PCM route (requires a Linux probe build)" OFF)

option(LAZER_ANDROID_BUILD_ENGINE "Build the complete Android AAudio playback engine" OFF)
if(ANDROID AND NOT LAZER_ANDROID_BUILD_ENGINE)
    option(LAZER_ANDROID_BUILD_UAC2 "Build Android UAC2 USB direct-output native transport" OFF)
    option(LAZER_ANDROID_BUILD_DSD "Build the Android DSD decoder" OFF)
    if(NOT LAZER_ANDROID_BUILD_UAC2 AND NOT LAZER_ANDROID_BUILD_DSD)
        message(FATAL_ERROR
            "No Android native target was requested. Set LAZER_ANDROID_BUILD_UAC2=ON and/or "
            "LAZER_ANDROID_BUILD_DSD=ON.")
    endif()
    foreach(_lazer_android_abi IN ITEMS "${ANDROID_ABI}" "${CMAKE_ANDROID_ARCH_ABI}")
        if(_lazer_android_abi AND NOT _lazer_android_abi MATCHES "^(arm64-v8a|armeabi-v7a|x86_64)$")
            message(FATAL_ERROR
                "The Android native audio targets support arm64-v8a, armeabi-v7a and x86_64; "
                "requested ${_lazer_android_abi}.")
        endif()
    endforeach()
    find_package(Threads REQUIRED)

    if(LAZER_ANDROID_BUILD_UAC2)
        # Pin the upstream release commit and archive hash. The source set below follows libusb's
        # own android/jni/libusb.mk, keeping its Linux usbfs backend and Android feature config in
        # sync without building the unrelated DSD/FFmpeg SDK.
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

        set(_lazer_libusb_root "${libusb_SOURCE_DIR}")
        add_library(usb-1.0 SHARED
            "${_lazer_libusb_root}/libusb/core.c"
            "${_lazer_libusb_root}/libusb/descriptor.c"
            "${_lazer_libusb_root}/libusb/hotplug.c"
            "${_lazer_libusb_root}/libusb/io.c"
            "${_lazer_libusb_root}/libusb/sync.c"
            "${_lazer_libusb_root}/libusb/strerror.c"
            "${_lazer_libusb_root}/libusb/os/linux_usbfs.c"
            "${_lazer_libusb_root}/libusb/os/events_posix.c"
            "${_lazer_libusb_root}/libusb/os/threads_posix.c"
            "${_lazer_libusb_root}/libusb/os/linux_netlink.c")
        target_include_directories(usb-1.0 PRIVATE
            "${_lazer_libusb_root}/android"
            "${_lazer_libusb_root}/libusb"
            "${_lazer_libusb_root}/libusb/os")
        target_compile_features(usb-1.0 PRIVATE c_std_11)
        target_compile_options(usb-1.0 PRIVATE -fvisibility=hidden -pthread)
        target_link_libraries(usb-1.0 PRIVATE Threads::Threads log)
        set_target_properties(usb-1.0 PROPERTIES
            OUTPUT_NAME "usb-1.0"
            C_EXTENSIONS ON
            POSITION_INDEPENDENT_CODE ON)

        add_library(lazer-uac2 SHARED
            src/android_uac2_jni.cpp
            src/android_uac2_iso_transport.cpp
            src/android_uac2_packetizer.cpp
            src/dop_packer.cpp)
        target_include_directories(lazer-uac2 PRIVATE
            "${CMAKE_CURRENT_LIST_DIR}/src"
            "${_lazer_libusb_root}/libusb")
        target_link_libraries(lazer-uac2 PRIVATE usb-1.0 Threads::Threads log)
        target_compile_features(lazer-uac2 PRIVATE cxx_std_20)
        set_target_properties(lazer-uac2 PROPERTIES
            CXX_EXTENSIONS OFF
            POSITION_INDEPENDENT_CODE ON)
    endif()

    if(LAZER_ANDROID_BUILD_DSD)
        if(ANDROID_PLATFORM MATCHES "^android-([0-9]+)$")
            set(_lazer_android_api "${CMAKE_MATCH_1}")
        elseif(ANDROID_PLATFORM MATCHES "^([0-9]+)$")
            set(_lazer_android_api "${CMAKE_MATCH_1}")
        elseif(CMAKE_ANDROID_API MATCHES "^[0-9]+$")
            set(_lazer_android_api "${CMAKE_ANDROID_API}")
        else()
            message(FATAL_ERROR "Set ANDROID_PLATFORM to android-24 or newer for the Android DSD target.")
        endif()
        if(_lazer_android_api LESS 24)
            message(FATAL_ERROR "The Android DSD FFmpeg SDK requires API 24 or newer.")
        endif()

        # FFmpeg is required only by the DSD decoder. USB transport-only builds remain independent
        # of this external SDK and its configure-time downloads.
        set(LAZER_FFMPEG_ROOT "" CACHE PATH "Directory holding the prebuilt FFmpeg include/ lib/ bin/")
        list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_LIST_DIR}/cmake")
        find_package(LazerFFmpeg REQUIRED)
        include(CheckCXXSourceCompiles)
        set(CMAKE_REQUIRED_INCLUDES ${LAZER_FFMPEG_INCLUDE_DIRS})
        unset(LAZER_FFMPEG_HAS_REQUIRED_DSD_APIS CACHE)
        check_cxx_source_compiles("\
            #include <libavutil/channel_layout.h>\n\
            #include <libavutil/samplefmt.h>\n\
            #include <libswresample/swresample.h>\n\
            #include <type_traits>\n\
            int main() {\n\
                static_assert(AV_SAMPLE_FMT_DSD >= 0);\n\
                AVChannelLayout layout = AV_CHANNEL_LAYOUT_STEREO;\n\
                using SetOpts2 = decltype(&swr_alloc_set_opts2);\n\
                static_assert(std::is_pointer<SetOpts2>::value);\n\
                return layout.nb_channels != 2;\n\
            }" LAZER_FFMPEG_HAS_REQUIRED_DSD_APIS)
        unset(CMAKE_REQUIRED_INCLUDES)
        if(NOT LAZER_FFMPEG_HAS_REQUIRED_DSD_APIS)
            message(FATAL_ERROR
                "The native HiFi engine requires FFmpeg with AV_SAMPLE_FMT_DSD, AVChannelLayout, and "
                "swr_alloc_set_opts2. Do not use a distro/Homebrew FFmpeg without those APIs; configure "
                "with -DLAZER_FFMPEG_ROOT=<DSD-capable FFmpeg prefix> or FFMPEG_ROOT.")
        endif()

        add_library(lazer-audio-dsd SHARED
            src/common.cpp
            src/dff_dsf_reader.cpp
            src/source.cpp
            src/dop_packer.cpp
            src/native_dsd_packer.cpp
            src/dsd_pcm_decoder.cpp
            src/android_dsd_jni.cpp)
        target_include_directories(lazer-audio-dsd PRIVATE
            "${CMAKE_CURRENT_LIST_DIR}/include"
            "${CMAKE_CURRENT_LIST_DIR}/src"
            ${LAZER_FFMPEG_INCLUDE_DIRS})
        target_link_libraries(lazer-audio-dsd PRIVATE ${LAZER_FFMPEG_LIBRARIES} Threads::Threads)
        target_compile_features(lazer-audio-dsd PRIVATE cxx_std_20)
        set_target_properties(lazer-audio-dsd PROPERTIES
            CXX_EXTENSIONS OFF
            POSITION_INDEPENDENT_CODE ON)
    endif()

    if((ANDROID_STL AND NOT ANDROID_STL STREQUAL "c++_static") OR
       (CMAKE_ANDROID_STL_TYPE AND NOT CMAKE_ANDROID_STL_TYPE STREQUAL "c++_static"))
        message(FATAL_ERROR
            "Android native audio targets currently expect the Android c++_static runtime; "
            "configure with -DANDROID_STL=c++_static.")
    endif()
    message(STATUS "Building Android native audio targets: UAC2=${LAZER_ANDROID_BUILD_UAC2}, DSD=${LAZER_ANDROID_BUILD_DSD}")
    return()
endif()

# FFmpeg stays outside the repository. Windows consumes the supplied import-library bundle;
# Linux/macOS use pkg-config unless -DLAZER_FFMPEG_ROOT=<dir> or FFMPEG_ROOT points to a shared
# development package with lib/pkgconfig metadata. All desktop builds require DSD-capable FFmpeg.
set(LAZER_FFMPEG_ROOT "" CACHE PATH "Directory holding the prebuilt FFmpeg include/ lib/ bin/")
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_LIST_DIR}/cmake")
find_package(LazerFFmpeg REQUIRED)
include(CheckCXXSourceCompiles)
set(CMAKE_REQUIRED_INCLUDES ${LAZER_FFMPEG_INCLUDE_DIRS})
unset(LAZER_FFMPEG_HAS_REQUIRED_DSD_APIS CACHE)
check_cxx_source_compiles("\
    #include <libavutil/channel_layout.h>\n\
    #include <libavutil/samplefmt.h>\n\
    #include <libswresample/swresample.h>\n\
    #include <type_traits>\n\
    int main() {\n\
        static_assert(AV_SAMPLE_FMT_DSD >= 0);\n\
        AVChannelLayout layout = AV_CHANNEL_LAYOUT_STEREO;\n\
        using SetOpts2 = decltype(&swr_alloc_set_opts2);\n\
        static_assert(std::is_pointer<SetOpts2>::value);\n\
        return layout.nb_channels != 2;\n\
    }" LAZER_FFMPEG_HAS_REQUIRED_DSD_APIS)
unset(CMAKE_REQUIRED_INCLUDES)
if(NOT LAZER_FFMPEG_HAS_REQUIRED_DSD_APIS)
    message(FATAL_ERROR
        "The native HiFi engine requires FFmpeg with AV_SAMPLE_FMT_DSD, AVChannelLayout, and "
        "swr_alloc_set_opts2. Do not use a distro/Homebrew FFmpeg without those APIs; configure "
        "with -DLAZER_FFMPEG_ROOT=<DSD-capable FFmpeg prefix> or FFMPEG_ROOT.")
endif()

set(LAZER_AUDIO_PLATFORM_SOURCES "")
set(LAZER_AUDIO_PLATFORM_LIBRARIES "")
if(WIN32)
    list(APPEND LAZER_AUDIO_PLATFORM_SOURCES
        src/output_wasapi.cpp
        src/wasapi_pcm_format_policy.cpp
        src/device_catalog_wasapi.cpp
        src/endpoint_volume_wasapi.cpp
        src/pcm_format_probe_wasapi.cpp)
    list(APPEND LAZER_AUDIO_PLATFORM_LIBRARIES ole32 mmdevapi user32 advapi32)
elseif(ANDROID)
    list(APPEND LAZER_AUDIO_PLATFORM_SOURCES src/output_aaudio.cpp)
    list(APPEND LAZER_AUDIO_PLATFORM_LIBRARIES aaudio android log)
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(ALSA REQUIRED IMPORTED_TARGET alsa)
    list(APPEND LAZER_AUDIO_PLATFORM_SOURCES
        src/output_alsa.cpp
        src/device_catalog_alsa.cpp)
    list(APPEND LAZER_AUDIO_PLATFORM_LIBRARIES PkgConfig::ALSA)
elseif(APPLE)
    find_library(COREAUDIO_FRAMEWORK CoreAudio REQUIRED)
    find_library(COREFOUNDATION_FRAMEWORK CoreFoundation REQUIRED)
    find_library(AUDIOTOOLBOX_FRAMEWORK AudioToolbox REQUIRED)
    list(APPEND LAZER_AUDIO_PLATFORM_SOURCES
        src/output_coreaudio.cpp
        src/device_catalog_coreaudio.cpp
        src/coreaudio_format_policy.cpp)
    list(APPEND LAZER_AUDIO_PLATFORM_LIBRARIES
        ${COREAUDIO_FRAMEWORK}
        ${COREFOUNDATION_FRAMEWORK}
        ${AUDIOTOOLBOX_FRAMEWORK})
else()
    message(FATAL_ERROR "No local audio output backend is implemented for ${CMAKE_SYSTEM_NAME}")
endif()

add_library(lazer-audio SHARED
    src/common.cpp
    src/dff_dsf_reader.cpp
    src/engine.cpp
    src/source.cpp
    src/dop_packer.cpp
    src/native_dsd_packer.cpp
    src/dsp_chain.cpp
    src/ring_buffer.cpp
    src/pcm_output.cpp
    src/api.cpp
    ${LAZER_AUDIO_PLATFORM_SOURCES}
)

target_include_directories(lazer-audio PRIVATE
    "${CMAKE_CURRENT_LIST_DIR}/include"
    "${LAZER_FFMPEG_INCLUDE_DIR}")
target_link_libraries(lazer-audio PRIVATE ${LAZER_FFMPEG_LIBRARIES}
    ${LAZER_AUDIO_PLATFORM_LIBRARIES})
target_compile_features(lazer-audio PRIVATE cxx_std_20)
target_compile_definitions(lazer-audio PRIVATE LAZER_AUDIO_EXPORTS)
if(ANDROID)
    # FFmpeg's static SIMD objects refer directly to internal tables. Keep them
    # local to this DSO, both for PIC linkage and to avoid interposing other
    # plugins' FFmpeg/libc++ symbols. Only the app's stable C ABI is exported.
    target_link_options(lazer-audio PRIVATE
        "-Wl,--exclude-libs,ALL"
        "-Wl,--version-script=${CMAKE_CURRENT_LIST_DIR}/src/exports_android.map"
        "-Wl,-z,max-page-size=16384")
    set_property(TARGET lazer-audio APPEND PROPERTY LINK_DEPENDS
        "${CMAKE_CURRENT_LIST_DIR}/src/exports_android.map")
endif()
if(WIN32)
    target_compile_definitions(lazer-audio PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
endif()
if(MSVC)
    target_link_options(lazer-audio PRIVATE "/EXPORT:lazer_audio_abi_version")
endif()
set_target_properties(lazer-audio PROPERTIES CXX_EXTENSIONS OFF)
if(APPLE)
    set_target_properties(lazer-audio PROPERTIES BUILD_RPATH "@loader_path" INSTALL_RPATH "@loader_path")
elseif(UNIX)
    set_target_properties(lazer-audio PROPERTIES BUILD_RPATH "\$ORIGIN" INSTALL_RPATH "\$ORIGIN")
endif()

# Same rule as the taskbar bridge: the app ships without a Visual C++ redistributable, so the CRT
# is linked statically. FFmpeg objects never cross that boundary; only the C ABI does.
if(MSVC)
    set_property(TARGET lazer-audio PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    target_compile_options(lazer-audio PRIVATE /W4 /permissive- /EHsc)
endif()

# JNA loads the DLL by absolute path, but FFmpeg's DLLs must sit beside it or be found by the
# loader, so copy them into the build directory for local runs and jpackage staging.
if(LAZER_FFMPEG_RUNTIME_FILES)
    add_custom_command(TARGET lazer-audio POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different ${LAZER_FFMPEG_RUNTIME_FILES}
                "$<TARGET_FILE_DIR:lazer-audio>"
        VERBATIM)
endif()

# Offline decode/render self test, built on demand with -DLAZER_AUDIO_BUILD_PROBE=ON.
if(LAZER_AUDIO_BUILD_PROBE)
    # Exercise the complete native playback session without a physical endpoint. The test links the
    # Engine sources directly and supplies its own fake platform-output factory.
    add_executable(lazer-audio-engine-gapless-probe
        tools/lazer_audio_engine_gapless_probe.cpp
        src/common.cpp
        src/dff_dsf_reader.cpp
        src/engine.cpp
        src/source.cpp
        src/dop_packer.cpp
        src/native_dsd_packer.cpp
        src/dsp_chain.cpp
        src/ring_buffer.cpp
        src/pcm_output.cpp)
    target_include_directories(lazer-audio-engine-gapless-probe PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/include"
        "${CMAKE_CURRENT_LIST_DIR}/src"
        "${LAZER_FFMPEG_INCLUDE_DIR}")
    target_link_libraries(lazer-audio-engine-gapless-probe PRIVATE ${LAZER_FFMPEG_LIBRARIES})
    target_compile_features(lazer-audio-engine-gapless-probe PRIVATE cxx_std_20)
    if(WIN32)
        target_compile_definitions(lazer-audio-engine-gapless-probe PRIVATE
            UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
    endif()
    if(MSVC)
        set_property(TARGET lazer-audio-engine-gapless-probe PROPERTY
            MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        target_compile_options(lazer-audio-engine-gapless-probe PRIVATE /W4 /permissive- /EHsc)
    endif()
    if(LAZER_FFMPEG_RUNTIME_FILES)
        add_custom_command(TARGET lazer-audio-engine-gapless-probe POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different ${LAZER_FFMPEG_RUNTIME_FILES}
                    "$<TARGET_FILE_DIR:lazer-audio-engine-gapless-probe>"
            VERBATIM)
    endif()
    enable_testing()
    add_test(NAME lazer-audio-engine-gapless
        COMMAND $<TARGET_FILE:lazer-audio-engine-gapless-probe>)

    # The bit-perfect claim and the three facts it is derived from (ABI v25). Captures the engine's
    # real output bytes through a fake fixed-period endpoint, so it proves byte-exactness without a
    # device, and proves the claim goes away when the DSP is in the path or the format is not the
    # source's.
    add_executable(lazer-audio-engine-bit-perfect-probe
        tools/lazer_audio_engine_bit_perfect_probe.cpp
        src/common.cpp
        src/dff_dsf_reader.cpp
        src/engine.cpp
        src/source.cpp
        src/dop_packer.cpp
        src/native_dsd_packer.cpp
        src/dsp_chain.cpp
        src/ring_buffer.cpp
        src/pcm_output.cpp)
    target_include_directories(lazer-audio-engine-bit-perfect-probe PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/include"
        "${CMAKE_CURRENT_LIST_DIR}/src"
        "${LAZER_FFMPEG_INCLUDE_DIR}")
    target_link_libraries(lazer-audio-engine-bit-perfect-probe PRIVATE ${LAZER_FFMPEG_LIBRARIES})
    target_compile_features(lazer-audio-engine-bit-perfect-probe PRIVATE cxx_std_20)
    if(WIN32)
        target_compile_definitions(lazer-audio-engine-bit-perfect-probe PRIVATE
            UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
    endif()
    if(MSVC)
        set_property(TARGET lazer-audio-engine-bit-perfect-probe PROPERTY
            MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        target_compile_options(lazer-audio-engine-bit-perfect-probe PRIVATE /W4 /permissive- /EHsc)
    endif()
    if(LAZER_FFMPEG_RUNTIME_FILES)
        add_custom_command(TARGET lazer-audio-engine-bit-perfect-probe POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different ${LAZER_FFMPEG_RUNTIME_FILES}
                    "$<TARGET_FILE_DIR:lazer-audio-engine-bit-perfect-probe>"
            VERBATIM)
    endif()
    add_test(NAME lazer-audio-engine-bit-perfect
        COMMAND $<TARGET_FILE:lazer-audio-engine-bit-perfect-probe>)

    # Ring/producer stress: a paced fake endpoint runs the whole producer -> ring -> render path and
    # the case asserts that a producer which keeps up never pads, and that an injected stall is
    # counted, bounded by the stall and recovered from.
    add_executable(lazer-audio-ring-stress-probe
        tools/lazer_audio_ring_stress_probe.cpp
        src/common.cpp
        src/dff_dsf_reader.cpp
        src/engine.cpp
        src/source.cpp
        src/dop_packer.cpp
        src/native_dsd_packer.cpp
        src/dsp_chain.cpp
        src/ring_buffer.cpp
        src/pcm_output.cpp)
    target_include_directories(lazer-audio-ring-stress-probe PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/include"
        "${CMAKE_CURRENT_LIST_DIR}/src"
        "${LAZER_FFMPEG_INCLUDE_DIR}")
    target_link_libraries(lazer-audio-ring-stress-probe PRIVATE ${LAZER_FFMPEG_LIBRARIES})
    target_compile_features(lazer-audio-ring-stress-probe PRIVATE cxx_std_20)
    if(WIN32)
        target_compile_definitions(lazer-audio-ring-stress-probe PRIVATE
            UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
    endif()
    if(MSVC)
        set_property(TARGET lazer-audio-ring-stress-probe PROPERTY
            MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        target_compile_options(lazer-audio-ring-stress-probe PRIVATE /W4 /permissive- /EHsc)
    endif()
    if(LAZER_FFMPEG_RUNTIME_FILES)
        add_custom_command(TARGET lazer-audio-ring-stress-probe POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different ${LAZER_FFMPEG_RUNTIME_FILES}
                    "$<TARGET_FILE_DIR:lazer-audio-ring-stress-probe>"
            VERBATIM)
    endif()
    add_test(NAME lazer-audio-ring-stress
        COMMAND $<TARGET_FILE:lazer-audio-ring-stress-probe>)
    set_tests_properties(lazer-audio-ring-stress PROPERTIES TIMEOUT 300)

    # Validate the Engine's global RequireDoP policy against PCM and raw stereo DSD using a
    # variable-write fake endpoint; no physical audio device is opened.
    add_executable(lazer-audio-engine-dop-probe
        tools/lazer_audio_engine_dop_probe.cpp
        src/common.cpp
        src/dff_dsf_reader.cpp
        src/engine.cpp
        src/source.cpp
        src/dop_packer.cpp
        src/native_dsd_packer.cpp
        src/dsp_chain.cpp
        src/ring_buffer.cpp
        src/pcm_output.cpp)
    target_include_directories(lazer-audio-engine-dop-probe PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/include"
        "${CMAKE_CURRENT_LIST_DIR}/src"
        "${LAZER_FFMPEG_INCLUDE_DIR}")
    target_link_libraries(lazer-audio-engine-dop-probe PRIVATE ${LAZER_FFMPEG_LIBRARIES})
    target_compile_features(lazer-audio-engine-dop-probe PRIVATE cxx_std_20)
    if(WIN32)
        target_compile_definitions(lazer-audio-engine-dop-probe PRIVATE
            UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
    endif()
    if(MSVC)
        set_property(TARGET lazer-audio-engine-dop-probe PROPERTY
            MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        target_compile_options(lazer-audio-engine-dop-probe PRIVATE /W4 /permissive- /EHsc)
    endif()
    if(LAZER_FFMPEG_RUNTIME_FILES)
        add_custom_command(TARGET lazer-audio-engine-dop-probe POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different ${LAZER_FFMPEG_RUNTIME_FILES}
                    "$<TARGET_FILE_DIR:lazer-audio-engine-dop-probe>"
            VERBATIM)
    endif()
    add_test(NAME lazer-audio-engine-dop
        COMMAND $<TARGET_FILE:lazer-audio-engine-dop-probe>)
    set_tests_properties(lazer-audio-engine-dop PROPERTIES TIMEOUT 30)

    # Exercise the direct Native DSD request/session contract without ALSA hardware.
    add_executable(lazer-audio-engine-native-dsd-probe
        tools/lazer_audio_engine_native_dsd_probe.cpp
        src/common.cpp
        src/dff_dsf_reader.cpp
        src/engine.cpp
        src/source.cpp
        src/dop_packer.cpp
        src/native_dsd_packer.cpp
        src/dsp_chain.cpp
        src/ring_buffer.cpp
        src/pcm_output.cpp)
    target_include_directories(lazer-audio-engine-native-dsd-probe PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/include"
        "${CMAKE_CURRENT_LIST_DIR}/src"
        "${LAZER_FFMPEG_INCLUDE_DIR}")
    target_link_libraries(lazer-audio-engine-native-dsd-probe PRIVATE ${LAZER_FFMPEG_LIBRARIES})
    target_compile_features(lazer-audio-engine-native-dsd-probe PRIVATE cxx_std_20)
    if(WIN32)
        target_compile_definitions(lazer-audio-engine-native-dsd-probe PRIVATE
            UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
    endif()
    if(MSVC)
        set_property(TARGET lazer-audio-engine-native-dsd-probe PROPERTY
            MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        target_compile_options(lazer-audio-engine-native-dsd-probe PRIVATE /W4 /permissive- /EHsc)
    endif()
    if(LAZER_FFMPEG_RUNTIME_FILES)
        add_custom_command(TARGET lazer-audio-engine-native-dsd-probe POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different ${LAZER_FFMPEG_RUNTIME_FILES}
                    "$<TARGET_FILE_DIR:lazer-audio-engine-native-dsd-probe>"
            VERBATIM)
    endif()
    add_test(NAME lazer-audio-engine-native-dsd
        COMMAND $<TARGET_FILE:lazer-audio-engine-native-dsd-probe>)
    set_tests_properties(lazer-audio-engine-native-dsd PROPERTIES TIMEOUT 30)

    # Keep ALSA recovery state semantics executable without an ALSA device or alsa-lib runtime.
    add_executable(lazer-audio-alsa-recovery-probe tools/lazer_audio_alsa_recovery_probe.cpp)
    target_include_directories(lazer-audio-alsa-recovery-probe PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/src")
    target_compile_features(lazer-audio-alsa-recovery-probe PRIVATE cxx_std_20)
    if(MSVC)
        set_property(TARGET lazer-audio-alsa-recovery-probe PROPERTY
            MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        target_compile_options(lazer-audio-alsa-recovery-probe PRIVATE /W4 /permissive- /EHsc)
    endif()
    add_test(NAME lazer-audio-alsa-recovery
        COMMAND $<TARGET_FILE:lazer-audio-alsa-recovery-probe>)
    set_tests_properties(lazer-audio-alsa-recovery PROPERTIES TIMEOUT 15)

    # Verify ALSA's final PCM byte-layout conversions without requiring alsa-lib or a device.
    add_executable(lazer-audio-alsa-pcm-packing-probe
        tools/lazer_audio_alsa_pcm_packing_probe.cpp)
    target_include_directories(lazer-audio-alsa-pcm-packing-probe PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/src")
    target_compile_features(lazer-audio-alsa-pcm-packing-probe PRIVATE cxx_std_20)
    if(MSVC)
        set_property(TARGET lazer-audio-alsa-pcm-packing-probe PROPERTY
            MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        target_compile_options(lazer-audio-alsa-pcm-packing-probe PRIVATE /W4 /WX /permissive- /EHsc)
    endif()
    add_test(NAME lazer-audio-alsa-pcm-packing
        COMMAND $<TARGET_FILE:lazer-audio-alsa-pcm-packing-probe>)
    set_tests_properties(lazer-audio-alsa-pcm-packing PROPERTIES TIMEOUT 15)

    # Run the actual WASAPI PCM support/Initialize fallback policy with injected result probes.
    # The test is platform-independent; the WASAPI adapter uses the same policy on Windows.
    add_executable(lazer-audio-wasapi-pcm-policy-probe
        tools/lazer_audio_wasapi_pcm_policy_probe.cpp
        src/wasapi_pcm_format_policy.cpp)
    target_include_directories(lazer-audio-wasapi-pcm-policy-probe PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/src")
    target_compile_features(lazer-audio-wasapi-pcm-policy-probe PRIVATE cxx_std_20)
    if(WIN32)
        target_compile_definitions(lazer-audio-wasapi-pcm-policy-probe PRIVATE
            UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
    endif()
    if(MSVC)
        set_property(TARGET lazer-audio-wasapi-pcm-policy-probe PROPERTY
            MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        target_compile_options(lazer-audio-wasapi-pcm-policy-probe PRIVATE /W4 /permissive- /EHsc)
    endif()
    add_test(NAME lazer-audio-wasapi-pcm-policy
        COMMAND $<TARGET_FILE:lazer-audio-wasapi-pcm-policy-probe>)
    set_tests_properties(lazer-audio-wasapi-pcm-policy PROPERTIES TIMEOUT 15)

    # Keep CoreAudio's target-vs-HAL PCM format policy executable on non-Apple build hosts.
    # This validates negotiation decisions only; the HAL output adapter itself is Apple-only.
    add_executable(lazer-audio-coreaudio-policy-probe
        tools/lazer_audio_coreaudio_policy_probe.cpp
        src/coreaudio_format_policy.cpp)
    target_include_directories(lazer-audio-coreaudio-policy-probe PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/include"
        "${CMAKE_CURRENT_LIST_DIR}/src"
        "${LAZER_FFMPEG_INCLUDE_DIR}")
    target_compile_features(lazer-audio-coreaudio-policy-probe PRIVATE cxx_std_20)
    if(WIN32)
        target_compile_definitions(lazer-audio-coreaudio-policy-probe PRIVATE
            UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
    endif()
    if(MSVC)
        set_property(TARGET lazer-audio-coreaudio-policy-probe PROPERTY
            MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        target_compile_options(lazer-audio-coreaudio-policy-probe PRIVATE /W4 /permissive- /EHsc)
    endif()
    add_test(NAME lazer-audio-coreaudio-policy
        COMMAND $<TARGET_FILE:lazer-audio-coreaudio-policy-probe>)
    set_tests_properties(lazer-audio-coreaudio-policy PROPERTIES TIMEOUT 15)

    # Exercise the realtime callback's lock-free PCM queue, planar/interleaved layouts and byte
    # order on every host; the actual HAL IOProc still requires the Apple SDK and a macOS runner.
    add_executable(lazer-audio-coreaudio-queue-probe
        tools/lazer_audio_coreaudio_queue_probe.cpp)
    target_include_directories(lazer-audio-coreaudio-queue-probe PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/src")
    target_compile_features(lazer-audio-coreaudio-queue-probe PRIVATE cxx_std_20)
    if(MSVC)
        set_property(TARGET lazer-audio-coreaudio-queue-probe PROPERTY
            MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        target_compile_options(lazer-audio-coreaudio-queue-probe PRIVATE /W4 /WX /permissive- /EHsc)
    endif()
    add_test(NAME lazer-audio-coreaudio-queue
        COMMAND $<TARGET_FILE:lazer-audio-coreaudio-queue-probe>)
    set_tests_properties(lazer-audio-coreaudio-queue PROPERTIES TIMEOUT 15)

    # Exercise the bounded queued-source PCM staging buffer without starting an Engine or audio
    # backend; this remains safe to build while the engine integration is under development.
    add_executable(lazer-audio-queued-pcm-buffer-probe
        tools/lazer_audio_queued_pcm_buffer_probe.cpp)
    target_include_directories(lazer-audio-queued-pcm-buffer-probe PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/include"
        "${CMAKE_CURRENT_LIST_DIR}/src"
        "${LAZER_FFMPEG_INCLUDE_DIR}")
    target_compile_features(lazer-audio-queued-pcm-buffer-probe PRIVATE cxx_std_20)
    if(WIN32)
        target_compile_definitions(lazer-audio-queued-pcm-buffer-probe PRIVATE
            UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
    endif()
    if(MSVC)
        set_property(TARGET lazer-audio-queued-pcm-buffer-probe PROPERTY
            MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        target_compile_options(lazer-audio-queued-pcm-buffer-probe PRIVATE /W4 /permissive- /EHsc)
    endif()
    add_test(NAME lazer-audio-queued-pcm-buffer
        COMMAND $<TARGET_FILE:lazer-audio-queued-pcm-buffer-probe>)
    set_tests_properties(lazer-audio-queued-pcm-buffer PROPERTIES TIMEOUT 15)

    # End-to-end exact integer PCM output and gapless capture over the advertised rate/depth grid.
    add_executable(lazer-audio-engine-pcm-matrix-probe
        tools/lazer_audio_engine_pcm_matrix_probe.cpp
        src/common.cpp
        src/dff_dsf_reader.cpp
        src/engine.cpp
        src/source.cpp
        src/dop_packer.cpp
        src/native_dsd_packer.cpp
        src/dsp_chain.cpp
        src/ring_buffer.cpp
        src/pcm_output.cpp)
    target_include_directories(lazer-audio-engine-pcm-matrix-probe PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/include"
        "${CMAKE_CURRENT_LIST_DIR}/src"
        "${LAZER_FFMPEG_INCLUDE_DIR}")
    target_link_libraries(lazer-audio-engine-pcm-matrix-probe PRIVATE ${LAZER_FFMPEG_LIBRARIES})
    target_compile_features(lazer-audio-engine-pcm-matrix-probe PRIVATE cxx_std_20)
    if(WIN32)
        target_compile_definitions(lazer-audio-engine-pcm-matrix-probe PRIVATE
            UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
    endif()
    if(MSVC)
        set_property(TARGET lazer-audio-engine-pcm-matrix-probe PROPERTY
            MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        target_compile_options(lazer-audio-engine-pcm-matrix-probe PRIVATE /W4 /permissive- /EHsc)
    endif()
    if(LAZER_FFMPEG_RUNTIME_FILES)
        add_custom_command(TARGET lazer-audio-engine-pcm-matrix-probe POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different ${LAZER_FFMPEG_RUNTIME_FILES}
                    "$<TARGET_FILE_DIR:lazer-audio-engine-pcm-matrix-probe>"
            VERBATIM)
    endif()
    add_test(NAME lazer-audio-engine-pcm-matrix
        COMMAND $<TARGET_FILE:lazer-audio-engine-pcm-matrix-probe>)
    add_test(NAME lazer-audio-engine-pcm-reopen
        COMMAND $<TARGET_FILE:lazer-audio-engine-pcm-matrix-probe> --pcm-format-reopen)
    add_test(NAME lazer-audio-engine-cue-gapless
        COMMAND $<TARGET_FILE:lazer-audio-engine-pcm-matrix-probe> --cue-gapless)
    add_test(NAME lazer-audio-engine-replaygain-gapless
        COMMAND $<TARGET_FILE:lazer-audio-engine-pcm-matrix-probe> --replaygain-gapless)
    set_tests_properties(lazer-audio-engine-cue-gapless PROPERTIES TIMEOUT 10)
    set_tests_properties(lazer-audio-engine-replaygain-gapless PROPERTIES TIMEOUT 15)
    set_tests_properties(lazer-audio-engine-pcm-reopen PROPERTIES TIMEOUT 15)

    if(WIN32)
        add_executable(lazer-audio-probe tools/lazer_audio_probe.cpp)
        target_include_directories(lazer-audio-probe PRIVATE "${CMAKE_CURRENT_LIST_DIR}/include")
        target_link_libraries(lazer-audio-probe PRIVATE lazer-audio)
        target_compile_features(lazer-audio-probe PRIVATE cxx_std_20)
        target_compile_definitions(lazer-audio-probe PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
        if(MSVC)
            set_property(TARGET lazer-audio-probe PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        endif()
    endif()

    # Hardware-free regression checks for the float DSP chain and its sample-peak limiter.
    add_executable(lazer-audio-dsp-probe
        tools/lazer_audio_dsp_probe.cpp
        src/dsp_chain.cpp
        src/pcm_output.cpp
    )
    target_include_directories(lazer-audio-dsp-probe PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/include"
        "${CMAKE_CURRENT_LIST_DIR}/src"
        "${LAZER_FFMPEG_INCLUDE_DIR}")
    target_compile_features(lazer-audio-dsp-probe PRIVATE cxx_std_20)
    if(WIN32)
        target_compile_definitions(lazer-audio-dsp-probe PRIVATE
            UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
    endif()
    if(MSVC)
        set_property(TARGET lazer-audio-dsp-probe PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        target_compile_options(lazer-audio-dsp-probe PRIVATE /W4 /permissive- /EHsc)
    endif()
    add_test(NAME lazer-audio-dsp
        COMMAND $<TARGET_FILE:lazer-audio-dsp-probe>)

    # Crossfeed mixes the channels, so its properties (leakage, delay, strength,
    # transparency when off) are measurable on synthetic signals without a device.
    add_executable(lazer-audio-crossfeed-probe
        tools/lazer_audio_crossfeed_probe.cpp
        src/dsp_chain.cpp
    )
    target_include_directories(lazer-audio-crossfeed-probe PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/include"
        "${CMAKE_CURRENT_LIST_DIR}/src"
        "${LAZER_FFMPEG_INCLUDE_DIR}")
    target_compile_features(lazer-audio-crossfeed-probe PRIVATE cxx_std_20)
    if(WIN32)
        target_compile_definitions(lazer-audio-crossfeed-probe PRIVATE
            UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
    endif()
    if(MSVC)
        set_property(TARGET lazer-audio-crossfeed-probe PROPERTY
            MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        target_compile_options(lazer-audio-crossfeed-probe PRIVATE /W4 /permissive- /EHsc)
    endif()
    add_test(NAME lazer-audio-crossfeed
        COMMAND $<TARGET_FILE:lazer-audio-crossfeed-probe>)
    set_tests_properties(lazer-audio-crossfeed PROPERTIES TIMEOUT 20)

    # Verify DoP framing independently of FFmpeg, the engine and physical audio endpoints.
    add_executable(lazer-audio-dop-packer-probe
        tools/lazer_audio_dop_packer_probe.cpp
        src/dop_packer.cpp)
    target_include_directories(lazer-audio-dop-packer-probe PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/src")
    target_compile_features(lazer-audio-dop-packer-probe PRIVATE cxx_std_20)
    if(WIN32)
        target_compile_definitions(lazer-audio-dop-packer-probe PRIVATE
            UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
    endif()
    if(MSVC)
        set_property(TARGET lazer-audio-dop-packer-probe PROPERTY
            MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        target_compile_options(lazer-audio-dop-packer-probe PRIVATE /W4 /WX /permissive- /EHsc)
    endif()
    add_test(NAME lazer-audio-dop-packer
        COMMAND $<TARGET_FILE:lazer-audio-dop-packer-probe>)
    set_tests_properties(lazer-audio-dop-packer PROPERTIES TIMEOUT 15)

    # Verify ALSA Native DSD word packing, endian order and idle padding independently of hardware.
    add_executable(lazer-audio-native-dsd-packer-probe
        tools/lazer_audio_native_dsd_packer_probe.cpp
        src/native_dsd_packer.cpp)
    target_include_directories(lazer-audio-native-dsd-packer-probe PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/src")
    target_compile_features(lazer-audio-native-dsd-packer-probe PRIVATE cxx_std_20)
    if(MSVC)
        set_property(TARGET lazer-audio-native-dsd-packer-probe PROPERTY
            MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        target_compile_options(lazer-audio-native-dsd-packer-probe PRIVATE
            /W4 /WX /permissive- /EHsc)
    endif()
    add_test(NAME lazer-audio-native-dsd-packer
        COMMAND $<TARGET_FILE:lazer-audio-native-dsd-packer-probe>)
    set_tests_properties(lazer-audio-native-dsd-packer PROPERTIES TIMEOUT 15)

    # Source-only verification bypasses WASAPI completely and consumes decoded PCM in memory.
    add_executable(lazer-audio-source-probe
        tools/lazer_audio_source_probe.cpp
        src/common.cpp
        src/dff_dsf_reader.cpp
        src/source.cpp
        src/dop_packer.cpp
        src/native_dsd_packer.cpp
    )
    target_include_directories(lazer-audio-source-probe PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/include"
        "${CMAKE_CURRENT_LIST_DIR}/src"
        "${LAZER_FFMPEG_INCLUDE_DIR}")
    target_link_libraries(lazer-audio-source-probe PRIVATE ${LAZER_FFMPEG_LIBRARIES})
    target_compile_features(lazer-audio-source-probe PRIVATE cxx_std_20)
    if(WIN32)
        target_compile_definitions(lazer-audio-source-probe PRIVATE
            UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
    endif()
    if(MSVC)
        set_property(TARGET lazer-audio-source-probe PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        target_compile_options(lazer-audio-source-probe PRIVATE /W4 /permissive- /EHsc)
    endif()
    if(LAZER_FFMPEG_RUNTIME_FILES)
        add_custom_command(TARGET lazer-audio-source-probe POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different ${LAZER_FFMPEG_RUNTIME_FILES}
                    "$<TARGET_FILE_DIR:lazer-audio-source-probe>"
            VERBATIM)
    endif()

    # Verify the pull-style bounded DSD -> float-PCM facade used by mobile integrations. This
    # probe also exercises cancellation while its ring is back-pressured; fixture-driven decode
    # and seek cases run next to the existing generated DSF source probes in CI.
    add_executable(lazer-audio-dsd-pcm-probe
        tools/lazer_audio_dsd_pcm_probe.cpp
        src/common.cpp
        src/dff_dsf_reader.cpp
        src/source.cpp
        src/dop_packer.cpp
        src/native_dsd_packer.cpp
        src/dsd_pcm_decoder.cpp)
    target_include_directories(lazer-audio-dsd-pcm-probe PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/include"
        "${CMAKE_CURRENT_LIST_DIR}/src"
        "${LAZER_FFMPEG_INCLUDE_DIR}")
    target_link_libraries(lazer-audio-dsd-pcm-probe PRIVATE ${LAZER_FFMPEG_LIBRARIES})
    target_compile_features(lazer-audio-dsd-pcm-probe PRIVATE cxx_std_20)
    if(WIN32)
        target_compile_definitions(lazer-audio-dsd-pcm-probe PRIVATE
            UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
    endif()
    if(MSVC)
        set_property(TARGET lazer-audio-dsd-pcm-probe PROPERTY
            MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        target_compile_options(lazer-audio-dsd-pcm-probe PRIVATE /W4 /permissive- /EHsc)
    endif()
    if(LAZER_FFMPEG_RUNTIME_FILES)
        add_custom_command(TARGET lazer-audio-dsd-pcm-probe POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different ${LAZER_FFMPEG_RUNTIME_FILES}
                    "$<TARGET_FILE_DIR:lazer-audio-dsd-pcm-probe>"
            VERBATIM)
    endif()

    if(CMAKE_SYSTEM_NAME STREQUAL "Linux" AND LAZER_AUDIO_TEST_ALLOW_ALSA_NULL)
        # This probe exercises Native DSD/DoP negotiation and the real AlsaOutput lifecycle over a
        # test-only ALSA null PCM, plus an explicit --loopback mode for snd-aloop digital capture.
        # Null PCM is never accepted by production output.
        target_compile_definitions(lazer-audio PRIVATE LAZER_AUDIO_TEST_ALLOW_ALSA_NULL)
        add_executable(lazer-audio-alsa-output-probe tools/lazer_audio_alsa_output_probe.cpp)
        target_include_directories(lazer-audio-alsa-output-probe PRIVATE
            "${CMAKE_CURRENT_LIST_DIR}/include"
            "${CMAKE_CURRENT_LIST_DIR}/src"
            "${LAZER_FFMPEG_INCLUDE_DIR}")
        target_link_libraries(lazer-audio-alsa-output-probe PRIVATE lazer-audio PkgConfig::ALSA)
        target_compile_features(lazer-audio-alsa-output-probe PRIVATE cxx_std_20)
        add_test(NAME lazer-audio-alsa-output
            COMMAND $<TARGET_FILE:lazer-audio-alsa-output-probe>)
        set_tests_properties(lazer-audio-alsa-output PROPERTIES TIMEOUT 60)
    endif()
endif()

if(LAZER_AUDIO_TEST_ALLOW_ALSA_NULL AND
    (NOT CMAKE_SYSTEM_NAME STREQUAL "Linux" OR NOT LAZER_AUDIO_BUILD_PROBE))
    message(FATAL_ERROR "LAZER_AUDIO_TEST_ALLOW_ALSA_NULL requires a Linux build with LAZER_AUDIO_BUILD_PROBE=ON")
endif()
