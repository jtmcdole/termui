import 'settings_storage.dart';

/// Platform-fallback [SettingsStorage] on non-web test platforms.
final SettingsStorage platformSettingsStorage = const _NoopSettingsStorage();

final class _NoopSettingsStorage implements SettingsStorage {
  const _NoopSettingsStorage();

  @override
  String? getItem(String key) => null;

  @override
  void setItem(String key, String value) {}
}
