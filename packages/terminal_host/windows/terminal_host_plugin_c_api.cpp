#include "include/terminal_host/terminal_host_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "terminal_host_plugin.h"

void TerminalHostPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  terminal_host::TerminalHostPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
