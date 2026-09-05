cmake_minimum_required(VERSION 3.10)
project(terminal_host_linux LANGUAGES C)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")
target_link_libraries(terminal_host PRIVATE util pthread)

set(terminal_host_bundled_libraries
  $<TARGET_FILE:terminal_host>
  PARENT_SCOPE
)
