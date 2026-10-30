if(LAZER_AUDIO_CONFIG STREQUAL "Release" OR
   LAZER_AUDIO_CONFIG STREQUAL "MinSizeRel")
    return()
endif()

set(runtime "${LAZER_AUDIO_REPO}/build/native-audio")
file(MAKE_DIRECTORY "${runtime}")
file(COPY_FILE "${LAZER_AUDIO_ENGINE}" "${LAZER_AUDIO_REPO}/lazer-audio.dll"
    ONLY_IF_DIFFERENT)
file(COPY_FILE "${LAZER_AUDIO_ENGINE}" "${runtime}/lazer-audio.dll"
    ONLY_IF_DIFFERENT)
file(COPY_FILE "${LAZER_AUDIO_BRIDGE}" "${runtime}/lazer-audio-bridge.dll"
    ONLY_IF_DIFFERENT)
file(GLOB dependencies "${LAZER_AUDIO_FFMPEG}/bin/*.dll")
foreach(dependency IN LISTS dependencies)
    get_filename_component(name "${dependency}" NAME)
    file(COPY_FILE "${dependency}" "${runtime}/${name}" ONLY_IF_DIFFERENT)
endforeach()
