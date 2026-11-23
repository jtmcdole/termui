import 'dart:async';
import 'dart:io';

import 'package:termui_cast_protocol/termui_cast_protocol_io.dart';

import 'caster_service.dart';
import 'caster_supervisor.dart';
import 'pty_process_adapter.dart';

void _writeLineSafely(StringSink sink, String line) {
  try {
    sink.writeln(line);
  } on IOException catch (_) {}
}

({CasterConfig? config, int? exitCode}) _parseCliConfig(
  List<String> args,
  Map<String, String> env,
  StringSink stdoutSink,
  StringSink stderrSink,
) {
  try {
    final config = CasterConfig.fromArgs(args, environment: env);
    if (config == null) {
      _writeLineSafely(
        stdoutSink,
        'Usage: termui_cast [options] -- <command> [args...]',
      );
      _writeLineSafely(stdoutSink, CasterConfig.buildArgParser().usage);
      return (config: null, exitCode: 0);
    }
    return (config: config, exitCode: null);
  } on FormatException catch (e) {
    _writeLineSafely(stderrSink, 'termui_cast: ${e.message}');
    _writeLineSafely(stderrSink, CasterConfig.buildArgParser().usage);
    return (config: null, exitCode: 64);
  }
}

Future<void> _prewarmIapSigner(
  IapJwtSigner? signer,
  StringSink stderrSink,
) async {
  if (signer == null) return;
  try {
    await signer.getBearerToken();
  } on Object catch (e) {
    _writeLineSafely(stderrSink, 'termui_cast: IAP token pre-warm failed: $e');
  }
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
  PtyStarter? ptyStarter,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  final resolvedEnvironment = environment ?? Platform.environment;
  final parsed = _parseCliConfig(
    args,
    resolvedEnvironment,
    stdoutSink,
    stderrSink,
  );
  final config = parsed.config;
  if (config == null) return parsed.exitCode ?? 64;

  for (final warning in config.warnings) {
    _writeLineSafely(stderrSink, 'termui_cast: warning: $warning');
  }

  final resolvedIapSigner = iapSigner ?? config.createIapSigner();
  var interrupted = false;
  CasterSupervisor? supervisor;
  StreamSubscription<void>? signalSub;

  void triggerShutdown() {
    if (interrupted) return;
    interrupted = true;
    final active = supervisor;
    if (active != null) unawaited(active.stop(killPty: true));
  }

  final hupSub = _subscribeHupSignal(
    config: config,
    checkInSignal: checkInSignal,
    stderrSink: stderrSink,
    onCheckIn: () => supervisor?.checkIn(),
    onShutdown: triggerShutdown,
    isInterrupted: () => interrupted,
  );
  try {
    await _prewarmIapSigner(resolvedIapSigner, stderrSink);
    if (interrupted) return -1;

    final activeSupervisor = CasterSupervisor(
      primaryConfig: config,
      ptyStarter: ptyStarter ?? (cfg) => _startCliPty(cfg, stderrSink),
      environment: resolvedEnvironment,
      channelOpener: channelOpener,
      iapTokenProvider: resolvedIapSigner?.getBearerToken,
      onLog: (msg) => _writeLineSafely(stderrSink, 'termui_cast: $msg'),
    );
    supervisor = activeSupervisor;
    final stopStream = shutdownSignal ?? watchPosixTerminationSignals();
    signalSub = stopStream.listen((_) => triggerShutdown());
    if (interrupted) unawaited(activeSupervisor.stop(killPty: true));
    final started = await activeSupervisor.start();
    if (!started) return interrupted ? -1 : 70;
    return await activeSupervisor.done;
  } finally {
    await signalSub?.cancel();
    await hupSub.cancel();
  }
}

StreamSubscription<void> _subscribeHupSignal({
  required CasterConfig config,
  required Stream<void>? checkInSignal,
  required StringSink stderrSink,
  required Future<void>? Function() onCheckIn,
  required void Function() onShutdown,
  required bool Function() isInterrupted,
}) {
  if (checkInSignal != null || config.keepAliveOnHup) {
    return (checkInSignal ?? watchPosixHangupSignals()).listen((_) {
      if (isInterrupted()) return;
      final pending = onCheckIn();
      if (pending != null) unawaited(pending);
    });
  }
  return watchPosixHangupSignals().listen((_) {
    _writeLineSafely(
      stderrSink,
      'termui_cast: received SIGHUP; shutting down cleanly (pass --keep-alive-on-hup to check in instead)',
    );
    onShutdown();
  });
}

Future<PtySession?> _startCliPty(
  CasterConfig config,
  StringSink stderrSink,
) async {
  try {
    await Pty2Session.ensureConPtyReady(
      download: config.downloadConPty,
      onWarning: (msg) => _writeLineSafely(stderrSink, 'termui_cast: $msg'),
    );
    return Pty2Session.start(
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
    return null;
  }
}
