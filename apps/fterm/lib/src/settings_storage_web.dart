import 'package:web/web.dart' as web;

import 'settings_storage.dart';

/// Platform `window.localStorage`-backed [SettingsStorage].
final SettingsStorage platformSettingsStorage = const _WebSettingsStorage();

final class _WebSettingsStorage implements SettingsStorage {
  const _WebSettingsStorage();

  @override
  String? getItem(String key) {
    if (key == ftermRelayCredentialsStorageKey) {
      try {
        web.window.localStorage.removeItem(key);
      } on Object {
        // Ignore SecurityError / restricted browsing mode errors.
      }
      return null;
    }
    try {
      return web.window.localStorage.getItem(key);
    } on Object {
      return null;
    }
  }

  @override
  void setItem(String key, String value) {
    if (key == ftermRelayCredentialsStorageKey) {
      return;
    }
    try {
      web.window.localStorage.setItem(key, value);
    } on Object {
      // Ignore SecurityError / QuotaExceededError in restricted browsing modes.
    }
  }
}
