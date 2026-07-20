cmake_minimum_required(VERSION 3.10)
project(termui_audio VERSION 0.1.0 LANGUAGES CXX C)

set(PLUGIN_NAME "soloud_cli")
set(SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/src")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(${SRC_DIR}/CMakeLists.txt)

add_library(${PLUGIN_NAME} SHARED ${PLUGIN_SOURCES})

add_compile_definitions(WITH_MINIAUDIO MA_NO_PULSEAUDIO NOMINMAX)

target_include_directories(${PLUGIN_NAME} PRIVATE
    "${SRC_DIR}"
    "${SRC_DIR}/soloud/include"
    "${SRC_DIR}/soloud/src"
    "${SRC_DIR}/pffft"
)

if(WIN32)
    # Define directories for precompiled headers and libraries
    set(LIBS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/windows/libs")
    set(INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/windows/include")

    target_include_directories(${PLUGIN_NAME} PRIVATE "${INCLUDE_DIR}")

    target_link_libraries(${PLUGIN_NAME} PRIVATE
        "${LIBS_DIR}/ogg.lib"
        "${LIBS_DIR}/opus.lib"
        "${LIBS_DIR}/vorbis.lib"
        "${LIBS_DIR}/vorbisfile.lib"
        "${LIBS_DIR}/FLAC.lib"
        ${LINK_LIBRARIES}
    )

    # Post-build copies of DLLs next to the soloud_cli.dll target
    set(DLL_FILES
        "ogg.dll"
        "opus.dll"
        "vorbis.dll"
        "vorbisfile.dll"
        "FLAC.dll"
    )

    foreach(DLL_NAME ${DLL_FILES})
        add_custom_command(TARGET ${PLUGIN_NAME} POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${LIBS_DIR}/${DLL_NAME}"
            "$<TARGET_FILE_DIR:${PLUGIN_NAME}>/${DLL_NAME}"
        )
    endforeach()

    set_target_properties(${PLUGIN_NAME} PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
else()
    # On other platforms, link normally to system/dynamic libraries
    target_link_libraries(${PLUGIN_NAME} PRIVATE ogg opus vorbis vorbisfile FLAC ${LINK_LIBRARIES})
endif()
