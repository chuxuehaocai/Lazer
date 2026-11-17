# The full engine links the USB transport statically, so one engine DSO owns all
# audio and libusb state. Standalone JNI builds preserve their shared libusb ABI.
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
if(LAZER_ANDROID_BUILD_ENGINE)
    set(_lazer_usb_type STATIC)
else()
    set(_lazer_usb_type SHARED)
endif()
find_package(Threads REQUIRED)
add_library(usb-1.0 ${_lazer_usb_type}
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
    "${_lazer_libusb_root}/android" "${_lazer_libusb_root}/libusb" "${_lazer_libusb_root}/libusb/os")
target_compile_features(usb-1.0 PRIVATE c_std_11)
target_compile_options(usb-1.0 PRIVATE -fvisibility=hidden -pthread)
target_link_libraries(usb-1.0 PRIVATE Threads::Threads log)
set_target_properties(usb-1.0 PROPERTIES OUTPUT_NAME "usb-1.0" C_EXTENSIONS ON POSITION_INDEPENDENT_CODE ON)
if(LAZER_ANDROID_BUILD_ENGINE)
    # Record the actual archive/source locations for the LGPL relinking package,
    # including builds using FETCHCONTENT_SOURCE_DIR_LIBUSB.
    file(GENERATE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/android-usb-relink.json"
        CONTENT "{\n  \"archive\": \"$<TARGET_FILE:usb-1.0>\",\n  \"source\": \"${libusb_SOURCE_DIR}\"\n}\n")
endif()
if(NOT LAZER_ANDROID_BUILD_ENGINE)
    target_link_options(usb-1.0 PRIVATE "-Wl,-z,max-page-size=16384")
endif()
