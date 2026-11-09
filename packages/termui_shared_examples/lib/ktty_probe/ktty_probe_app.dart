import 'dart:async';
import 'dart:convert';

import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;

import 'ktty_probe_report.dart';
import 'ktty_probe_widgets.dart';
import 'ktty_reply_interceptor.dart';
import 'ktty_wire_backend.dart';

/// Runs a non-interactive capability probe over [wireInput] and [onWriteWire],
/// completing as soon as the `DA1` sentinel arrives or [timeout] elapses.
Future<KttyProbeReport> runKttyBatchProbe({
  required Stream<List<int>> wireInput,
  required void Function(String data) onWriteWire,
  Duration timeout = const Duration(milliseconds: 500),
}) async {
  final report = KttyProbeReport()..resetForNewProbe();
  final interceptor = KttyReplyInterceptor(report);
  final done = Completer<void>();

  void checkComplete() {
    if (report.isComplete && !done.isCompleted) {
      done.complete();
    }
  }

  report.addListener(checkComplete);
  final sub = wireInput.listen((chunk) {
    interceptor.processChunk(chunk);
  });
  final timer = Timer(timeout, () {
    if (!done.isCompleted) {
      report.finalizePending('Timed out waiting for DA1');
      done.complete();
    }
  });

  onWriteWire(KttyProbeReport.buildWireProbeSequence());
  try {
    await done.future;
  } finally {
    timer.cancel();
    report.removeListener(checkComplete);
    await sub.cancel();
  }
  return report;
}

/// Synchronous cancellation handle for stopping an active [runKttyProbeOnWire] session.
final class KttyProbeStopHandle {
  void Function()? _onStop;
  bool _stopped = false;

  void _attach(void Function() onStop) {
    _onStop = onStop;
    if (_stopped) onStop();
  }

  /// Requests immediate clean termination of the running KTTY probe session.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _onStop?.call();
  }
}

/// Runs the interactive KTTY Probe & Check TUI over a [KttyWireTerminalBackend].
Future<KttyProbeReport> runKttyProbeOnWire(
  KttyWireTerminalBackend backend, {
  Duration probeTimeout = const Duration(milliseconds: 600),
  KttyProbeStopHandle? stopHandle,
}) async {
  final terminal = term.Terminal(backend);
  final sceneManager = SceneManager(terminal, renderingMode: .alternateScreen)
    ..enableMouseTracking = true;

  final exitCompleter = Completer<void>();
  void requestQuit() {
    if (!exitCompleter.isCompleted) exitCompleter.complete();
  }

  stopHandle?._attach(requestQuit);

  terminal
    ..enterAlternateScreen()
    ..hideCursor()
    ..enableMouseTracking()
    ..enableBracketedPaste();
  backend.interceptor.sgrPixelsRequested = true;
  backend.write('\x1b[?1004h\x1b[>11u\x1b[?1016h');

  late final PromptRunner<void> runner;
  runner = PromptRunner<void>(
    terminal: terminal,
    widget: KttyProbeStatefulRoot(
      backend: backend,
      terminal: terminal,
      probeTimeout: probeTimeout,
      onQuit: requestQuit,
    ),
    alternateScreen: false,
    mode: .managed,
    onFramePainted: (_) => sceneManager.scheduleRender(),
  );

  final rootLayer = SceneLayer(
    renderer: runner,
    sizing: .fullscreen,
    zIndex: 10,
  );
  sceneManager.layers.add(rootLayer);
  sceneManager.focusedLayer = rootLayer;
  unawaited(runner.run().catchError((Object _) {}));

  sceneManager.onKeyEvent = (event) {
    if (event.eventType == term.KeyEventType.release) return false;
    if (event.logicalKey == TermKey.controlC ||
        event.logicalKey == TermKey.controlQ) {
      requestQuit();
      return true;
    }
    return false;
  };

  try {
    await exitCompleter.future;
  } finally {
    runner.abort();
    sceneManager.dispose();
    backend.write(
      '\x1b[<u\x1b[?1016l\x1b[?1004l\x1b[?2004l'
      '\x1b[?1003l\x1b[?1006l\x1b[?1049l\x1b[?25h\x1b[0m',
    );
    terminal.dispose();
  }
  return backend.report;
}

/// Stateful root widget managing probe lifecycles, mode toggles, and telemetry.
final class KttyProbeStatefulRoot extends StatefulWidget {
  /// Wire backend carrying raw escape sequences and replies.
  final KttyWireTerminalBackend backend;

  /// Wrapped `termui` terminal instance.
  final term.Terminal terminal;

  /// Fallback timeout if the target terminal ignores `DA1`.
  final Duration probeTimeout;

  /// Callback invoked when the user exits the probe app.
  final void Function() onQuit;

  /// Creates a [KttyProbeStatefulRoot].
  const KttyProbeStatefulRoot({
    super.key,
    required this.backend,
    required this.terminal,
    required this.probeTimeout,
    required this.onQuit,
  });

  @override
  State<KttyProbeStatefulRoot> createState() => _KttyProbeStatefulRootState();
}

final class _KttyProbeStatefulRootState extends State<KttyProbeStatefulRoot> {
  static const List<int> _kbFlagCycle = [11, 3, 1, 0];

  final FocusNode _focusNode = FocusNode(id: 'ktty_probe_root');
  final List<String> _keyLog = [
    'Press or release any key to inspect Kitty CSI u telemetry',
  ];

  KttyProbeTab _activeTab = .overview;
  int _kbCycleIndex = 0;
  bool _sgrPixelsEnabled = true;
  bool _showOcclusion = true;
  int _notifySeq = 0;
  int _clipboardSeq = 0;
  int _titleSeq = 0;
  int _promptSeq = 0;
  String _lastActionMessage = 'Ready — press [N] OSC99, [C] OSC52, [T] Title';
  Timer? _probeFallbackTimer;

  int get _requestedKbFlags => _kbFlagCycle[_kbCycleIndex];

  @override
  void initState() {
    super.initState();
    widget.backend.report.addListener(_onReportUpdated);
    _triggerProbe();
  }

  @override
  void dispose() {
    _probeFallbackTimer?.cancel();
    widget.backend.report.removeListener(_onReportUpdated);
    _focusNode.dispose();
    super.dispose();
  }

  void _onReportUpdated() {
    if (mounted) setState(() {});
  }

  void _triggerProbe() {
    _probeFallbackTimer?.cancel();
    widget.backend.report.resetForNewProbe();
    widget.backend.write(KttyProbeReport.buildWireProbeSequence());
    _probeFallbackTimer = Timer(widget.probeTimeout, () {
      if (!widget.backend.report.isComplete) {
        widget.backend.report.finalizePending('Timed out waiting for DA1');
      }
    });
  }

  void _selectTab(KttyProbeTab tab) {
    setState(() {
      _activeTab = tab;
    });
  }

  void _cycleKittyKeyboard() {
    _kbCycleIndex = (_kbCycleIndex + 1) % _kbFlagCycle.length;
    final flags = _requestedKbFlags;
    widget.backend.write('\x1b[=$flags;1u\x1b[?u');
    setState(() {
      _lastActionMessage =
          'Set Kitty Keyboard flags -> 0x${flags.toRadixString(16).padLeft(2, '0')} (CSI =$flags;1u)';
    });
  }

  void _toggleSgrPixels() {
    _sgrPixelsEnabled = !_sgrPixelsEnabled;
    widget.backend.interceptor.sgrPixelsRequested = _sgrPixelsEnabled;
    widget.backend.write(
      _sgrPixelsEnabled ? '\x1b[?1016h' : '\x1b[?1016l\x1b[?1006h',
    );
    widget.backend.write('\x1b[?1016\$p');
    setState(() {
      _lastActionMessage = _sgrPixelsEnabled
          ? 'Enabled SGR-Pixels mouse (?1016h)'
          : 'Switched to cell SGR mouse (?1016l + ?1006h)';
    });
  }

  void _toggleOcclusion() {
    setState(() {
      _showOcclusion = !_showOcclusion;
      _lastActionMessage =
          'Z-index cell occlusion overlay: ${_showOcclusion ? "ON" : "OFF"}';
    });
  }

  void _sendNotification() {
    _notifySeq++;
    final id = 'ktty$_notifySeq';
    final title = 'KTTY Probe #$_notifySeq';
    const body = 'OSC 99 chunked notification verified!';
    widget.backend.write(
      '\x1b]99;i=$id:d=0:p=title:a=report:c=1;$title\x1b\\'
      '\x1b]99;i=$id:d=1:p=body;$body\x1b\\',
    );
    setState(() {
      _lastActionMessage =
          'Sent OSC 99 "$title" (a=report:c=1 — click toast for ACK)';
    });
  }

  void _sendClipboard() {
    _clipboardSeq++;
    final payload = 'KTTY-OSC52-Check-#$_clipboardSeq';
    final encoded = base64Encode(utf8.encode(payload));
    widget.backend.write('\x1b]52;c;$encoded\x1b\\');
    setState(() {
      _lastActionMessage = 'Sent OSC 52 clipboard write "$payload"';
    });
  }

  void _cycleWindowTitle() {
    _titleSeq++;
    final title = 'KTTY Probe [Check #$_titleSeq]';
    widget.backend.write('\x1b]2;$title\x1b\\');
    setState(() {
      _lastActionMessage = 'Sent OSC 2 window title "$title"';
    });
  }

  void _emitPromptMarker() {
    _promptSeq++;
    widget.backend.write('\x1b]133;A\x1b\\\x1b]133;B\x1b\\');
    setState(() {
      _lastActionMessage = 'Sent OSC 133;A + 133;B prompt marker #$_promptSeq';
    });
  }

  bool _handleKeyEvent(term.KeyEvent event) {
    _recordKeyTelemetry(event);
    if (event.eventType == term.KeyEventType.release) {
      setState(() {});
      return true;
    }
    if (_dispatchShortcut(event)) return true;
    setState(() {});
    return true;
  }

  void _recordKeyTelemetry(term.KeyEvent event) {
    final kind = event.eventType.name.toUpperCase().padRight(7);
    final mods = event.modifiers.map((m) => m.name).join('+');
    final modStr = mods.isEmpty ? '' : '$mods+';
    final cpInfo = _formatCodepointExtras(event);
    final summary = '[$kind] $modStr${event.key} (${event.type.name})$cpInfo';
    _keyLog.insert(0, summary);
    if (_keyLog.length > 8) {
      _keyLog.removeRange(8, _keyLog.length);
    }
  }

  static String _formatCodepointExtras(term.KeyEvent event) {
    final parts = <String>[];
    if (event.shiftedCodepoint != null) {
      parts.add(
        'shifted=U+${event.shiftedCodepoint!.toRadixString(16).toUpperCase()}',
      );
    }
    if (event.baseLayoutCodepoint != null) {
      parts.add(
        'base=U+${event.baseLayoutCodepoint!.toRadixString(16).toUpperCase()}',
      );
    }
    return parts.isEmpty ? '' : ' [${parts.join(", ")}]';
  }

  bool _dispatchShortcut(term.KeyEvent event) {
    if (event.modifiers.contains(term.Modifier.control)) return false;
    switch (event.key) {
      case '1':
        _selectTab(.overview);
      case '2':
        _selectTab(.matrix);
      case '3':
        _selectTab(.graphicsAndSgr);
      case '4':
        _selectTab(.inputAndOsc);
      case 'r' || 'R':
        _triggerProbe();
      case 'k' || 'K':
        _cycleKittyKeyboard();
      case 'm' || 'M':
        _toggleSgrPixels();
      case 'o' || 'O':
        _toggleOcclusion();
      case 'n' || 'N':
        _sendNotification();
      case 'c' || 'C':
        _sendClipboard();
      case 't' || 'T':
        _cycleWindowTitle();
      case 'p' || 'P':
        _emitPromptMarker();
      case 'q' || 'Q':
        widget.onQuit();
      default:
        return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final viewState = KttyProbeViewState(
      report: widget.backend.report,
      activeTab: _activeTab,
      requestedKeyboardFlags: _requestedKbFlags,
      sgrPixelsEnabled: _sgrPixelsEnabled,
      showOcclusion: _showOcclusion,
      keyLog: _keyLog,
      lastActionMessage: _lastActionMessage,
    );
    final actions = KttyProbeActions(
      onSelectTab: _selectTab,
      onReprobe: _triggerProbe,
      onCycleKittyKeyboard: _cycleKittyKeyboard,
      onToggleSgrPixels: _toggleSgrPixels,
      onToggleOcclusion: _toggleOcclusion,
      onSendNotification: _sendNotification,
      onSendClipboard: _sendClipboard,
      onCycleWindowTitle: _cycleWindowTitle,
      onEmitPromptMarker: _emitPromptMarker,
      onQuit: widget.onQuit,
    );
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      wantsKeyReleaseEvents: (_requestedKbFlags & 2) != 0,
      onKeyEvent: _handleKeyEvent,
      child: KttyProbeDashboard(state: viewState, actions: actions),
    );
  }
}
