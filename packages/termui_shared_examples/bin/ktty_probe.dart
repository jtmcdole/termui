import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:clock/clock.dart';
import 'package:termui/terminal/backend/io_backend.dart';
import 'package:termui/ui/color.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:termui_shared_examples/ktty_probe/ktty_probe.dart';

ArgParser _buildArgParser() {
  return ArgParser()
    ..addFlag(
      'report',
      abbr: 'r',
      negatable: false,
      help: 'Run a non-interactive wire capability probe and print the report.',
    )
    ..addFlag(
      'self-test',
      negatable: false,
      help:
          'Run the batch capability probe against an in-memory VirtualTerminal.',
    )
    ..addFlag(
      'json',
      abbr: 'j',
      negatable: false,
      help: 'Emit probe results as JSON (with --report or --self-test).',
    )
    ..addFlag(
      'strict',
      negatable: false,
      help:
          'Exit with code 1 when any core capability is unsupported '
          '(with --report or --self-test).',
    )
    ..addFlag(
      'diagnose',
      negatable: false,
      help:
          'Append terminfo, environment, XTGETTCAP, and multiplexer '
          'diagnostics to --report or --self-test output.',
    )
    ..addOption(
      'compare',
      valueHelp: 'baseline.json',
      help:
          'Compare probe results against a JSON baseline file and exit 1 on '
          'any capability regression (PASS -> MISS).',
    )
    ..addFlag(
      'tmux-passthrough',
      negatable: false,
      help:
          'Wrap Kitty Graphics APC probe and control commands in tmux DCS '
          'passthrough envelopes.',
    )
    ..addOption(
      'timeout-ms',
      defaultsTo: '600',
      help: 'Fallback timeout in milliseconds when DA1 sentinel is unanswered.',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show CLI usage.');
}

KttyProbeOptions _buildProbeOptions({
  required bool wrapTmux,
  KttyLocalMediaProbeSession? mediaSession,
}) {
  return KttyProbeOptions(
    wrapTmuxPassthrough: wrapTmux,
    tempProbeFilePath: mediaSession?.tempFilePath,
    shmProbeName: mediaSession?.shmObjectName,
    fileProbeFilePath: mediaSession?.tempFilePath,
  );
}

void _warnIfLocalMediaUnlinked(
  KttyLocalMediaProbeSession? mediaSession,
  StringSink errSink,
) {
  if (mediaSession == null) return;
  if (mediaSession.tempFilePath != null && !mediaSession.tempFileStillExists) {
    errSink.writeln(
      'Warning: Kitty a=q,t=t/t=f unexpectedly unlinked local probe file '
      '(${mediaSession.tempFilePath}).',
    );
  }
  if (mediaSession.shmObjectName != null && !mediaSession.shmStillExists) {
    errSink.writeln(
      'Warning: Kitty a=q,t=s unexpectedly unlinked shared-memory probe '
      'object (${mediaSession.shmObjectName}).',
    );
  }
}

void _printMultiplexerHintsToStderr(
  KttyMultiplexerDiagnostics? diagnostics,
  StringSink errSink,
) {
  if (diagnostics == null || diagnostics.hints.isEmpty) return;
  errSink.writeln('Multiplexer diagnostics (${diagnostics.multiplexer}):');
  for (final hint in diagnostics.hints) {
    errSink.writeln('  Hint: $hint');
  }
}

RandomAccessFile? _openControllingTtyForWrite() {
  if (Platform.isWindows) return null;
  try {
    return File('/dev/tty').openSync(mode: FileMode.writeOnlyAppend);
  } on FileSystemException {
    return null;
  }
}

Map<String, Object?>? _loadBaselineJson(String path, StringSink errSink) {
  final file = File(path);
  if (!file.existsSync()) {
    errSink.writeln('Baseline file not found: $path');
    return null;
  }
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, Object?> ||
        decoded['capabilities'] is! List<Object?>) {
      errSink.writeln(
        'Invalid baseline JSON in "$path": expected object with "capabilities" list.',
      );
      return null;
    }
    return decoded;
  } on Object catch (e) {
    errSink.writeln('Failed to read baseline JSON "$path": $e');
    return null;
  }
}

int _emitBatchOutput(
  KttyProbeReport report, {
  required bool asJson,
  required bool diagnose,
  required bool strict,
  required bool requireZeroCoreUnsupported,
  required Map<String, Object?>? baselineJson,
  required Map<String, String> environment,
  required StringSink outSink,
  required bool ansiColor,
}) {
  final diff = baselineJson != null
      ? report.diffAgainstBaseline(baselineJson)
      : null;
  _printReport(
    report,
    asJson: asJson,
    diagnose: diagnose,
    diff: diff,
    environment: environment,
    outSink: outSink,
    ansiColor: ansiColor,
  );
  if (diff != null && diff.hasRegressions) return 1;
  if ((strict || requireZeroCoreUnsupported) &&
      report.coreUnsupportedCount > 0) {
    return 1;
  }
  return 0;
}

Future<int> _runSelfTest({
  required bool asJson,
  required Duration timeout,
  required bool strict,
  required bool diagnose,
  required Map<String, Object?>? baselineJson,
  required bool wrapTmux,
  required Map<String, String> environment,
  required StringSink outSink,
  required StringSink errSink,
  required bool ansiColor,
  Future<KttyProbeReport> Function(KttyProbeOptions options)? probeOverride,
}) async {
  final replies = StreamController<List<int>>.broadcast();
  final vt = VirtualTerminal(
    width: 100,
    height: 30,
    defaultForeground: const Color(220, 228, 240),
    defaultBackground: const Color(18, 22, 32),
    allowLocalKittyMedia: true,
    allowLocalKittyFiles: true,
    onReply: (reply) {
      final bytes = utf8.encode(reply);
      scheduleMicrotask(() {
        if (!replies.isClosed) replies.add(bytes);
      });
    },
  );
  KttyLocalMediaProbeSession? mediaSession;

  try {
    mediaSession = createLocalMediaProbeSession();
    final options = _buildProbeOptions(
      wrapTmux: wrapTmux,
      mediaSession: mediaSession,
    );
    final report = probeOverride != null
        ? await probeOverride(options)
        : await runKttyBatchProbe(
            wireInput: replies.stream,
            onWriteWire: vt.writeString,
            timeout: timeout,
            options: options,
          );
    _warnIfLocalMediaUnlinked(mediaSession, errSink);
    return _emitBatchOutput(
      report,
      asJson: asJson,
      diagnose: diagnose,
      strict: strict,
      requireZeroCoreUnsupported: baselineJson == null,
      baselineJson: baselineJson,
      environment: environment,
      outSink: outSink,
      ansiColor: ansiColor,
    );
  } finally {
    mediaSession?.dispose();
    await replies.close();
    vt.dispose();
  }
}

Future<int> _runStdioBatchReport({
  required bool asJson,
  required Duration timeout,
  required bool strict,
  required bool diagnose,
  required Map<String, Object?>? baselineJson,
  required bool wrapTmux,
  required Map<String, String> environment,
  required StringSink outSink,
  required StringSink errSink,
  required bool hasStdinTerminal,
  required bool ansiColor,
  Future<KttyProbeReport> Function(KttyProbeOptions options)? probeOverride,
}) async {
  if (probeOverride != null) {
    final report = await probeOverride(_buildProbeOptions(wrapTmux: wrapTmux));
    return _emitBatchOutput(
      report,
      asJson: asJson,
      diagnose: diagnose,
      strict: strict,
      requireZeroCoreUnsupported: false,
      baselineJson: baselineJson,
      environment: environment,
      outSink: outSink,
      ansiColor: ansiColor,
    );
  }
  if (!hasStdinTerminal) {
    errSink.writeln(
      'ktty_probe --report requires an interactive TTY on stdin '
      '(or pass --self-test to probe VirtualTerminal).',
    );
    return 2;
  }

  final muxDiagnostics = await detectMultiplexerDiagnostics(
    environment: environment,
  );
  KttyLocalMediaProbeSession? mediaSession;
  IoTerminalBackend? ioBackend;
  RandomAccessFile? ttyOut;
  StreamSubscription<ProcessSignal>? sigintSub;
  StreamSubscription<List<int>>? ctrlCSub;
  var aborted = false;

  try {
    if (!Platform.isWindows) {
      ttyOut = _openControllingTtyForWrite();
      if (ttyOut == null) {
        errSink.writeln(
          'ktty_probe --report could not open /dev/tty for writing probes '
          '(or pass --self-test to probe VirtualTerminal).',
        );
        return 2;
      }
    }
    mediaSession = createLocalMediaProbeSession();
    ioBackend = IoTerminalBackend();
    final stopHandle = KttyProbeStopHandle();
    void abortProbe() {
      aborted = true;
      stopHandle.stop();
    }

    if (!Platform.isWindows) {
      sigintSub = ProcessSignal.sigint.watch().listen((_) => abortProbe());
    }
    ctrlCSub = ioBackend.rawInput.listen((chunk) {
      if (chunk.contains(0x03)) abortProbe();
    });

    ioBackend.enableRawMode();
    final report = await runKttyBatchProbe(
      wireInput: ioBackend.rawInput,
      onWriteWire: (data) {
        if (ttyOut != null) {
          ttyOut.writeStringSync(data);
        } else {
          stdout.write(data);
        }
      },
      timeout: timeout,
      options: _buildProbeOptions(
        wrapTmux: wrapTmux,
        mediaSession: mediaSession,
      ),
      stopHandle: stopHandle,
    );
    report.multiplexerDiagnostics = muxDiagnostics;
    ioBackend.disableRawMode();
    if (aborted) return 130;
    _warnIfLocalMediaUnlinked(mediaSession, errSink);
    return _emitBatchOutput(
      report,
      asJson: asJson,
      diagnose: diagnose,
      strict: strict,
      requireZeroCoreUnsupported: false,
      baselineJson: baselineJson,
      environment: environment,
      outSink: outSink,
      ansiColor: ansiColor,
    );
  } finally {
    await ctrlCSub?.cancel();
    await sigintSub?.cancel();
    mediaSession?.dispose();
    ttyOut?.closeSync();
    ioBackend?.disableRawMode();
    ioBackend?.dispose();
  }
}

void _printReport(
  KttyProbeReport report, {
  required bool asJson,
  required bool diagnose,
  required KttyProbeDiff? diff,
  required Map<String, String> environment,
  required StringSink outSink,
  required bool ansiColor,
}) {
  if (asJson) {
    final jsonMap = <String, Object?>{
      ...report.toJsonMap(),
      if (diff != null) 'comparison': diff.toJsonMap(),
      if (diagnose)
        'diagnostics': {
          'term': environment['TERM'],
          'colorterm': environment['COLORTERM'],
          'hints': report.buildDiagnosticHints(environment: environment),
          'summary': report.buildDiagnosticSummary(
            environment: environment,
            ansiColor: false,
          ),
        },
    };
    outSink.writeln(const JsonEncoder.withIndent('  ').convert(jsonMap));
    return;
  }
  outSink.write(report.formatPlainReport(ansiColor: ansiColor));
  if (diff != null) {
    outSink.write(diff.formatPlainSummary(ansiColor: ansiColor));
  }
  if (diagnose) {
    outSink.write(
      report.buildDiagnosticSummary(
        environment: environment,
        ansiColor: ansiColor,
      ),
    );
  }
}

String _exportInteractiveReportToFile(String reportJson) {
  final ts = clock.now().toUtc().millisecondsSinceEpoch;
  final path = 'ktty_probe_report_$ts.json';
  File(path).writeAsStringSync('$reportJson\n');
  return path;
}

Future<void> _runInteractiveStdio(
  Duration timeout, {
  required bool wrapTmux,
  required Map<String, String> environment,
  required StringSink errSink,
}) async {
  final muxDiagnostics = await detectMultiplexerDiagnostics(
    environment: environment,
  );
  KttyLocalMediaProbeSession? mediaSession;
  IoTerminalBackend? ioBackend;
  StreamSubscription<ProcessSignal>? sigintSub;

  try {
    mediaSession = createLocalMediaProbeSession();
    ioBackend = IoTerminalBackend();
    final rawSize = ioBackend.size;
    final initialSize = rawSize.x > 0 && rawSize.y > 0
        ? rawSize
        : const Point<int>(100, 30);
    final report = KttyProbeReport()..multiplexerDiagnostics = muxDiagnostics;
    final wireBackend = KttyWireTerminalBackend(
      wireInput: ioBackend.rawInput,
      onWriteWire: ioBackend.write,
      report: report,
      initialSize: initialSize,
      externalResizeStream: ioBackend.watchSize(),
      onEnableRawMode: ioBackend.enableRawMode,
      onDisableRawMode: ioBackend.disableRawMode,
      isWindows: ioBackend.isWindows,
    );

    final stopHandle = KttyProbeStopHandle();
    if (!Platform.isWindows) {
      sigintSub = ProcessSignal.sigint.watch().listen((_) => stopHandle.stop());
    }

    await runKttyProbeOnWire(
      wireBackend,
      probeTimeout: timeout,
      stopHandle: stopHandle,
      options: _buildProbeOptions(
        wrapTmux: wrapTmux,
        mediaSession: mediaSession,
      ),
      onExportReport: _exportInteractiveReportToFile,
    );
    ioBackend.disableRawMode();
    _warnIfLocalMediaUnlinked(mediaSession, errSink);
    _printMultiplexerHintsToStderr(muxDiagnostics, errSink);
  } finally {
    mediaSession?.dispose();
    await sigintSub?.cancel();
    ioBackend?.disableRawMode();
    ioBackend?.dispose();
  }
}

int _countSelectedModes(ArgResults results) {
  var count = 0;
  if (results['self-test'] as bool) count++;
  if (results['report'] as bool) count++;
  return count;
}

/// Runs the standalone KTTY probe CLI and returns its process exit code.
Future<int> runKttyProbeCli(
  List<String> arguments, {
  StringSink? stdoutSink,
  StringSink? stderrSink,
  bool? stdinHasTerminal,
  bool? stdoutSupportsAnsi,
  Map<String, String>? environment,
  Future<KttyProbeReport> Function(KttyProbeOptions options)? probeOverride,
}) async {
  final outSink = stdoutSink ?? stdout;
  final errSink = stderrSink ?? stderr;
  final ansiColor = stdoutSupportsAnsi ?? stdout.supportsAnsiEscapes;
  final env = environment ?? Platform.environment;
  final parser = _buildArgParser();
  final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (e) {
    errSink.writeln(e.message);
    errSink.writeln(parser.usage);
    return 64;
  }

  if (results['help'] as bool) {
    outSink.writeln(
      'KTTY Probe: Standalone Kitty & VT capability diagnostic suite.\n',
    );
    outSink.writeln(parser.usage);
    return 0;
  }

  if (_countSelectedModes(results) > 1) {
    errSink.writeln('Specify at most one of --self-test or --report.');
    errSink.writeln(parser.usage);
    return 64;
  }

  final timeoutRaw = results['timeout-ms'] as String;
  final timeoutMs = int.tryParse(timeoutRaw);
  if (timeoutMs == null || timeoutMs <= 0) {
    errSink.writeln(
      'Invalid --timeout-ms value: "$timeoutRaw" (expected positive integer).',
    );
    errSink.writeln(parser.usage);
    return 64;
  }

  final comparePath = results['compare'] as String?;
  final diagnose = results['diagnose'] as bool;
  final isBatchMode =
      (results['self-test'] as bool) || (results['report'] as bool);
  if (!isBatchMode && (comparePath != null || diagnose)) {
    errSink.writeln(
      '--compare and --diagnose require --report or --self-test.',
    );
    errSink.writeln(parser.usage);
    return 64;
  }

  Map<String, Object?>? baselineJson;
  if (comparePath != null) {
    baselineJson = _loadBaselineJson(comparePath, errSink);
    if (baselineJson == null) return 64;
  }

  final timeout = Duration(milliseconds: max(50, timeoutMs));
  final asJson = results['json'] as bool;
  final strict = results['strict'] as bool;
  final wrapTmux = results['tmux-passthrough'] as bool;

  if (results['self-test'] as bool) {
    return _runSelfTest(
      asJson: asJson,
      timeout: timeout,
      strict: strict,
      diagnose: diagnose,
      baselineJson: baselineJson,
      wrapTmux: wrapTmux,
      environment: env,
      outSink: outSink,
      errSink: errSink,
      ansiColor: ansiColor,
      probeOverride: probeOverride,
    );
  }

  if (results['report'] as bool) {
    return _runStdioBatchReport(
      asJson: asJson,
      timeout: timeout,
      strict: strict,
      diagnose: diagnose,
      baselineJson: baselineJson,
      wrapTmux: wrapTmux,
      environment: env,
      outSink: outSink,
      errSink: errSink,
      hasStdinTerminal: stdinHasTerminal ?? stdin.hasTerminal,
      ansiColor: ansiColor,
      probeOverride: probeOverride,
    );
  }

  await _runInteractiveStdio(
    timeout,
    wrapTmux: wrapTmux,
    environment: env,
    errSink: errSink,
  );
  return 0;
}

/// CLI entrypoint for the standalone KTTY capability probe and TUI check suite.
Future<void> main(List<String> arguments) async {
  exit(await runKttyProbeCli(arguments));
}
