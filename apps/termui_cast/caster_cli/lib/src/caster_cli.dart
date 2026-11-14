import 'dart:async';
import 'dart:io';

import 'package:termui_cast_protocol/termui_cast_protocol_io.dart';

import 'caster_service.dart';
import 'pty_process_adapter.dart';

void _writeLineSafely(StringSink sink, String line) {
  try {
    sink.writeln(line);
  } on IOException catch (_) {}
}

/// Runs the `termui_cast` CLI with [args], returning the child or error exit code.
Future<int> runCasterCli(
  List<String> args, {
  StringSink? out,
  StringSink? err,
  ChannelOpener? channelOpener,
  IapJwtSigner? iapSigner,
  Stream<void>? shutdownSignal,
  Stream<void>? checkInSignal,
  Map<String, String>? environment,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  final env = environment ?? Platform.environment;

  final CasterConfig? config;
  try {
    config = CasterConfig.fromArgs(args, environment: env);
  } on FormatException catch (e) {
    _writeLineSafely(stderrSink, 'termui_cast: ${e.message}');
    _writeLineSafely(stderrSink, CasterConfig.buildArgParser().usage);
    return 64;
  }

  if (config == null) {
    _writeLineSafely(
      stdoutSink,
      'Usage: termui_cast [options] -- <command> [args...]',
    );
    _writeLineSafely(stdoutSink, CasterConfig.buildArgParser().usage);
    return 0;
  }

  final resolvedIapSigner =
      iapSigner ??
      ((config.iapServiceAccount != null || config.iapServiceAccountKey != null)
          ? IapJwtSigner(
              serviceAccount: config.iapServiceAccount,
              serviceAccountKey: config.iapServiceAccountKey,
              targetAudienceUrl: IapJwtSigner.audienceForWebSocketUri(
                config.serverUri,
              ),
            )
          : null);

  var interrupted = false;
  CasterService? service;
  StreamSubscription<void>? signalSub;
  final checkInSub = (checkInSignal ?? watchPosixHangupSignals()).listen((_) {
    if (!interrupted && service != null) {
      unawaited(service.checkIn());
    }
  });
  try {
    if (resolvedIapSigner != null) {
      try {
        await resolvedIapSigner.getBearerToken();
      } on Object catch (e) {
        _writeLineSafely(
          stderrSink,
          'termui_cast: IAP token pre-warm failed: $e',
        );
      }
    }

    final PtySession pty;
    try {
      await Pty2Session.ensureConPtyReady(
        download: config.downloadConPty,
        onWarning: (msg) => _writeLineSafely(stderrSink, 'termui_cast: $msg'),
      );
      pty = Pty2Session.start(
        config.command.first,
        config.command.sublist(1),
        initialCols: config.initialCols,
        initialRows: config.initialRows,
      );
    } on Object catch (e) {
      _writeLineSafely(
        stderrSink,
        'termui_cast: failed to start PTY command: $e',
      );
      return 70;
    }

    final activeService = CasterService(
      config: config,
      pty: pty,
      channelOpener: channelOpener,
      iapTokenProvider: resolvedIapSigner?.getBearerToken,
      onLog: (msg) => _writeLineSafely(stderrSink, 'termui_cast: $msg'),
    );
    service = activeService;
    final stopStream = shutdownSignal ?? watchPosixTerminationSignals();
    signalSub = stopStream.listen((_) {
      if (interrupted) return;
      interrupted = true;
      unawaited(activeService.stop(killPty: true));
    });
    await activeService.start();
    return await activeService.done;
  } finally {
    await signalSub?.cancel();
    await checkInSub.cancel();
  }
}
