#include "flutter_window.h"

#include <dxgi.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

const char* GpuPreferenceName(flutter::GpuPreference preference) {
  switch (preference) {
    case flutter::GpuPreference::HighPerformancePreference:
      return "highPerformance";
    case flutter::GpuPreference::LowPowerPreference:
      return "powerSaving";
    case flutter::GpuPreference::NoPreference:
      return "auto";
  }
  return "auto";
}

flutter::EncodableMap QueryGraphicsAdapterInfo(
    flutter::FlutterEngine* engine, flutter::GpuPreference gpu_preference) {
  flutter::EncodableMap info;
  info[flutter::EncodableValue("gpuPreference")] =
      flutter::EncodableValue(GpuPreferenceName(gpu_preference));
  if (!engine) {
    return info;
  }
  IDXGIAdapter* adapter = nullptr;
  if (!engine->GetGraphicsAdapter(&adapter) || adapter == nullptr) {
    return info;
  }
  DXGI_ADAPTER_DESC desc = {};
  const HRESULT hr = adapter->GetDesc(&desc);
  adapter->Release();
  if (SUCCEEDED(hr)) {
    info[flutter::EncodableValue("description")] =
        flutter::EncodableValue(Utf8FromUtf16(desc.Description));
    info[flutter::EncodableValue("vendorId")] =
        flutter::EncodableValue(static_cast<int32_t>(desc.VendorId));
    info[flutter::EncodableValue("dedicatedVideoMemoryMB")] =
        flutter::EncodableValue(
            static_cast<int32_t>(desc.DedicatedVideoMemory / (1024ULL * 1024ULL)));
  }
  return info;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "fterm/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "getGraphicsAdapterInfo") {
          auto* engine =
              flutter_controller_ ? flutter_controller_->engine() : nullptr;
          result->Success(flutter::EncodableValue(
              QueryGraphicsAdapterInfo(engine, project_.gpu_preference())));
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
    case WM_ENTERSIZEMOVE:
      if (window_channel_) {
        window_channel_->InvokeMethod(
            "windowSizeMoveChanged",
            std::make_unique<flutter::EncodableValue>(true));
      }
      break;
    case WM_EXITSIZEMOVE:
      if (window_channel_) {
        window_channel_->InvokeMethod(
            "windowSizeMoveChanged",
            std::make_unique<flutter::EncodableValue>(false));
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
