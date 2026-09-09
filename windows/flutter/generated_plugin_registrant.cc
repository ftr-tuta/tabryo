//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <fullscreen_window/fullscreen_window_plugin_c_api.h>
#include <multiview_desktop/multi_view_desktop_plugin.h>
#include <webview_win_floating/webview_win_floating_plugin_c_api.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  FullscreenWindowPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FullscreenWindowPluginCApi"));
  MultiViewDesktopPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("MultiViewDesktopPlugin"));
  WebviewWinFloatingPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("WebviewWinFloatingPluginCApi"));
}
