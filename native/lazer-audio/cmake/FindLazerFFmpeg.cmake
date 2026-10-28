# Android consumes the selected-ABI static SDK through its isolated pkg-config metadata. Other platforms
# retain the existing shared/import-library discovery behavior below.
if(ANDROID)
    if(NOT LAZER_FFMPEG_ROOT AND DEFINED ENV{FFMPEG_ROOT})
        set(LAZER_FFMPEG_ROOT "$ENV{FFMPEG_ROOT}")
    endif()
    if(NOT LAZER_FFMPEG_ROOT)
        message(FATAL_ERROR
            "Android requires a static DSD-capable FFmpeg SDK. Pass -DLAZER_FFMPEG_ROOT=<prefix> "
            "or set FFMPEG_ROOT to the Android ABI SDK built by build_android_dsd_ffmpeg.sh.")
    endif()

    file(TO_CMAKE_PATH "${LAZER_FFMPEG_ROOT}" _lazer_android_ffmpeg_root)
    set(_lazer_android_ffmpeg_pc_dirs
        "${_lazer_android_ffmpeg_root}/lib/pkgconfig"
        "${_lazer_android_ffmpeg_root}/lib64/pkgconfig"
        "${_lazer_android_ffmpeg_root}/lib/${CMAKE_LIBRARY_ARCHITECTURE}/pkgconfig")
    set(_lazer_android_ffmpeg_pc_dirs_existing "")
    foreach(directory IN LISTS _lazer_android_ffmpeg_pc_dirs)
        if(IS_DIRECTORY "${directory}")
            list(APPEND _lazer_android_ffmpeg_pc_dirs_existing "${directory}")
        endif()
    endforeach()
    if(NOT _lazer_android_ffmpeg_pc_dirs_existing)
        message(FATAL_ERROR
            "Android FFmpeg root '${_lazer_android_ffmpeg_root}' has no lib/pkgconfig directory.")
    endif()

    foreach(component avformat avcodec avutil swresample)
        set(_lazer_pc_found FALSE)
        foreach(directory IN LISTS _lazer_android_ffmpeg_pc_dirs_existing)
            if(EXISTS "${directory}/lib${component}.pc")
                set(_lazer_pc_found TRUE)
                break()
            endif()
        endforeach()
        if(NOT _lazer_pc_found)
            message(FATAL_ERROR
                "Android FFmpeg root '${_lazer_android_ffmpeg_root}' is missing lib${component}.pc.")
        endif()
    endforeach()

    find_package(PkgConfig REQUIRED)
    set(_lazer_saved_pkg_config_path "$ENV{PKG_CONFIG_PATH}")
    set(_lazer_saved_pkg_config_libdir "$ENV{PKG_CONFIG_LIBDIR}")
    string(JOIN ":" _lazer_android_ffmpeg_pc_path ${_lazer_android_ffmpeg_pc_dirs_existing})
    # Do not let a developer machine's host FFmpeg pkg-config modules leak into an Android build.
    set(ENV{PKG_CONFIG_PATH} "${_lazer_android_ffmpeg_pc_path}")
    set(ENV{PKG_CONFIG_LIBDIR} "${_lazer_android_ffmpeg_pc_path}")

    execute_process(
        COMMAND "${PKG_CONFIG_EXECUTABLE}" --exists
            libavformat libavcodec libavutil libswresample
        RESULT_VARIABLE _lazer_android_ffmpeg_exists_result
        ERROR_VARIABLE _lazer_android_ffmpeg_error
        OUTPUT_QUIET)
    execute_process(
        COMMAND "${PKG_CONFIG_EXECUTABLE}" --static --cflags
            libavformat libavcodec libavutil libswresample
        RESULT_VARIABLE _lazer_android_ffmpeg_cflags_result
        OUTPUT_VARIABLE _lazer_android_ffmpeg_cflags
        ERROR_VARIABLE _lazer_android_ffmpeg_cflags_error
        OUTPUT_STRIP_TRAILING_WHITESPACE)
    execute_process(
        COMMAND "${PKG_CONFIG_EXECUTABLE}" --static --libs
            libavformat libavcodec libavutil libswresample
        RESULT_VARIABLE _lazer_android_ffmpeg_libs_result
        OUTPUT_VARIABLE _lazer_android_ffmpeg_libs
        ERROR_VARIABLE _lazer_android_ffmpeg_libs_error
        OUTPUT_STRIP_TRAILING_WHITESPACE)
    execute_process(
        COMMAND "${PKG_CONFIG_EXECUTABLE}" --modversion libavformat
        RESULT_VARIABLE _lazer_android_ffmpeg_version_result
        OUTPUT_VARIABLE LAZER_FFMPEG_VERSION
        ERROR_VARIABLE _lazer_android_ffmpeg_version_error
        OUTPUT_STRIP_TRAILING_WHITESPACE)

    set(ENV{PKG_CONFIG_PATH} "${_lazer_saved_pkg_config_path}")
    set(ENV{PKG_CONFIG_LIBDIR} "${_lazer_saved_pkg_config_libdir}")

    if(NOT _lazer_android_ffmpeg_exists_result EQUAL 0 OR
       NOT _lazer_android_ffmpeg_cflags_result EQUAL 0 OR
       NOT _lazer_android_ffmpeg_libs_result EQUAL 0 OR
       NOT _lazer_android_ffmpeg_version_result EQUAL 0)
        message(FATAL_ERROR
            "Could not read the Android FFmpeg static SDK pkg-config files under "
            "${_lazer_android_ffmpeg_root}: ${_lazer_android_ffmpeg_error} "
            "${_lazer_android_ffmpeg_cflags_error} ${_lazer_android_ffmpeg_libs_error} "
            "${_lazer_android_ffmpeg_version_error}")
    endif()

    separate_arguments(_lazer_android_ffmpeg_cflags_list UNIX_COMMAND
        "${_lazer_android_ffmpeg_cflags}")
    set(LAZER_FFMPEG_INCLUDE_DIRS "${_lazer_android_ffmpeg_root}/include")
    set(_lazer_android_ffmpeg_compile_options "")
    foreach(flag IN LISTS _lazer_android_ffmpeg_cflags_list)
        if(flag MATCHES "^-I(.+)$")
            list(APPEND LAZER_FFMPEG_INCLUDE_DIRS "${CMAKE_MATCH_1}")
        else()
            list(APPEND _lazer_android_ffmpeg_compile_options "${flag}")
        endif()
    endforeach()
    list(REMOVE_DUPLICATES LAZER_FFMPEG_INCLUDE_DIRS)
    set(LAZER_FFMPEG_INCLUDE_DIR "${_lazer_android_ffmpeg_root}/include")

    separate_arguments(_lazer_android_ffmpeg_libs_list UNIX_COMMAND
        "${_lazer_android_ffmpeg_libs}")
    set(_lazer_android_ffmpeg_link_directories "")
    set(_lazer_android_ffmpeg_link_libraries "")
    set(_lazer_android_ffmpeg_link_options "")
    set(_lazer_android_ffmpeg_thread_options "")
    foreach(flag IN LISTS _lazer_android_ffmpeg_libs_list)
        if(flag MATCHES "^-L(.+)$")
            list(APPEND _lazer_android_ffmpeg_link_directories "${CMAKE_MATCH_1}")
        elseif(flag MATCHES "^-l(.+)$")
            list(APPEND _lazer_android_ffmpeg_link_libraries "${CMAKE_MATCH_1}")
        elseif(flag STREQUAL "-pthread")
            list(APPEND _lazer_android_ffmpeg_thread_options "-pthread")
        elseif(flag MATCHES "^-Wl," OR flag MATCHES "^-fuse-ld=" OR
               flag MATCHES "^-static" OR flag MATCHES "^-shared")
            list(APPEND _lazer_android_ffmpeg_link_options "${flag}")
        elseif(IS_ABSOLUTE "${flag}")
            list(APPEND _lazer_android_ffmpeg_link_libraries "${flag}")
        else()
            message(FATAL_ERROR
                "Unsupported Android FFmpeg pkg-config linker flag '${flag}'. "
                "Update FindLazerFFmpeg.cmake to preserve its meaning.")
        endif()
    endforeach()

    foreach(component avformat avcodec avutil swresample)
        set(_lazer_android_static_archive_found FALSE)
        foreach(directory IN LISTS _lazer_android_ffmpeg_link_directories)
            if(EXISTS "${directory}/lib${component}.a")
                set(_lazer_android_static_archive_found TRUE)
            endif()
            file(GLOB _lazer_android_component_shared
                "${directory}/lib${component}.so*")
            if(_lazer_android_component_shared)
                message(FATAL_ERROR
                    "Android FFmpeg root must be static; found shared lib${component} in ${directory}.")
            endif()
        endforeach()
        if(NOT _lazer_android_static_archive_found)
            message(FATAL_ERROR
                "Android FFmpeg pkg-config did not resolve static lib${component}.a.")
        endif()
    endforeach()

    # pkg-config --static expands Libs.private in dependency order, including system libraries.
    # Preserve that order for GNU/LLVM's one-pass static archive linker.
    add_library(LazerFFmpeg::Static INTERFACE IMPORTED GLOBAL)
    set_property(TARGET LazerFFmpeg::Static PROPERTY
        INTERFACE_INCLUDE_DIRECTORIES "${LAZER_FFMPEG_INCLUDE_DIRS}")
    set_property(TARGET LazerFFmpeg::Static PROPERTY
        INTERFACE_COMPILE_OPTIONS "${_lazer_android_ffmpeg_compile_options}")
    set_property(TARGET LazerFFmpeg::Static PROPERTY
        INTERFACE_LINK_DIRECTORIES "${_lazer_android_ffmpeg_link_directories}")
    set_property(TARGET LazerFFmpeg::Static PROPERTY
        INTERFACE_LINK_LIBRARIES "${_lazer_android_ffmpeg_link_libraries}")
    set_property(TARGET LazerFFmpeg::Static PROPERTY
        INTERFACE_LINK_OPTIONS "${_lazer_android_ffmpeg_link_options};${_lazer_android_ffmpeg_thread_options}")
    set(LAZER_FFMPEG_LIBRARIES LazerFFmpeg::Static)
    set(LAZER_FFMPEG_RUNTIME_FILES "")
    set(LazerFFmpeg_FOUND TRUE)
    message(STATUS
        "Lazer Android FFmpeg static SDK: ${_lazer_android_ffmpeg_root} (${LAZER_FFMPEG_VERSION})")
elseif(WIN32)
    include(FindPackageHandleStandardArgs)

    find_path(LAZER_FFMPEG_INCLUDE_DIR
        NAMES libavformat/avformat.h libavcodec/avcodec.h libavutil/version.h libswresample/swresample.h
        PATHS "${LAZER_FFMPEG_ROOT}/include" ENV FFMPEG_ROOT)

    set(_lazer_ffmpeg_components avformat avcodec avutil swresample)
    set(_lazer_ffmpeg_libraries "")
    set(LAZER_FFMPEG_RUNTIME_FILES "")

    foreach(component IN LISTS _lazer_ffmpeg_components)
        file(GLOB candidates
            "${LAZER_FFMPEG_ROOT}/lib/${component}-[0-9]*.lib"
            "${LAZER_FFMPEG_ROOT}/lib/${component}.lib"
            "$ENV{FFMPEG_ROOT}/lib/${component}-[0-9]*.lib"
            "$ENV{FFMPEG_ROOT}/lib/${component}.lib")
        if(NOT candidates)
            message(FATAL_ERROR "FFmpeg import library '${component}' was not found under ${LAZER_FFMPEG_ROOT}/lib")
        endif()
        list(SORT candidates COMPARE NATURAL ORDER DESCENDING)
        list(GET candidates 0 chosen)
        list(APPEND _lazer_ffmpeg_libraries "${chosen}")
        get_filename_component(chosen_name "${chosen}" NAME_WE)
        file(GLOB chosen_dll
            "${LAZER_FFMPEG_ROOT}/bin/${chosen_name}-*.dll"
            "$ENV{FFMPEG_ROOT}/bin/${chosen_name}-*.dll")
        if(chosen_dll)
            list(APPEND LAZER_FFMPEG_RUNTIME_FILES ${chosen_dll})
        endif()
        message(STATUS "Lazer FFmpeg ${component}: ${chosen}")
    endforeach()

    find_package_handle_standard_args(LazerFFmpeg
        REQUIRED_VARS LAZER_FFMPEG_INCLUDE_DIR _lazer_ffmpeg_libraries)

    if(LazerFFmpeg_FOUND)
        set(LAZER_FFMPEG_LIBRARIES ${_lazer_ffmpeg_libraries})
        set(LAZER_FFMPEG_INCLUDE_DIRS ${LAZER_FFMPEG_INCLUDE_DIR})
    endif()
else()
    find_package(PkgConfig REQUIRED)

    # On Unix hosts, a caller may point at a custom shared FFmpeg development package. Search its
    # pkg-config metadata before the system paths so the headers, linker flags and runtime copy
    # all come from the same package. With no custom root, use the distribution's pkg-config data.
    set(_lazer_ffmpeg_root "${LAZER_FFMPEG_ROOT}")
    if(NOT _lazer_ffmpeg_root AND DEFINED ENV{FFMPEG_ROOT})
        set(_lazer_ffmpeg_root "$ENV{FFMPEG_ROOT}")
    endif()
    if(_lazer_ffmpeg_root)
        file(TO_CMAKE_PATH "${_lazer_ffmpeg_root}" _lazer_ffmpeg_root)
        set(_lazer_ffmpeg_pkgconfig_dirs
            "${_lazer_ffmpeg_root}/lib/pkgconfig"
            "${_lazer_ffmpeg_root}/lib64/pkgconfig"
            "${_lazer_ffmpeg_root}/lib/${CMAKE_LIBRARY_ARCHITECTURE}/pkgconfig")
        set(_lazer_ffmpeg_pkgconfig_dirs_existing "")
        foreach(directory IN LISTS _lazer_ffmpeg_pkgconfig_dirs)
            if(IS_DIRECTORY "${directory}")
                list(APPEND _lazer_ffmpeg_pkgconfig_dirs_existing "${directory}")
            endif()
        endforeach()
        if(NOT _lazer_ffmpeg_pkgconfig_dirs_existing)
            message(FATAL_ERROR
                "FFmpeg root '${_lazer_ffmpeg_root}' has no lib/pkgconfig, lib64/pkgconfig, or architecture-specific pkgconfig directory")
        endif()
        foreach(component avformat avcodec avutil swresample)
            set(_lazer_pc_found FALSE)
            foreach(directory IN LISTS _lazer_ffmpeg_pkgconfig_dirs_existing)
                if(EXISTS "${directory}/lib${component}.pc")
                    set(_lazer_pc_found TRUE)
                    break()
                endif()
            endforeach()
            if(NOT _lazer_pc_found)
                message(FATAL_ERROR
                    "FFmpeg root '${_lazer_ffmpeg_root}' is missing pkg-config module lib${component}.pc")
            endif()
        endforeach()

        set(_lazer_saved_pkg_config_path "$ENV{PKG_CONFIG_PATH}")
        string(JOIN ":" _lazer_ffmpeg_pkgconfig_path ${_lazer_ffmpeg_pkgconfig_dirs_existing})
        if(_lazer_saved_pkg_config_path)
            set(ENV{PKG_CONFIG_PATH} "${_lazer_ffmpeg_pkgconfig_path}:${_lazer_saved_pkg_config_path}")
        else()
            set(ENV{PKG_CONFIG_PATH} "${_lazer_ffmpeg_pkgconfig_path}")
        endif()
    endif()

    pkg_check_modules(LAZER_FFMPEG REQUIRED IMPORTED_TARGET
        libavformat libavcodec libavutil libswresample)
    if(_lazer_ffmpeg_root)
        set(ENV{PKG_CONFIG_PATH} "${_lazer_saved_pkg_config_path}")
    endif()
    set(LAZER_FFMPEG_INCLUDE_DIR ${LAZER_FFMPEG_INCLUDE_DIRS})
    set(LAZER_FFMPEG_LIBRARIES PkgConfig::LAZER_FFMPEG)

    foreach(component avformat avcodec avutil swresample)
        foreach(directory IN LISTS LAZER_FFMPEG_LIBRARY_DIRS)
            file(GLOB runtime_files
                "${directory}/lib${component}.so*"
                "${directory}/lib${component}*.dylib")
            list(APPEND LAZER_FFMPEG_RUNTIME_FILES ${runtime_files})
        endforeach()
    endforeach()
    list(REMOVE_DUPLICATES LAZER_FFMPEG_RUNTIME_FILES)
    set(LazerFFmpeg_FOUND TRUE)
    if(_lazer_ffmpeg_root)
        message(STATUS "Lazer FFmpeg via pkg-config under ${_lazer_ffmpeg_root}: ${LAZER_FFMPEG_VERSION}")
    else()
        message(STATUS "Lazer FFmpeg via system pkg-config: ${LAZER_FFMPEG_VERSION}")
    endif()
endif()
