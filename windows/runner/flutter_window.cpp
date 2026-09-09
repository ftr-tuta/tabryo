#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include <multiview_desktop/multi_view_desktop_plugin.h>

FlutterWindow::FlutterWindow(const flutter::DartProject& project, bool hidden)
    : project_(project), hidden_(hidden) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  if (!hidden_) {
    MultiViewDesktopPrepareEngine(project_, GetHandle());
    MultiViewDesktopCreateMainView(GetHandle(), frame.right - frame.left,
                                  frame.bottom - frame.top, RegisterPlugins);
    const HWND view = MultiViewDesktopGetFlutterHwnd(MultiViewDesktopGetMainViewId());
    if (!view) return false;
    SetChildContent(view);
    // Mapping before Dart's first frame also supports desktop integration tests.
    Show();
    return true;
  }

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!hidden_) this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (!hidden_) {
    LRESULT result = 0;
    if (message == WM_FONTCHANGE) {
      FlutterDesktopEngineReloadSystemFonts(MultiViewDesktopGetEngineRef());
    }
    if (MultiViewDesktopHandleWindowProc(hwnd, message, wparam, lparam, &result)) {
      return result;
    }
    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
