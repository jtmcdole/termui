import 'ktty_probe_report.dart';

final class _StubLocalMediaProbeSession implements KttyLocalMediaProbeSession {
  const _StubLocalMediaProbeSession();

  @override
  String? get tempFilePath => null;

  @override
  String? get shmObjectName => null;

  @override
  bool get tempFileStillExists => false;

  @override
  bool get shmStillExists => false;

  @override
  void dispose() {}
}

/// Web/non-IO stub returning a no-op [KttyLocalMediaProbeSession].
KttyLocalMediaProbeSession createLocalMediaProbeSession() =>
    const _StubLocalMediaProbeSession();
