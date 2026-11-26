import 'automation_models.dart';

/// No-op [AutomationHttpServerBackend] used on platforms without `dart:io`
/// loopback socket support (such as Web).
final class StubAutomationHttpServer implements AutomationHttpServerBackend {
  /// Creates a [StubAutomationHttpServer].
  const StubAutomationHttpServer();

  @override
  bool get isSupported => false;

  @override
  bool get isRunning => false;

  @override
  int? get boundPort => null;

  @override
  Future<void> start({
    required int port,
    required String password,
    required bool allowPty,
    required AutomationRequestHandler onRequest,
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  void updatePassword(String password) {}

  @override
  void updateAllowPty(bool allowPty) {}
}

/// Platform factory returning a [StubAutomationHttpServer] on non-IO targets.
AutomationHttpServerBackend createPlatformAutomationHttpServerBackend() =>
    const StubAutomationHttpServer();
