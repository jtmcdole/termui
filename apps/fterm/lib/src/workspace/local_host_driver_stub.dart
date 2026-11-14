import 'local_host_driver_interface.dart';

export 'local_host_driver_interface.dart';

/// Browser and test-fallback [LocalHostDriver] where native PTY hosting is
/// unsupported.
LocalHostDriver createPlatformLocalHostDriver() => const _StubLocalHostDriver();

final class _StubLocalHostDriver implements LocalHostDriver {
  const _StubLocalHostDriver();

  @override
  bool get isSupported => false;

  @override
  Future<LocalPaneHost> openShell(LocalShellConfig config) => Future.error(
    UnsupportedError('Local shells are unavailable on this platform.'),
  );

  @override
  Future<void> dispose() async {}
}
