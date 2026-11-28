import 'dart:async';
import 'dart:convert';

import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;

import 'ktty_probe_assets.dart';
import 'ktty_probe_report.dart';
import 'ktty_probe_widgets.dart';
import 'ktty_reply_interceptor.dart';
import 'ktty_wire_backend.dart';

/// Runs a non-interactive capability probe over [wireInput] and [onWriteWire],
/// completing as soon as the `DA1` sentinel arrives, [stopHandle] stops, or
/// [timeout] elapses.
Future<KttyProbeReport> runKttyBatchProbe({
  required Stream<List<int>> wireInput,
  required void Function(String data) onWriteWire,
  Duration timeout = const Duration(milliseconds: 500),
  KttyProbeOptions options = const KttyProbeOptions(),
  KttyProbeStopHandle? stopHandle,
}) async {
  final report = KttyProbeReport()..resetForNewProbe(options: options);
  final interceptor = KttyReplyInterceptor(report);
  final done = Completer<void>();

  void checkComplete() {
    if (report.isComplete && !done.isCompleted) {
      done.complete();
    }
  }

  void finalizeAndComplete(String reason) {
    if (done.isCompleted) return;
    report.finalizePending(reason);
    if (!done.isCompleted) {
      done.complete();
    }
  }

  report.addListener(checkComplete);
  stopHandle?._attach(() => finalizeAndComplete('Aborted before DA1'));
  final sub = wireInput.listen((chunk) {
    interceptor.processChunk(chunk);
  });
  final timer = Timer(timeout, () {
    finalizeAndComplete('Timed out waiting for DA1');
  });

  if (!done.isCompleted) {
    onWriteWire(KttyProbeReport.buildWireProbeSequence(options: options));
  }
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

bool _bufferContainsKittyImageId(Buffer buffer, int imageId) {
  final targetRgb = imageId & 0xFFFFFF;
  final count = buffer.width * buffer.height;
  for (var i = 0; i < count; i++) {
    final mods = buffer.attributes[i * 3 + 2];
    if ((mods & Modifier.kittyPlaceholder) == 0) continue;
    final fg = buffer.attributes[i * 3];
    if ((fg & 0xFFFFFF) == targetRgb) return true;
  }
  return false;
}

final class _ExtendedPlacementEmitter {
  final KttyWireTerminalBackend backend;
  final bool wrapTmux;
  String _shorthandSig = '';
  String _animatedSig = '';

  _ExtendedPlacementEmitter(this.backend, {required this.wrapTmux});

  void emitIfUploaded(Buffer frame) {
    _emitShorthandIfUploaded(frame);
    _emitAnimatedIfUploaded(frame);
  }

  void _emitShorthandIfUploaded(Buffer frame) {
    if (!_bufferContainsKittyImageId(frame, kttyVisualShorthandImageId)) return;
    final data = KittyImageRegistry.global.lookupImage(
      kttyVisualShorthandImageId,
    );
    if (data == null) return;
    final sig = '${data.version}:${data.gridCols}x${data.gridRows}';
    if (sig == _shorthandSig) return;
    _shorthandSig = sig;
    _writeApcSequence(
      backend,
      buildShorthandPlacementApcCommands(
        cols: data.gridCols,
        rows: data.gridRows,
      ),
      wrapTmux: wrapTmux,
    );
  }

  void _emitAnimatedIfUploaded(Buffer frame) {
    if (!_bufferContainsKittyImageId(frame, kttyVisualAnimatedImageId)) return;
    final anim = KittyImageRegistry.global.lookupAnimation(
      kttyVisualAnimatedImageId,
    );
    if (anim == null || anim.frames.length < 2) return;
    final f2 = anim.frames[1].imageData;
    final sig = '${f2.version}:${f2.gridCols}x${f2.gridRows}';
    if (sig == _animatedSig) return;
    _animatedSig = sig;
    _writeApcSequence(
      backend,
      buildAnimatedTileApcCommands(f2, frameGapMs: anim.frames[1].gapMs),
      wrapTmux: wrapTmux,
    );
  }
}

String _formatHeaderSliceRestoreAnsi(Buffer frame) {
  final sb = StringBuffer('\x1b[1;1H');
  for (var x = 0; x < 2; x++) {
    final attrIdx = x * 3;
    final fg = frame.attributes[attrIdx];
    final bg = frame.attributes[attrIdx + 1];
    final mods = frame.attributes[attrIdx + 2];
    sb.write('\x1b[0');
    if ((mods & Modifier.bold) != 0) sb.write(';1');
    if (fg != 0) {
      sb.write(';38;2;${(fg >>> 16) & 0xFF};${(fg >>> 8) & 0xFF};${fg & 0xFF}');
    }
    if (bg != 0) {
      sb.write(';48;2;${(bg >>> 16) & 0xFF};${(bg >>> 8) & 0xFF};${bg & 0xFF}');
    }
    sb
      ..write('m')
      ..write(frame.getCharacter(x, 0));
  }
  sb.write('\x1b[0m');
  return sb.toString();
}

/// Runs the interactive KTTY Probe & Check TUI over a [KttyWireTerminalBackend].
Future<KttyProbeReport> runKttyProbeOnWire(
  KttyWireTerminalBackend backend, {
  Duration probeTimeout = const Duration(milliseconds: 600),
  KttyProbeStopHandle? stopHandle,
  KttyProbeOptions options = const KttyProbeOptions(),
  FutureOr<String?> Function(String reportJson)? onExportReport,
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
  backend.write('\x1b[?1004h\x1b[>11u\x1b[?1016h\x1b[?2031h');

  final placementEmitter = _ExtendedPlacementEmitter(
    backend,
    wrapTmux: options.wrapTmuxPassthrough,
  );
  Buffer? lastPaintedFrame;

  void restoreHeaderProbeCells() {
    final frame = lastPaintedFrame;
    if (frame == null || frame.width < 2 || frame.height < 1) return;
    backend.write(_formatHeaderSliceRestoreAnsi(frame));
    sceneManager.scheduleRender();
  }

  late final PromptRunner<void> runner;
  runner = PromptRunner<void>(
    terminal: terminal,
    widget: KttyProbeStatefulRoot(
      backend: backend,
      terminal: terminal,
      probeTimeout: probeTimeout,
      onQuit: requestQuit,
      options: options,
      onExportReport: onExportReport,
      onAfterReprobe: restoreHeaderProbeCells,
    ),
    alternateScreen: false,
    mode: .managed,
    onFramePainted: (frame) {
      lastPaintedFrame = frame;
      sceneManager.scheduleRender();
      scheduleMicrotask(() {
        if (!exitCompleter.isCompleted) placementEmitter.emitIfUploaded(frame);
      });
    },
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
    _writeApcSequence(
      backend,
      '\x1b_Ga=d,d=I,i=$kttyVisualAnimatedImageId,q=2\x1b\\',
      wrapTmux: options.wrapTmuxPassthrough,
    );
    backend.write(
      '\x1b[<u\x1b[?2031l\x1b[?1016l\x1b[?1004l\x1b[?2004l'
      '\x1b[?1003l\x1b[?1006l\x1b[?1049l\x1b[?25h\x1b[0m',
    );
    terminal.dispose();
  }
  return backend.report;
}

final RegExp _singleApcCommandRegex = RegExp(r'\x1b_G[^\x1b]*\x1b\\');

void _writeApcSequence(
  KttyWireTerminalBackend backend,
  String sequence, {
  required bool wrapTmux,
}) {
  if (!wrapTmux) {
    backend.write(sequence);
    return;
  }
  final matches = _singleApcCommandRegex.allMatches(sequence).toList();
  if (matches.isEmpty) {
    backend.write(wrapTmuxDcsPassthrough(sequence));
    return;
  }
  final sb = StringBuffer();
  for (final match in matches) {
    sb.write(wrapTmuxDcsPassthrough(match.group(0)!));
  }
  backend.write(sb.toString());
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

  /// Optional wire-level probe options (e.g. tmux passthrough or local media).
  final KttyProbeOptions options;

  /// Optional Web-safe callback exporting the serialized JSON report.
  final FutureOr<String?> Function(String reportJson)? onExportReport;

  /// Optional hook invoked after an interactive re-probe to restore probed header cells.
  final void Function()? onAfterReprobe;

  /// Creates a [KttyProbeStatefulRoot].
  const KttyProbeStatefulRoot({
    super.key,
    required this.backend,
    required this.terminal,
    required this.probeTimeout,
    required this.onQuit,
    this.options = const KttyProbeOptions(),
    this.onExportReport,
    this.onAfterReprobe,
  });

  @override
  State<KttyProbeStatefulRoot> createState() => _KttyProbeStatefulRootState();
}

final class _KttyProbeStatefulRootState extends State<KttyProbeStatefulRoot> {
  static const List<int> _kbFlagCycle = [11, 31, 15, 3, 1, 0];

  final FocusNode _focusNode = FocusNode(id: 'ktty_probe_root');
  final List<String> _keyLog = [
    'Press or release any key to inspect Kitty CSI u telemetry',
  ];

  KttyProbeTab _activeTab = .overview;
  int _kbCycleIndex = 0;
  bool _sgrPixelsEnabled = true;
  bool _showOcclusion = true;
  bool _deleteFreeDataNext = false;
  String? _deleteModeLabel;
  String? _hoveredCursorShape;
  int _notifySeq = 0;
  int _clipboardSeq = 0;
  int _titleSeq = 0;
  int _promptSeq = 0;
  String _lastActionMessage =
      'Ready — press [D] DelMode, [N] OSC99, [C] OSC52, [E] Export, [P] Copy';
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
    if (_hoveredCursorShape != null) {
      widget.backend.write('\x1b]22;<\x1b\\');
      _hoveredCursorShape = null;
    }
    _probeFallbackTimer?.cancel();
    widget.backend.report.removeListener(_onReportUpdated);
    _focusNode.dispose();
    super.dispose();
  }

  void _onReportUpdated() {
    if (mounted) setState(() {});
  }

  void _writeApc(String sequence) {
    _writeApcSequence(
      widget.backend,
      sequence,
      wrapTmux: widget.options.wrapTmuxPassthrough,
    );
  }

  void _triggerProbe() {
    _probeFallbackTimer?.cancel();
    widget.backend.report.resetForNewProbe(options: widget.options);
    widget.backend.write('\x1b[1;1H');
    widget.backend.write(
      KttyProbeReport.buildWireProbeSequence(options: widget.options),
    );
    widget.onAfterReprobe?.call();
    _probeFallbackTimer = Timer(widget.probeTimeout, () {
      if (!widget.backend.report.isComplete) {
        widget.backend.report.finalizePending('Timed out waiting for DA1');
      }
    });
  }

  void _handleHoverCursorShape(String? shape) {
    if (shape == _hoveredCursorShape) return;
    if (_hoveredCursorShape != null) {
      widget.backend.write('\x1b]22;<\x1b\\');
    }
    _hoveredCursorShape = shape;
    if (shape != null) {
      widget.backend.write('\x1b]22;>$shape\x1b\\');
    }
    if (mounted) {
      setState(() {
        _lastActionMessage = shape == null
            ? 'Popped OSC 22 hover cursor (OSC 22;<)'
            : 'Pushed OSC 22 hover cursor "$shape" (OSC 22;>$shape)';
      });
    }
  }

  void _selectTab(KttyProbeTab tab) {
    if (_hoveredCursorShape != null) {
      widget.backend.write('\x1b]22;<\x1b\\');
      _hoveredCursorShape = null;
    }
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

  void _cycleDeleteMode() {
    final freeData = _deleteFreeDataNext;
    _deleteFreeDataNext = !freeData;
    final mode = freeData ? 'A' : 'a';
    _writeApc('\x1b_Ga=d,d=$mode,q=2\x1b\\');
    setState(() {
      _deleteModeLabel = 'd=$mode';
      _lastActionMessage = freeData
          ? 'Sent Kitty delete a=d,d=A,q=2 (frees unreferenced images)'
          : 'Sent Kitty delete a=d,d=a,q=2 (clears direct placements, keeps U=1)';
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

  String _serializeReportJson() => const JsonEncoder.withIndent(
    '  ',
  ).convert(widget.backend.report.toJsonMap());

  void _copyReportToClipboard() {
    final jsonText = _serializeReportJson();
    final utf8Bytes = utf8.encode(jsonText);
    final encoded = base64Encode(utf8Bytes);
    widget.backend.write('\x1b]52;c;$encoded\x1b\\');
    setState(() {
      _lastActionMessage =
          'Copied JSON report via OSC 52 (${utf8Bytes.length} bytes)';
    });
  }

  void _setExportSuccess(String? dest) {
    if (!mounted) return;
    setState(() {
      _lastActionMessage = dest == null
          ? 'Exported JSON report'
          : 'Exported JSON report -> $dest';
    });
  }

  void _setExportError(Object error) {
    if (!mounted) return;
    setState(() {
      _lastActionMessage = 'Export failed: $error';
    });
  }

  void _exportReport() {
    final callback = widget.onExportReport;
    if (callback == null) {
      setState(() {
        _lastActionMessage =
            'Export sink unavailable on this host (use [P:Copy])';
      });
      return;
    }
    final jsonText = _serializeReportJson();
    try {
      final result = callback(jsonText);
      if (result is Future<String?>) {
        unawaited(result.then(_setExportSuccess, onError: _setExportError));
      } else {
        _setExportSuccess(result);
      }
    } on Object catch (error) {
      _setExportError(error);
    }
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
      case 'd' || 'D':
        _cycleDeleteMode();
      case 'n' || 'N':
        _sendNotification();
      case 'c' || 'C':
        _sendClipboard();
      case 't' || 'T':
        _cycleWindowTitle();
      case 's' || 'S':
        _emitPromptMarker();
      case 'e' || 'E':
        _exportReport();
      case 'p' || 'P':
        _copyReportToClipboard();
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
      deleteModeLabel: _deleteModeLabel,
      hoveredCursorShape: _hoveredCursorShape,
    );
    final actions = KttyProbeActions(
      onSelectTab: _selectTab,
      onReprobe: _triggerProbe,
      onCycleKittyKeyboard: _cycleKittyKeyboard,
      onToggleSgrPixels: _toggleSgrPixels,
      onToggleOcclusion: _toggleOcclusion,
      onCycleDeleteMode: _cycleDeleteMode,
      onSendNotification: _sendNotification,
      onSendClipboard: _sendClipboard,
      onCycleWindowTitle: _cycleWindowTitle,
      onEmitPromptMarker: _emitPromptMarker,
      onExportReport: _exportReport,
      onCopyReport: _copyReportToClipboard,
      onHoverCursorShape: _handleHoverCursorShape,
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
