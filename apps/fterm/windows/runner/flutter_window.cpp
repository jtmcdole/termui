#include "flutter_window.h"

#include <dwmapi.h>
#include <dxgi.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

// Fallback constants for Windows SDKs older than 10.0.22000.0 (Windows 11).
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWCP_DEFAULT
#define DWMWCP_DEFAULT 0
#endif
#ifndef DWMWCP_DONOTROUND
#define DWMWCP_DONOTROUND 1
#endif

struct DwmFrameDeltas {
  LONG left;
  LONG top;
  LONG right;
  LONG bottom;
};

struct BoundsMutation {
  std::optional<double> x;
  std::optional<double> y;
  std::optional<double> width;
  std::optional<double> height;
  bool is_logical = false;
  std::optional<bool> square_corners;
  std::optional<bool> always_on_top;
  bool focus = false;

  bool has_move() const { return x.has_value() || y.has_value(); }
  bool has_size() const { return width.has_value() || height.has_value(); }
};

std::optional<double> TryGetDouble(const flutter::EncodableMap& map,
                                   const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return std::nullopt;
  }
  if (const auto* value = std::get_if<double>(&it->second)) {
    return std::isfinite(*value) ? std::optional<double>(*value)
                                 : std::nullopt;
  }
  if (const auto* value = std::get_if<int32_t>(&it->second)) {
    return static_cast<double>(*value);
  }
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return static_cast<double>(*value);
  }
  return std::nullopt;
}

std::optional<bool> TryGetBool(const flutter::EncodableMap& map,
                               const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return std::nullopt;
  }
  if (const auto* value = std::get_if<bool>(&it->second)) {
    return *value;
  }
  return std::nullopt;
}

std::optional<std::string> TryGetString(const flutter::EncodableMap& map,
                                        const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return std::nullopt;
  }
  if (const auto* value = std::get_if<std::string>(&it->second)) {
    return *value;
  }
  return std::nullopt;
}

BoundsMutation ParseBoundsMutation(const flutter::EncodableMap& args) {
  BoundsMutation mutation;
  mutation.x = TryGetDouble(args, "x");
  mutation.y = TryGetDouble(args, "y");
  const auto raw_width = TryGetDouble(args, "width");
  if (raw_width.has_value() && *raw_width > 0.0) {
    mutation.width = raw_width;
  }
  const auto raw_height = TryGetDouble(args, "height");
  if (raw_height.has_value() && *raw_height > 0.0) {
    mutation.height = raw_height;
  }
  const auto units = TryGetString(args, "units");
  mutation.is_logical = units.has_value() && *units == "logical";
  mutation.square_corners = TryGetBool(args, "squareCorners");
  mutation.always_on_top = TryGetBool(args, "alwaysOnTop");
  mutation.focus = TryGetBool(args, "focus").value_or(false);
  return mutation;
}

UINT QueryWindowDpi(HWND hwnd) {
  UINT dpi = GetDpiForWindow(hwnd);
  if (dpi == 0) {
    dpi = FlutterDesktopGetDpiForHWND(hwnd);
  }
  return dpi == 0 ? 96u : dpi;
}

RECT QueryExtendedFrameRect(HWND hwnd, const RECT& window_rect) {
  RECT extended_rect = window_rect;
  if (FAILED(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS,
                                   &extended_rect, sizeof(extended_rect)))) {
    return window_rect;
  }
  return extended_rect;
}

DwmFrameDeltas ComputeFrameDeltas(const RECT& window_rect,
                                  const RECT& extended_rect) {
  return DwmFrameDeltas{
      extended_rect.left - window_rect.left,
      extended_rect.top - window_rect.top,
      window_rect.right - extended_rect.right,
      window_rect.bottom - extended_rect.bottom,
  };
}

bool QuerySquareCorners(HWND hwnd) {
  DWORD preference = DWMWCP_DEFAULT;
  const HRESULT hr = DwmGetWindowAttribute(
      hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &preference, sizeof(preference));
  if (FAILED(hr)) {
    return false;
  }
  return preference == DWMWCP_DONOTROUND;
}

flutter::EncodableMap MakeRectMap(double x, double y, double width,
                                  double height) {
  return flutter::EncodableMap{
      {flutter::EncodableValue("x"), flutter::EncodableValue(x)},
      {flutter::EncodableValue("y"), flutter::EncodableValue(y)},
      {flutter::EncodableValue("width"), flutter::EncodableValue(width)},
      {flutter::EncodableValue("height"), flutter::EncodableValue(height)},
  };
}

flutter::EncodableMap MakeUnsupportedBounds() {
  return flutter::EncodableMap{
      {flutter::EncodableValue("supported"), flutter::EncodableValue(false)},
  };
}

flutter::EncodableMap QueryWindowBounds(HWND hwnd) {
  if (hwnd == nullptr) {
    return MakeUnsupportedBounds();
  }
  RECT window_rect{};
  if (!GetWindowRect(hwnd, &window_rect)) {
    return MakeUnsupportedBounds();
  }
  const RECT extended_rect = QueryExtendedFrameRect(hwnd, window_rect);
  const double dpr = static_cast<double>(QueryWindowDpi(hwnd)) / 96.0;
  const double phys_x = static_cast<double>(extended_rect.left);
  const double phys_y = static_cast<double>(extended_rect.top);
  const double phys_w =
      static_cast<double>(std::max<LONG>(0, extended_rect.right - extended_rect.left));
  const double phys_h =
      static_cast<double>(std::max<LONG>(0, extended_rect.bottom - extended_rect.top));
  const bool always_on_top =
      (GetWindowLongPtr(hwnd, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;

  return flutter::EncodableMap{
      {flutter::EncodableValue("supported"), flutter::EncodableValue(true)},
      {flutter::EncodableValue("physical"),
       flutter::EncodableValue(MakeRectMap(phys_x, phys_y, phys_w, phys_h))},
      {flutter::EncodableValue("logical"),
       flutter::EncodableValue(MakeRectMap(phys_x / dpr, phys_y / dpr,
                                           phys_w / dpr, phys_h / dpr))},
      {flutter::EncodableValue("dpr"), flutter::EncodableValue(dpr)},
      {flutter::EncodableValue("alwaysOnTop"),
       flutter::EncodableValue(always_on_top)},
      {flutter::EncodableValue("squareCorners"),
       flutter::EncodableValue(QuerySquareCorners(hwnd))},
  };
}

double ResolveTargetDpr(const BoundsMutation& mutation,
                        const RECT& extended_rect, double current_dpr) {
  if (!mutation.is_logical) {
    return current_dpr;
  }
  const POINT probe = {
      mutation.x.has_value()
          ? static_cast<LONG>(std::llround(*mutation.x * current_dpr))
          : extended_rect.left,
      mutation.y.has_value()
          ? static_cast<LONG>(std::llround(*mutation.y * current_dpr))
          : extended_rect.top,
  };
  HMONITOR monitor = MonitorFromPoint(probe, MONITOR_DEFAULTTONEAREST);
  if (monitor == nullptr) {
    return current_dpr;
  }
  const UINT monitor_dpi = FlutterDesktopGetDpiForMonitor(monitor);
  return monitor_dpi != 0 ? static_cast<double>(monitor_dpi) / 96.0
                          : current_dpr;
}

RECT ResolveTargetPhysicalRect(const BoundsMutation& mutation,
                               const RECT& base_extended_rect, double scale) {
  const LONG target_x = mutation.x.has_value()
                            ? static_cast<LONG>(std::llround(*mutation.x * scale))
                            : base_extended_rect.left;
  const LONG target_y = mutation.y.has_value()
                            ? static_cast<LONG>(std::llround(*mutation.y * scale))
                            : base_extended_rect.top;
  const LONG base_w =
      std::max<LONG>(0, base_extended_rect.right - base_extended_rect.left);
  const LONG base_h =
      std::max<LONG>(0, base_extended_rect.bottom - base_extended_rect.top);
  const LONG target_w =
      mutation.width.has_value()
          ? std::max<LONG>(1, static_cast<LONG>(std::llround(*mutation.width * scale)))
          : base_w;
  const LONG target_h =
      mutation.height.has_value()
          ? std::max<LONG>(1, static_cast<LONG>(std::llround(*mutation.height * scale)))
          : base_h;
  return RECT{target_x, target_y, target_x + target_w, target_y + target_h};
}

void IssueSetWindowPos(HWND hwnd, const BoundsMutation& mutation,
                       const RECT& target_ext, const DwmFrameDeltas& deltas,
                       bool allow_zorder) {
  UINT flags = 0;
  if (!mutation.has_move()) {
    flags |= SWP_NOMOVE;
  }
  if (!mutation.has_size()) {
    flags |= SWP_NOSIZE;
  }
  HWND insert_after = nullptr;
  if (allow_zorder && mutation.always_on_top.has_value()) {
    insert_after = *mutation.always_on_top ? HWND_TOPMOST : HWND_NOTOPMOST;
  } else {
    flags |= SWP_NOZORDER;
  }
  if (!mutation.focus) {
    flags |= SWP_NOACTIVATE;
  }

  const int win_x = static_cast<int>(target_ext.left - deltas.left);
  const int win_y = static_cast<int>(target_ext.top - deltas.top);
  const int win_w = static_cast<int>(
      (target_ext.right - target_ext.left) + deltas.left + deltas.right);
  const int win_h = static_cast<int>(
      (target_ext.bottom - target_ext.top) + deltas.top + deltas.bottom);

  SetWindowPos(hwnd, insert_after, win_x, win_y, win_w, win_h, flags);
}

bool NeedsCorrectivePos(const BoundsMutation& mutation, const RECT& actual_ext,
                        const RECT& target_ext, UINT initial_dpi,
                        UINT post_dpi) {
  if (post_dpi != initial_dpi) {
    return true;
  }
  if (mutation.x.has_value() && actual_ext.left != target_ext.left) {
    return true;
  }
  if (mutation.y.has_value() && actual_ext.top != target_ext.top) {
    return true;
  }
  const LONG actual_w = actual_ext.right - actual_ext.left;
  const LONG target_w = target_ext.right - target_ext.left;
  if (mutation.width.has_value() && actual_w != target_w) {
    return true;
  }
  const LONG actual_h = actual_ext.bottom - actual_ext.top;
  const LONG target_h = target_ext.bottom - target_ext.top;
  return mutation.height.has_value() && actual_h != target_h;
}

void ApplyCorrectiveWindowPosIfNeeded(HWND hwnd, const BoundsMutation& mutation,
                                      const RECT& initial_ext,
                                      UINT initial_dpi) {
  RECT post_window_rect{};
  if (!GetWindowRect(hwnd, &post_window_rect)) {
    return;
  }
  const RECT post_ext = QueryExtendedFrameRect(hwnd, post_window_rect);
  const UINT post_dpi = QueryWindowDpi(hwnd);
  const double post_scale =
      mutation.is_logical ? (static_cast<double>(post_dpi) / 96.0) : 1.0;
  const RECT final_target_ext =
      ResolveTargetPhysicalRect(mutation, initial_ext, post_scale);
  if (!NeedsCorrectivePos(mutation, post_ext, final_target_ext, initial_dpi,
                          post_dpi)) {
    return;
  }
  const DwmFrameDeltas post_deltas =
      ComputeFrameDeltas(post_window_rect, post_ext);
  IssueSetWindowPos(hwnd, mutation, final_target_ext, post_deltas,
                    /*allow_zorder=*/false);
}

flutter::EncodableMap ApplyWindowBounds(HWND hwnd,
                                        const flutter::EncodableMap& args) {
  if (hwnd == nullptr) {
    return MakeUnsupportedBounds();
  }
  const BoundsMutation mutation = ParseBoundsMutation(args);
  if (!IsWindowVisible(hwnd)) {
    ShowWindow(hwnd, mutation.focus ? SW_SHOWNORMAL : SW_SHOWNOACTIVATE);
  }
  if ((mutation.has_move() || mutation.has_size()) &&
      (IsIconic(hwnd) || IsZoomed(hwnd))) {
    ShowWindow(hwnd, mutation.focus ? SW_RESTORE : SW_SHOWNOACTIVATE);
  } else if (mutation.focus && IsIconic(hwnd)) {
    ShowWindow(hwnd, SW_RESTORE);
  }

  if (mutation.square_corners.has_value()) {
    DWORD preference =
        *mutation.square_corners ? DWMWCP_DONOTROUND : DWMWCP_DEFAULT;
    DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &preference,
                          sizeof(preference));
  }

  RECT window_rect{};
  if (!GetWindowRect(hwnd, &window_rect)) {
    return MakeUnsupportedBounds();
  }
  const RECT initial_ext = QueryExtendedFrameRect(hwnd, window_rect);
  const UINT initial_dpi = QueryWindowDpi(hwnd);
  const double initial_dpr = static_cast<double>(initial_dpi) / 96.0;

  if (mutation.has_move() || mutation.has_size() ||
      mutation.always_on_top.has_value()) {
    const double target_dpr =
        ResolveTargetDpr(mutation, initial_ext, initial_dpr);
    const double scale = mutation.is_logical ? target_dpr : 1.0;
    const RECT target_ext =
        ResolveTargetPhysicalRect(mutation, initial_ext, scale);
    const DwmFrameDeltas deltas = ComputeFrameDeltas(window_rect, initial_ext);
    IssueSetWindowPos(hwnd, mutation, target_ext, deltas,
                      /*allow_zorder=*/true);

    if (mutation.has_move() || mutation.has_size()) {
      ApplyCorrectiveWindowPosIfNeeded(hwnd, mutation, initial_ext,
                                       initial_dpi);
    }
  }

  if (mutation.focus) {
    BringWindowToTop(hwnd);
    SetForegroundWindow(hwnd);
  }

  return QueryWindowBounds(hwnd);
}

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
        if (call.method_name() == "getBounds") {
          result->Success(
              flutter::EncodableValue(QueryWindowBounds(GetHandle())));
          return;
        }
        if (call.method_name() == "setBounds") {
          const auto* args = call.arguments() != nullptr
                                 ? std::get_if<flutter::EncodableMap>(
                                       call.arguments())
                                 : nullptr;
          if (args == nullptr) {
            result->Error("INVALID_ARGUMENTS",
                          "setBounds expects a map of window bounds options.");
            return;
          }
          result->Success(
              flutter::EncodableValue(ApplyWindowBounds(GetHandle(), *args)));
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
