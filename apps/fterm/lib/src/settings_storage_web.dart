import 'package:web/web.dart' as web;

import 'settings_storage.dart';

/// Platform Web [SettingsStorage] routing preferences to `window.localStorage`
/// and tab-scoped relay credentials / Web layout resume to `window.sessionStorage`.
final SettingsStorage platformSettingsStorage = const _WebSettingsStorage();

final class _WebSettingsStorage implements SettingsStorage {
  const _WebSettingsStorage();

  static bool _isSessionScopedKey(String key) =>
      key == ftermRelayCredentialsStorageKey ||
      key == ftermWebWorkspaceResumeStorageKey;

  void _purgeLocalStorageKey(String key) {
    try {
      web.window.localStorage.removeItem(key);
    } on Object {
      // Ignore SecurityError / restricted browsing mode errors.
    }
  }

  @override
  String? getItem(String key) {
    if (key == ftermAutomationConfigStorageKey) return null;
    if (_isSessionScopedKey(key)) {
      if (key == ftermRelayCredentialsStorageKey) {
        _purgeLocalStorageKey(key);
      }
      try {
        return web.window.sessionStorage.getItem(key);
      } on Object {
        return null;
      }
    }
    try {
      return web.window.localStorage.getItem(key);
    } on Object {
      return null;
    }
  }

  @override
  void setItem(String key, String value) {
    if (key == ftermAutomationConfigStorageKey) return;
    if (_isSessionScopedKey(key)) {
      if (key == ftermRelayCredentialsStorageKey) {
        _purgeLocalStorageKey(key);
      }
      try {
        web.window.sessionStorage.setItem(key, value);
      } on Object {
        // Ignore SecurityError / QuotaExceededError in restricted browsing modes.
      }
      return;
    }
    try {
      web.window.localStorage.setItem(key, value);
    } on Object {
      // Ignore SecurityError / QuotaExceededError in restricted browsing modes.
    }
  }
}
