import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:termui/terminal/backend/io_backend.dart';
import 'package:termui/terminal/terminal.dart' as term;
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
      'virtual',
      abbr: 'v',
      negatable: false,
      help: 'Run the interactive TUI wrapped inside a VirtualTerminal.',
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
      'tmux-passthrough',
      negatable: false,
      help:
          'Wrap Kitty Graphics APC probe and control commands in tmux DCS '
          'passthrough envelopes.',
    )
    ..addFlag(
      'local-media',
      negatable: false,
      help:
          'Create local temp-file (t=t) and shared-memory (t=s) fixtures to '
          'probe optional Kitty graphics media.',
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
  );
}

void _warnIfLocalMediaUnlinked(
  KttyLocalMediaProbeSession? mediaSession,
  StringSink errSink,
) {
  if (mediaSession == null) return;
  if (mediaSession.tempFilePath != null && !mediaSession.tempFileStillExists) {
    errSink.writeln(
      'Warning: Kitty a=q,t=t unexpectedly unlinked temp probe file '
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

Future<int> _runSelfTest({
  required bool asJson,
  required Duration timeout,
  required bool wrapTmux,
  required bool localMedia,
  required StringSink outSink,
  required StringSink errSink,
  required bool ansiColor,
}) async {
  final replies = StreamController<List<int>>.broadcast();
  final vt = VirtualTerminal(
    width: 100,
    height: 30,
    defaultForeground: const Color(220, 228, 240),
    defaultBackground: const Color(18, 22, 32),
    allowLocalKittyMedia: localMedia,
    onReply: (reply) {
      final bytes = utf8.encode(reply);
      scheduleMicrotask(() {
        if (!replies.isClosed) replies.add(bytes);
      });
    },
  );
  KttyLocalMediaProbeSession? mediaSession;

  try {
    mediaSession = localMedia ? createLocalMediaProbeSession() : null;
    final report = await runKttyBatchProbe(
      wireInput: replies.stream,
      onWriteWire: vt.writeString,
      timeout: timeout,
      options: _buildProbeOptions(
        wrapTmux: wrapTmux,
        mediaSession: mediaSession,
      ),
    );
    _warnIfLocalMediaUnlinked(mediaSession, errSink);
    _printReport(
      report,
      asJson: asJson,
      outSink: outSink,
      ansiColor: ansiColor,
    );
    return report.coreUnsupportedCount == 0 ? 0 : 1;
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
  required bool wrapTmux,
  required bool localMedia,
  required StringSink outSink,
  required StringSink errSink,
  required bool hasStdinTerminal,
  required bool ansiColor,
}) async {
  if (!hasStdinTerminal) {
    errSink.writeln(
      'ktty_probe --report requires an interactive TTY on stdin '
      '(or pass --self-test to probe VirtualTerminal).',
    );
    return 2;
  }

  final muxDiagnostics = await detectMultiplexerDiagnostics();
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
    mediaSession = localMedia ? createLocalMediaProbeSession() : null;
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
    _printReport(
      report,
      asJson: asJson,
      outSink: outSink,
      ansiColor: ansiColor,
    );
    return strict && report.coreUnsupportedCount > 0 ? 1 : 0;
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
  required StringSink outSink,
  required bool ansiColor,
}) {
  if (asJson) {
    outSink.writeln(
      const JsonEncoder.withIndent('  ').convert(report.toJsonMap()),
    );
  } else {
    outSink.write(report.formatPlainReport(ansiColor: ansiColor));
  }
}

Future<void> _runInteractiveStdio(
  Duration timeout, {
  required bool wrapTmux,
  required bool localMedia,
  required StringSink errSink,
}) async {
  final muxDiagnostics = await detectMultiplexerDiagnostics();
  KttyLocalMediaProbeSession? mediaSession;
  IoTerminalBackend? ioBackend;
  StreamSubscription<ProcessSignal>? sigintSub;

  try {
    mediaSession = localMedia ? createLocalMediaProbeSession() : null;
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
  if (results['virtual'] as bool) count++;
  return count;
}

/// Runs the standalone KTTY probe CLI and returns its process exit code.
Future<int> runKttyProbeCli(
  List<String> arguments, {
  StringSink? stdoutSink,
  StringSink? stderrSink,
  bool? stdinHasTerminal,
  bool? stdoutSupportsAnsi,
}) async {
  final outSink = stdoutSink ?? stdout;
  final errSink = stderrSink ?? stderr;
  final ansiColor = stdoutSupportsAnsi ?? stdout.supportsAnsiEscapes;
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
    errSink.writeln(
      'Specify at most one of --self-test, --report, or --virtual.',
    );
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
  final timeout = Duration(milliseconds: max(50, timeoutMs));
  final asJson = results['json'] as bool;
  final strict = results['strict'] as bool;
  final wrapTmux = results['tmux-passthrough'] as bool;
  final localMedia = results['local-media'] as bool;

  if (results['self-test'] as bool) {
    return _runSelfTest(
      asJson: asJson,
      timeout: timeout,
      wrapTmux: wrapTmux,
      localMedia: localMedia,
      outSink: outSink,
      errSink: errSink,
      ansiColor: ansiColor,
    );
  }

  if (results['report'] as bool) {
    return _runStdioBatchReport(
      asJson: asJson,
      timeout: timeout,
      strict: strict,
      wrapTmux: wrapTmux,
      localMedia: localMedia,
      outSink: outSink,
      errSink: errSink,
      hasStdinTerminal: stdinHasTerminal ?? stdin.hasTerminal,
      ansiColor: ansiColor,
    );
  }

  if (results['virtual'] as bool) {
    await term.Terminal.runGuarded((terminal) async {
      await runVirtualTerminalKttyProbe(terminal);
    });
    return 0;
  }

  await _runInteractiveStdio(
    timeout,
    wrapTmux: wrapTmux,
    localMedia: localMedia,
    errSink: errSink,
  );
  return 0;
}

/// CLI entrypoint for the standalone KTTY capability probe and TUI check suite.
Future<void> main(List<String> arguments) async {
  exit(await runKttyProbeCli(arguments));
}
