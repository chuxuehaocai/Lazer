cmake_minimum_required(VERSION 3.21)
project(lazer_audio_bridge LANGUAGES CXX)

# The growing-file reader the Dart side plugs into the engine's reader callbacks.
# It deliberately links to nothing: no FFmpeg, no platform audio API, no engine
# headers. That keeps it buildable (and testable) on every host, including ones
# where the engine itself cannot be built yet.

option(LAZER_AUDIO_BRIDGE_BUILD_PROBES
    "Build the ABI layout probe used to verify the Dart mirror" OFF)

add_library(lazer-audio-bridge SHARED src/growing_reader.cpp)
target_compile_features(lazer-audio-bridge PRIVATE cxx_std_20)
target_compile_definitions(lazer-audio-bridge PRIVATE LAZER_BRIDGE_EXPORTS)
set_target_properties(lazer-audio-bridge PROPERTIES
    CXX_EXTENSIONS OFF
    POSITION_INDEPENDENT_CODE ON)
if(APPLE)
    set_target_properties(lazer-audio-bridge PROPERTIES
        BUILD_RPATH "@loader_path" INSTALL_RPATH "@loader_path")
elseif(UNIX)
    set_target_properties(lazer-audio-bridge PROPERTIES
        BUILD_RPATH "\$ORIGIN" INSTALL_RPATH "\$ORIGIN")
endif()
if(WIN32 AND NOT MSVC)
    # The Dart loader opens the DLL by name; MinGW would otherwise add a `lib`
    # prefix that only the Linux naming convention has.
    set_target_properties(lazer-audio-bridge PROPERTIES PREFIX "")
endif()
if(MSVC)
    # Same rule as the engine: the app ships without the VC++ redistributable.
    set_property(TARGET lazer-audio-bridge PROPERTY
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    target_compile_options(lazer-audio-bridge PRIVATE /W4 /permissive- /EHsc)
else()
    target_compile_options(lazer-audio-bridge PRIVATE -Wall -Wextra)
endif()

if(LAZER_AUDIO_BRIDGE_BUILD_PROBES)
    # Prints the layout the C compiler produces for `lazer_audio_api.h`; the Dart
    # side asserts the same numbers (`dart tool/native_abi_check.dart`).
    add_executable(lazer-audio-abi-layout tools/abi_layout_probe.cpp)
    target_compile_features(lazer-audio-abi-layout PRIVATE cxx_std_20)
    target_include_directories(lazer-audio-abi-layout PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/../lazer-audio/include")
    if(MSVC)
        set_property(TARGET lazer-audio-abi-layout PROPERTY
            MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    endif()
endif()
