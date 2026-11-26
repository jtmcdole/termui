import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show ChangeNotifier;

import '../settings_storage.dart';
import 'automation_http_server.dart';
import 'automation_models.dart';

/// Lifecycle and persistence controller for the loopback HTTP automation
/// driver.
///
/// Remains completely inert on unsupported targets (Web) without reading,
/// generating, or writing [ftermAutomationConfigStorageKey]. On desktop,
/// persists only `port` and generated `password`; `isRunning` and `allowPty`
/// always start `false` unless explicitly activated via [setEnabled] or
/// [applyStartupFlags].
final class AutomationDriverController extends ChangeNotifier
    implements AutomationDriverViewModel {
  final AutomationRequestHandler _onRequest;
  final SettingsStorage _storage;
  final AutomationHttpServerBackend _backend;
  final Random? _random;

  AutomationDriverConfig _persistedConfig = AutomationDriverConfig();
  int? _startupPortOverride;
  String? _ephemeralTokenOverride;
  bool _allowPty = false;
  String? _lastError;
  bool _disposed = false;

  /// Creates an [AutomationDriverController] backed by [backend] and [storage].
  AutomationDriverController({
    required this._onRequest,
    SettingsStorage? storage,
    AutomationHttpServerBackend? backend,
    this._random,
  }) : _storage = storage ?? defaultSettingsStorage,
       _backend = backend ?? createAutomationHttpServerBackend() {
    _loadInitialConfig();
  }

  @override
  bool get isSupported => _backend.isSupported;

  @override
  bool get isRunning => _backend.isRunning;

  @override
  int get port => _startupPortOverride ?? _persistedConfig.port;

  /// Active bound loopback TCP port while running, or `null` when stopped.
  int? get boundPort => _backend.boundPort;

  @override
  String get password => _ephemeralTokenOverride ?? _persistedConfig.password;

  @override
  bool get allowPty => _allowPty;

  @override
  bool get hasEphemeralTokenOverride => _ephemeralTokenOverride != null;

  @override
  String? get lastError => _lastError;

  /// Applies CLI and environment startup overrides without modifying persisted
  /// desktop settings.
  ///
  /// Throws [RangeError] if [portOverride] is provided outside `1..65535`.
  /// Returns `true` when the server is listening after applying the flags.
  Future<bool> applyStartupFlags({
    bool enabled = false,
    bool allowPty = false,
    int? portOverride,
    String? tokenOverride,
  }) async {
    if (!_backend.isSupported || _disposed) return false;
    if (portOverride != null &&
        !AutomationDriverConfig.isValidPort(portOverride)) {
      throw RangeError.range(
        portOverride,
        AutomationDriverConfig.minPort,
        AutomationDriverConfig.maxPort,
        'portOverride',
      );
    }

    var changed = _applyOverrides(
      allowPty: allowPty,
      portOverride: portOverride,
      tokenOverride: tokenOverride,
    );
    if (changed) {
      _safeNotifyListeners();
    }
    if (enabled) {
      return setEnabled(true);
    }
    return _backend.isRunning;
  }

  @override
  Future<bool> setEnabled(bool enabled) async {
    if (!_backend.isSupported || _disposed) return false;
    if (!enabled) {
      return _stopServer();
    }
    if (_backend.isRunning) {
      if (_lastError != null) {
        _lastError = null;
        _safeNotifyListeners();
      }
      return true;
    }
    return _startServer();
  }

  @override
  void setPort(int port) {
    if (!_backend.isSupported || _disposed) return;
    if (!AutomationDriverConfig.isValidPort(port)) {
      throw RangeError.range(
        port,
        AutomationDriverConfig.minPort,
        AutomationDriverConfig.maxPort,
        'port',
      );
    }
    if (_backend.isRunning) return;
    _startupPortOverride = null;
    _lastError = null;
    _persistedConfig = _persistedConfig.copyWith(port: port);
    _persistConfig();
    _safeNotifyListeners();
  }

  @override
  void setAllowPty(bool allowPty) {
    if (!_backend.isSupported || _disposed || _allowPty == allowPty) return;
    _allowPty = allowPty;
    if (_backend.isRunning) {
      _backend.updateAllowPty(_allowPty);
    }
    _safeNotifyListeners();
  }

  @override
  String regeneratePassword() {
    if (!_backend.isSupported || _disposed) return '';
    final nextPassword = AutomationDriverConfig.generatePassword(
      random: _random,
    );
    _ephemeralTokenOverride = null;
    _persistedConfig = _persistedConfig.copyWith(password: nextPassword);
    _persistConfig();
    if (_backend.isRunning) {
      _backend.updatePassword(nextPassword);
    }
    _safeNotifyListeners();
    return nextPassword;
  }

  @override
  void dispose() {
    _disposed = true;
    if (_backend.isRunning) {
      unawaited(_backend.stop());
    }
    super.dispose();
  }

  void _loadInitialConfig() {
    if (!_backend.isSupported) return;
    final raw = _storage.getItem(ftermAutomationConfigStorageKey);
    final loaded = AutomationDriverConfig.tryFromJsonString(raw);
    if (loaded != null && loaded.hasPassword) {
      _persistedConfig = loaded;
      return;
    }
    final base = loaded ?? AutomationDriverConfig();
    _persistedConfig = base.copyWith(
      password: AutomationDriverConfig.generatePassword(random: _random),
    );
    _persistConfig();
  }

  bool _applyOverrides({
    required bool allowPty,
    required int? portOverride,
    required String? tokenOverride,
  }) {
    var changed = false;
    if (portOverride != null && _startupPortOverride != portOverride) {
      _startupPortOverride = portOverride;
      changed = true;
    }
    final trimmedToken = tokenOverride?.trim();
    if (trimmedToken != null &&
        trimmedToken.isNotEmpty &&
        _ephemeralTokenOverride != trimmedToken) {
      _ephemeralTokenOverride = trimmedToken;
      if (_backend.isRunning) {
        _backend.updatePassword(trimmedToken);
      }
      changed = true;
    }
    if (_allowPty != allowPty) {
      _allowPty = allowPty;
      if (_backend.isRunning) {
        _backend.updateAllowPty(_allowPty);
      }
      changed = true;
    }
    return changed;
  }

  Future<bool> _startServer() async {
    _ensurePasswordReady();
    _lastError = null;
    try {
      await _backend.start(
        port: port,
        password: password,
        allowPty: _allowPty,
        onRequest: _onRequest,
      );
      if (_disposed) {
        await _backend.stop();
        return false;
      }
      _safeNotifyListeners();
      return true;
    } on Object catch (error) {
      _lastError = 'Failed to bind 127.0.0.1:$port: $error';
      _safeNotifyListeners();
      return false;
    }
  }

  Future<bool> _stopServer() async {
    _lastError = null;
    if (_backend.isRunning) {
      await _backend.stop();
    }
    _safeNotifyListeners();
    return false;
  }

  void _ensurePasswordReady() {
    if (password.isNotEmpty) return;
    _persistedConfig = _persistedConfig.copyWith(
      password: AutomationDriverConfig.generatePassword(random: _random),
    );
    _persistConfig();
  }

  void _persistConfig() {
    _storage.setItem(
      ftermAutomationConfigStorageKey,
      _persistedConfig.toJsonString(),
    );
  }

  void _safeNotifyListeners() {
    if (!_disposed) {
      notifyListeners();
    }
  }
}
