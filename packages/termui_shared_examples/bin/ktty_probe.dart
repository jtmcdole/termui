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
    ..addOption(
      'timeout-ms',
      defaultsTo: '600',
      help: 'Fallback timeout in milliseconds when DA1 sentinel is unanswered.',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show CLI usage.');
}

Future<int> _runSelfTest({
  required bool asJson,
  required Duration timeout,
}) async {
  final replies = StreamController<List<int>>.broadcast();
  final vt = VirtualTerminal(
    width: 100,
    height: 30,
    defaultForeground: const Color(220, 228, 240),
    defaultBackground: const Color(18, 22, 32),
    onReply: (reply) {
      final bytes = utf8.encode(reply);
      scheduleMicrotask(() {
        if (!replies.isClosed) replies.add(bytes);
      });
    },
  );

  try {
    final report = await runKttyBatchProbe(
      wireInput: replies.stream,
      onWriteWire: vt.writeString,
      timeout: timeout,
    );
    _printReport(report, asJson: asJson);
    return report.unsupportedCount == 0 ? 0 : 1;
  } finally {
    await replies.close();
    vt.dispose();
  }
}

Future<int> _runStdioBatchReport({
  required bool asJson,
  required Duration timeout,
}) async {
  if (!stdin.hasTerminal) {
    stderr.writeln(
      'ktty_probe --report requires an interactive TTY on stdin '
      '(or pass --self-test to probe VirtualTerminal).',
    );
    return 2;
  }

  final ioBackend = IoTerminalBackend();
  ioBackend.enableRawMode();
  try {
    final report = await runKttyBatchProbe(
      wireInput: ioBackend.rawInput,
      onWriteWire: (data) {
        stdout.write(data);
      },
      timeout: timeout,
    );
    ioBackend.disableRawMode();
    _printReport(report, asJson: asJson);
    return 0;
  } finally {
    ioBackend.disableRawMode();
    ioBackend.dispose();
  }
}

void _printReport(KttyProbeReport report, {required bool asJson}) {
  if (asJson) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert(report.toJsonMap()),
    );
  } else {
    stdout.write(
      report.formatPlainReport(ansiColor: stdout.supportsAnsiEscapes),
    );
  }
}

Future<void> _runInteractiveStdio(Duration timeout) async {
  final ioBackend = IoTerminalBackend();
  final rawSize = ioBackend.size;
  final initialSize = rawSize.x > 0 && rawSize.y > 0
      ? rawSize
      : const Point<int>(100, 30);
  final report = KttyProbeReport();
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
  StreamSubscription<ProcessSignal>? sigintSub;
  if (!Platform.isWindows) {
    sigintSub = ProcessSignal.sigint.watch().listen((_) => stopHandle.stop());
  }

  try {
    await runKttyProbeOnWire(
      wireBackend,
      probeTimeout: timeout,
      stopHandle: stopHandle,
    );
  } finally {
    await sigintSub?.cancel();
    ioBackend.disableRawMode();
    ioBackend.dispose();
  }
}

/// CLI entrypoint for the standalone KTTY capability probe and TUI check suite.
Future<void> main(List<String> arguments) async {
  final parser = _buildArgParser();
  final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(parser.usage);
    exit(64);
  }

  if (results['help'] as bool) {
    stdout.writeln(
      'KTTY Probe: Standalone Kitty & VT capability diagnostic suite.\n',
    );
    stdout.writeln(parser.usage);
    exit(0);
  }

  final timeoutMs = int.tryParse(results['timeout-ms'] as String) ?? 600;
  final timeout = Duration(milliseconds: max(50, timeoutMs));
  final asJson = results['json'] as bool;

  if (results['self-test'] as bool) {
    final code = await _runSelfTest(asJson: asJson, timeout: timeout);
    exit(code);
  }

  if (results['report'] as bool) {
    final code = await _runStdioBatchReport(asJson: asJson, timeout: timeout);
    exit(code);
  }

  if (results['virtual'] as bool) {
    await term.Terminal.runGuarded((terminal) async {
      await runVirtualTerminalKttyProbe(terminal);
    });
    exit(0);
  }

  await _runInteractiveStdio(timeout);
  exit(0);
}
