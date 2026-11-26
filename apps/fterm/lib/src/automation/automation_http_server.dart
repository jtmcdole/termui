import 'automation_http_server_stub.dart'
    if (dart.library.io) 'automation_http_server_io.dart'
    as impl;
import 'automation_models.dart';

/// Creates the platform-appropriate [AutomationHttpServerBackend] (`dart:io`
/// loopback server on desktop platforms, no-op stub on Web).
AutomationHttpServerBackend createAutomationHttpServerBackend() =>
    impl.createPlatformAutomationHttpServerBackend();
