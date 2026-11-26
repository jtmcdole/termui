#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>
#include <cctype>
#include <fstream>
#include <sstream>
#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

std::string ReadEnvString(const char* name) {
  DWORD required = ::GetEnvironmentVariableA(name, nullptr, 0);
  if (required == 0) {
    return {};
  }
  std::string buffer(required, '\0');
  DWORD written = ::GetEnvironmentVariableA(name, buffer.data(), required);
  if (written == 0) {
    return {};
  }
  buffer.resize(written);
  return buffer;
}

std::wstring ReadEnvWideString(const wchar_t* name) {
  DWORD required = ::GetEnvironmentVariableW(name, nullptr, 0);
  if (required == 0) {
    return {};
  }
  std::wstring buffer(required, L'\0');
  DWORD written = ::GetEnvironmentVariableW(name, buffer.data(), required);
  if (written == 0) {
    return {};
  }
  buffer.resize(written);
  return buffer;
}

std::string ToLowerAscii(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return value;
}

std::string TrimAscii(const std::string& value) {
  size_t start = 0;
  while (start < value.size() &&
         std::isspace(static_cast<unsigned char>(value[start]))) {
    ++start;
  }
  size_t end = value.size();
  while (end > start &&
         std::isspace(static_cast<unsigned char>(value[end - 1]))) {
    --end;
  }
  return value.substr(start, end - start);
}

bool ParseGpuPreferenceValue(const std::string& raw,
                             flutter::GpuPreference* out) {
  const std::string normalized = ToLowerAscii(TrimAscii(raw));
  if (normalized.empty()) {
    return false;
  }
  if (normalized == "high" || normalized == "highperformance" ||
      normalized == "high_performance" || normalized == "discrete") {
    *out = flutter::GpuPreference::HighPerformancePreference;
    return true;
  }
  if (normalized == "low" || normalized == "powersaving" ||
      normalized == "power_saving" || normalized == "integrated") {
    *out = flutter::GpuPreference::LowPowerPreference;
    return true;
  }
  if (normalized == "auto" || normalized == "default" ||
      normalized == "none" || normalized == "nopreference") {
    *out = flutter::GpuPreference::NoPreference;
    return true;
  }
  return false;
}

bool SkipAsciiWhitespace(const std::string& text, size_t* index) {
  while (*index < text.size() &&
         std::isspace(static_cast<unsigned char>(text[*index]))) {
    ++(*index);
  }
  return *index < text.size();
}

// Extracts a JSON string value for `key` where `key` is immediately followed
// by optional ASCII whitespace, `:`, optional ASCII whitespace, and a quoted
// string value (handling simple `\"` / `\\` escapes).
std::string ExtractJsonStringField(const std::string& json,
                                   const std::string& key) {
  const std::string token = "\"" + key + "\"";
  size_t search_pos = 0;
  while (search_pos < json.size()) {
    const size_t found = json.find(token, search_pos);
    if (found == std::string::npos) {
      return {};
    }
    search_pos = found + token.size();
    size_t cursor = search_pos;
    if (!SkipAsciiWhitespace(json, &cursor) || json[cursor] != ':') {
      continue;
    }
    ++cursor;
    if (!SkipAsciiWhitespace(json, &cursor) || json[cursor] != '"') {
      continue;
    }
    ++cursor;
    std::string result;
    while (cursor < json.size()) {
      const char ch = json[cursor++];
      if (ch == '\\' && cursor < json.size()) {
        result.push_back(json[cursor++]);
        continue;
      }
      if (ch == '"') {
        return result;
      }
      result.push_back(ch);
    }
    return {};
  }
  return {};
}

std::string ExtractGpuDriverPreference(const std::string& content) {
  const std::string nested =
      ExtractJsonStringField(content, "fterm.preferences.v1");
  if (!nested.empty()) {
    return ExtractJsonStringField(nested, "gpuDriverPreference");
  }
  return ExtractJsonStringField(content, "gpuDriverPreference");
}

std::wstring ResolveSettingsFilePath() {
  const std::wstring appdata = ReadEnvWideString(L"APPDATA");
  if (!appdata.empty()) {
    return appdata + L"\\fterm\\settings.json";
  }
  const std::wstring userprofile = ReadEnvWideString(L"USERPROFILE");
  if (!userprofile.empty()) {
    return userprofile + L"\\AppData\\Roaming\\fterm\\settings.json";
  }
  return {};
}

flutter::GpuPreference ResolveStartupGpuPreference() {
  flutter::GpuPreference pref = flutter::GpuPreference::NoPreference;
  const std::string env_value = ReadEnvString("FTERM_GPU_PREFERENCE");
  if (ParseGpuPreferenceValue(env_value, &pref)) {
    return pref;
  }

  const std::wstring settings_path = ResolveSettingsFilePath();
  if (settings_path.empty()) {
    return pref;
  }
  std::ifstream file(settings_path, std::ios::in | std::ios::binary);
  if (!file.is_open()) {
    return pref;
  }
  std::ostringstream buffer;
  buffer << file.rdbuf();
  const std::string stored = ExtractGpuDriverPreference(buffer.str());
  ParseGpuPreferenceValue(stored, &pref);
  return pref;
}

flutter::UIThreadPolicy ResolveStartupUiThreadPolicy() {
  const std::string env_value =
      ToLowerAscii(TrimAscii(ReadEnvString("FTERM_UI_THREAD_POLICY")));
  if (env_value == "separate") {
    return flutter::UIThreadPolicy::RunOnSeparateThread;
  }
  if (env_value == "platform") {
    return flutter::UIThreadPolicy::RunOnPlatformThread;
  }
  return flutter::UIThreadPolicy::Default;
}

std::wstring Utf16FromUtf8(const std::string& utf8_string) {
  if (utf8_string.empty()) {
    return {};
  }
  const int target_length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8_string.data(),
      static_cast<int>(utf8_string.size()), nullptr, 0);
  if (target_length <= 0) {
    return {};
  }
  std::wstring utf16_string(static_cast<size_t>(target_length), L'\0');
  const int converted = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8_string.data(),
      static_cast<int>(utf8_string.size()), utf16_string.data(), target_length);
  if (converted <= 0) {
    return {};
  }
  return utf16_string;
}

std::wstring ResolveStartupWindowTitle(
    const std::vector<std::string>& arguments) {
  constexpr const char kPrefix[] = "--window-title=";
  constexpr size_t kPrefixLen = sizeof(kPrefix) - 1;
  std::string raw_title;
  for (size_t i = 0; i < arguments.size(); ++i) {
    const std::string& arg = arguments[i];
    if (arg == "--window-title" && i + 1 < arguments.size()) {
      raw_title = arguments[++i];
    } else if (arg.size() > kPrefixLen &&
               arg.compare(0, kPrefixLen, kPrefix) == 0) {
      raw_title = arg.substr(kPrefixLen);
    }
  }
  const std::string trimmed = TrimAscii(raw_title);
  if (trimmed.empty()) {
    return L"fterm";
  }
  const std::wstring wide = Utf16FromUtf8(trimmed);
  return wide.empty() ? L"fterm" : wide;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const std::wstring window_title =
      ResolveStartupWindowTitle(command_line_arguments);

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));
  project.set_enable_flutter_gpu(true);
  project.set_gpu_preference(ResolveStartupGpuPreference());
  const flutter::UIThreadPolicy ui_policy = ResolveStartupUiThreadPolicy();
  if (ui_policy != flutter::UIThreadPolicy::Default) {
    project.set_ui_thread_policy(ui_policy);
  }

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(window_title, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
