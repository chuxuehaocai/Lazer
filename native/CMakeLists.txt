# Builds the native HiFi audio engine (and its reader bridge) for this host.
#
# The engine is the master branch's `native/lazer-audio` tree, unchanged: FFmpeg
# decode, WASAPI / ALSA / CoreAudio output, DSD and DoP, gapless queueing and the
# EQ/limiter chain, behind one C ABI (`lazer_audio_api.h`). Dart talks to it
# through `lib/audio/native/`.
#
# It is opt-in because it needs a *DSD-capable* FFmpeg build, which distro
# packages usually are not. Without one the app still builds and plays through
# just_audio; the native path simply reports unavailable and the app falls back.
#
#   cmake -DLAZER_FFMPEG_ROOT=/path/to/ffmpeg ...
#
# or set the environment when invoking `flutter build`:
#
#   LAZER_FFMPEG_ROOT=/path/to/ffmpeg flutter build linux --release
#
# A checkout that puts the SDK at `third_party/ffmpeg` needs no variable at all.
cmake_minimum_required(VERSION 3.21)
project(lazer_native_audio LANGUAGES C CXX)

set(_lazer_repo_root "${CMAKE_CURRENT_LIST_DIR}/..")

option(LAZER_AUDIO_NATIVE_ENGINE
    "Build the native HiFi audio engine into the app bundle" ON)
option(LAZER_AUDIO_NATIVE_PROBES
    "Also build the engine's offline CTest probes" OFF)

# The engine registers its probes with `add_test` inside its own directory, so the
# top level has to enable testing as well for `ctest` to see them.
if(LAZER_AUDIO_NATIVE_PROBES)
    enable_testing()
endif()

# Resolve the FFmpeg prefix the engine's FindLazerFFmpeg.cmake will use, so this
# file and that module agree on it (cache var, then environment, then third_party).
if(NOT LAZER_FFMPEG_ROOT AND DEFINED ENV{LAZER_FFMPEG_ROOT})
    file(TO_CMAKE_PATH "$ENV{LAZER_FFMPEG_ROOT}" LAZER_FFMPEG_ROOT)
endif()
if(NOT LAZER_FFMPEG_ROOT AND DEFINED ENV{FFMPEG_ROOT})
    file(TO_CMAKE_PATH "$ENV{FFMPEG_ROOT}" LAZER_FFMPEG_ROOT)
endif()
if(NOT LAZER_FFMPEG_ROOT AND
   EXISTS "${_lazer_repo_root}/third_party/ffmpeg/include/libavformat/avformat.h")
    set(LAZER_FFMPEG_ROOT "${_lazer_repo_root}/third_party/ffmpeg")
endif()
if(NOT LAZER_FFMPEG_ROOT AND EXISTS "${_lazer_repo_root}/native/ffmpeg/include/libavformat/avformat.h")
    set(LAZER_FFMPEG_ROOT "${_lazer_repo_root}/native/ffmpeg")
endif()
if(LAZER_FFMPEG_ROOT)
    file(TO_CMAKE_PATH "${LAZER_FFMPEG_ROOT}" LAZER_FFMPEG_ROOT)
endif()

# The bridge has no dependencies, so it is always buildable; it is what lets the
# Dart side stream network sources into the engine.
set(LAZER_AUDIO_BRIDGE_BUILD_PROBES ${LAZER_AUDIO_NATIVE_PROBES})
add_subdirectory(lazer-audio-bridge)

set(LAZER_AUDIO_NATIVE_TARGETS "lazer-audio-bridge")
set(LAZER_AUDIO_NATIVE_RUNTIME_FILES "")
set(LAZER_AUDIO_ENGINE_ENABLED FALSE)

if(LAZER_AUDIO_NATIVE_ENGINE)
    if(NOT LAZER_FFMPEG_ROOT)
        message(STATUS
            "lazer-audio: no DSD-capable FFmpeg found (set LAZER_FFMPEG_ROOT), so the "
            "native engine is not built. The app will use just_audio.")
    elseif(NOT EXISTS "${LAZER_FFMPEG_ROOT}/include/libavformat/avformat.h")
        message(WARNING
            "lazer-audio: '${LAZER_FFMPEG_ROOT}' has no include/libavformat/avformat.h; "
            "the native engine is not built.")
    else()
        set(LAZER_AUDIO_BUILD_PROBE ${LAZER_AUDIO_NATIVE_PROBES} CACHE BOOL
            "Build the native audio probe harness" FORCE)
        add_subdirectory(lazer-audio)
        list(APPEND LAZER_AUDIO_NATIVE_TARGETS lazer-audio)
        set(LAZER_AUDIO_ENGINE_ENABLED TRUE)
        if(WIN32)
            # The engine loads these next to itself; the bundle needs its own copy
            # because `install` runs outside this subdirectory's variable scope.
            file(GLOB LAZER_AUDIO_NATIVE_RUNTIME_FILES
                "${LAZER_FFMPEG_ROOT}/bin/*.dll")
        endif()
        message(STATUS
            "lazer-audio: building the native engine against FFmpeg at ${LAZER_FFMPEG_ROOT}")
    endif()
endif()

# Copies the built libraries (and the FFmpeg DLLs they load) into a bundle
# directory. Call from a platform CMakeLists once its install prefix is known.
function(lazer_install_native_audio destination)
    install(TARGETS ${LAZER_AUDIO_NATIVE_TARGETS}
        RUNTIME DESTINATION "${destination}"
        LIBRARY DESTINATION "${destination}"
        COMPONENT Runtime)
    if(LAZER_AUDIO_ENGINE_ENABLED AND LAZER_AUDIO_NATIVE_RUNTIME_FILES)
        install(FILES ${LAZER_AUDIO_NATIVE_RUNTIME_FILES}
            DESTINATION "${destination}"
            COMPONENT Runtime)
    endif()
    if(LAZER_FFMPEG_ROOT AND
       EXISTS "${LAZER_FFMPEG_ROOT}/share/lazer-ffmpeg")
        install(DIRECTORY "${LAZER_FFMPEG_ROOT}/share/lazer-ffmpeg/"
            DESTINATION "${destination}/licenses/lazer-ffmpeg"
            COMPONENT Runtime)
    endif()
endfunction()
