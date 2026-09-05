cmake_minimum_required(VERSION 3.14)
project(terminal_host_windows LANGUAGES C)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

set(terminal_host_bundled_libraries
  $<TARGET_FILE:terminal_host>
  PARENT_SCOPE
)
