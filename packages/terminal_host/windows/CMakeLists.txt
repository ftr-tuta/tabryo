cmake_minimum_required(VERSION 3.14)
project(terminal_host_windows LANGUAGES C)

include(FetchContent)
if(POLICY CMP0135)
  cmake_policy(SET CMP0135 NEW)
endif()
FetchContent_Declare(tabryo_conpty
  URL "https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty/1.24.260710001/microsoft.windows.console.conpty.1.24.260710001.nupkg"
  DOWNLOAD_NAME conpty.zip
  URL_HASH SHA256=175640566a3b59c4b132070ee96c2c77e5ab7edd2e92732a5eb3610bbf63d90e
)
FetchContent_MakeAvailable(tabryo_conpty)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

set(terminal_host_bundled_libraries
  $<TARGET_FILE:terminal_host>
  "${tabryo_conpty_SOURCE_DIR}/runtimes/win-x64/native/conpty.dll"
  "${tabryo_conpty_SOURCE_DIR}/build/native/runtimes/x64/OpenConsole.exe"
  PARENT_SCOPE
)
