# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(terminal_host_library VERSION 0.1.0 LANGUAGES C)

add_library(terminal_host SHARED
  "flutter_pty.c"
)

set_target_properties(terminal_host PROPERTIES
  PUBLIC_HEADER flutter_pty.h
  OUTPUT_NAME "terminal_host"
  C_STANDARD 11
  C_STANDARD_REQUIRED YES
)

target_compile_definitions(terminal_host PUBLIC DART_SHARED_LIB)

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_link_libraries(terminal_host PRIVATE util pthread)
endif()

if (ANDROID)
  # Support Android 15 16k page size.
  target_link_options(terminal_host PRIVATE "-Wl,-z,max-page-size=16384")
endif()
