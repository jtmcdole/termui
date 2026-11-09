import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui_pty/termui_pty.dart';

import 'ktty_probe_app.dart';
import 'ktty_probe_report.dart';
import 'ktty_wire_backend.dart';

/// Host telemetry state observed on the outer [VirtualTerminal] wrapper.
final class VirtualTerminalHostTelemetry {
  /// Last `OSC 9` or `OSC 99` desktop notification intercepted by [VirtualTerminal].
  String lastNotification = 'None (press [N] inside probe)';

  /// Currently visible interactive `OSC 99` desktop notification toast, if any.
  Osc99Notification? activeNotification;

  /// Last `OSC 52` clipboard write intercepted by [VirtualTerminal].
  String lastClipboard = 'None (press [C] inside probe)';
}

(int width, int height) _resolveInnerSize(math.Point<int> rawHostSize) {
  final hostW = rawHostSize.x > 0 ? rawHostSize.x : 100;
  final hostH = rawHostSize.y > 0 ? rawHostSize.y : 32;
  return (math.max(40, hostW), math.max(12, hostH - 2));
}

VirtualTerminal _createConfiguredVirtualTerminal({
  required int width,
  required int height,
  required int cellPixelWidth,
  required int cellPixelHeight,
  required StreamController<List<int>> probeInput,
  required VirtualTerminalHostTelemetry telemetry,
  required term.Terminal hostTerminal,
}) {
  final vt = VirtualTerminal(
    width: width,
    height: height,
    cellPixelWidth: cellPixelWidth,
    cellPixelHeight: cellPixelHeight,
    maxScrollbackLines: 500,
    defaultForeground: const Color(220, 228, 240),
    defaultBackground: const Color(18, 22, 32),
    onReply: (reply) => _enqueueReply(probeInput, reply),
    onNotification: (title, message) {
      telemetry.lastNotification = title.isEmpty ? message : '$title: $message';
    },
  );
  vt.onOsc99Notification = (notification) {
    telemetry.activeNotification = notification;
  };
  vt.onClipboardWrite = (selection, text) {
    telemetry.lastClipboard = '[$selection] $text';
    hostTerminal.setClipboard(text);
  };
  vt.windowTitle = 'KTTY Probe';
  return vt;
}

void _enqueueReply(StreamController<List<int>> probeInput, String reply) {
  final bytes = utf8.encode(reply);
  scheduleMicrotask(() {
    if (!probeInput.isClosed) probeInput.add(bytes);
  });
}

bool _isHostExitShortcut(term.KeyEvent event) {
  if (event.eventType == term.KeyEventType.release) return false;
  return event.logicalKey == TermKey.controlC ||
      event.logicalKey == TermKey.controlQ;
}

/// Runs the standalone KTTY Probe program inside an in-memory [VirtualTerminal]
/// rendered via [TerminalView] onto [hostTerminal].
///
/// Every probe query (`APC`, `CSI ? u`, `XTVERSION`, `DECRQM`, `OSC 10/11`,
/// `DA1`/`DA2`) and rendered frame (`U+10EEEE` placeholders, extended SGR,
/// `OSC 8`, `OSC 52`, `OSC 99`, `OSC 133`) traverses [VirtualTerminal]'s real
/// ANSI/VT wire parser and reply pipeline.
Future<KttyProbeReport> runVirtualTerminalKttyProbe(
  term.Terminal hostTerminal, {
  void Function(Buffer)? onFrameRedrawn,
  int cellPixelWidth = 9,
  int cellPixelHeight = 18,
  Stream<(int, int)>? cellPixelSizeChanges,
}) async {
  final (innerW, innerH) = _resolveInnerSize(hostTerminal.backend.size);
  final probeInput = StreamController<List<int>>.broadcast();
  final telemetry = VirtualTerminalHostTelemetry();
  final report = KttyProbeReport()
    ..cellPixelWidth = cellPixelWidth
    ..cellPixelHeight = cellPixelHeight;

  final virtualTerminal = _createConfiguredVirtualTerminal(
    width: innerW,
    height: innerH,
    cellPixelWidth: cellPixelWidth,
    cellPixelHeight: cellPixelHeight,
    probeInput: probeInput,
    telemetry: telemetry,
    hostTerminal: hostTerminal,
  );

  final wireBackend = KttyWireTerminalBackend(
    wireInput: probeInput.stream,
    onWriteWire: virtualTerminal.writeString,
    report: report,
    initialSize: math.Point<int>(innerW, innerH),
  );

  final hostScene = SceneManager(hostTerminal, renderingMode: .alternateScreen)
    ..enableMouseTracking = true
    ..onFrameRedrawn = onFrameRedrawn;

  hostTerminal
    ..enterAlternateScreen()
    ..hideCursor()
    ..enableMouseTracking()
    ..enableBracketedPaste();

  final vtFocusNode = FocusNode(id: 'ktty_vt_view');
  final hostRunner = _mountHostRunner(
    hostTerminal: hostTerminal,
    hostScene: hostScene,
    virtualTerminal: virtualTerminal,
    telemetry: telemetry,
    focusNode: vtFocusNode,
    probeInput: probeInput,
  );

  final sizeSub = _bindHostResize(hostTerminal, virtualTerminal, wireBackend);
  final cellPxSub = cellPixelSizeChanges?.listen((next) {
    virtualTerminal.setCellPixelSize(next.$1, next.$2);
    report.recordCellPixelSize(next.$1, next.$2);
  });
  final stopHandle = KttyProbeStopHandle();
  hostScene.onKeyEvent = (event) {
    if (!_isHostExitShortcut(event)) return false;
    stopHandle.stop();
    return true;
  };

  try {
    return await runKttyProbeOnWire(wireBackend, stopHandle: stopHandle);
  } finally {
    if (cellPxSub != null) unawaited(cellPxSub.cancel());
    unawaited(sizeSub.cancel());
    if (!probeInput.isClosed) unawaited(probeInput.close());
    hostRunner.abort();
    hostScene.dispose();
    vtFocusNode.dispose();
    virtualTerminal.dispose();
    _restoreHostTerminal(hostTerminal);
  }
}

PromptRunner<void> _mountHostRunner({
  required term.Terminal hostTerminal,
  required SceneManager hostScene,
  required VirtualTerminal virtualTerminal,
  required VirtualTerminalHostTelemetry telemetry,
  required FocusNode focusNode,
  required StreamController<List<int>> probeInput,
}) {
  final hostRunner = PromptRunner<void>(
    terminal: hostTerminal,
    widget: _VirtualTerminalProbeShell(
      hostTerminal: hostTerminal,
      virtualTerminal: virtualTerminal,
      telemetry: telemetry,
      focusNode: focusNode,
      onEncodedInput: (encoded) {
        if (!probeInput.isClosed) probeInput.add(utf8.encode(encoded));
      },
    ),
    alternateScreen: false,
    mode: .managed,
    onFramePainted: (_) => hostScene.scheduleRender(),
  );

  final shellLayer = SceneLayer(
    renderer: hostRunner,
    sizing: .fullscreen,
    zIndex: 10,
  );
  hostScene.layers.add(shellLayer);
  hostScene.focusedLayer = shellLayer;
  unawaited(hostRunner.run().catchError((Object _) {}));
  return hostRunner;
}

StreamSubscription<math.Point<int>> _bindHostResize(
  term.Terminal hostTerminal,
  VirtualTerminal virtualTerminal,
  KttyWireTerminalBackend wireBackend,
) {
  return hostTerminal.watchSize().listen((next) {
    if (next.x <= 0 || next.y <= 0) return;
    final (w, h) = _resolveInnerSize(next);
    virtualTerminal.resize(w, h);
    wireBackend.updateSize(w, h);
  });
}

void _restoreHostTerminal(term.Terminal hostTerminal) {
  hostTerminal.backend.write('\x1b[=0;1u\x1b[?1016l');
  hostTerminal
    ..exitAlternateScreen()
    ..showCursor()
    ..disableBracketedPaste()
    ..disableMouseTracking()
    ..resetStyle();
}

final class _VirtualTerminalProbeShell extends StatefulWidget {
  final term.Terminal hostTerminal;
  final VirtualTerminal virtualTerminal;
  final VirtualTerminalHostTelemetry telemetry;
  final FocusNode focusNode;
  final void Function(String encoded) onEncodedInput;

  const _VirtualTerminalProbeShell({
    required this.hostTerminal,
    required this.virtualTerminal,
    required this.telemetry,
    required this.focusNode,
    required this.onEncodedInput,
  });

  @override
  State<_VirtualTerminalProbeShell> createState() =>
      _VirtualTerminalProbeShellState();
}

final class _VirtualTerminalProbeShellState
    extends State<_VirtualTerminalProbeShell> {
  bool? _lastSyncedSgrPixels;
  int? _lastSyncedKittyKbFlags;

  @override
  void initState() {
    super.initState();
    widget.virtualTerminal.addListener(_onVtChanged);
    _syncHostProtocols();
  }

  @override
  void dispose() {
    widget.virtualTerminal.removeListener(_onVtChanged);
    super.dispose();
  }

  void _syncHostProtocols() {
    final nextPixels = widget.virtualTerminal.sgrPixelsMouseMode;
    if (_lastSyncedSgrPixels != nextPixels) {
      _lastSyncedSgrPixels = nextPixels;
      widget.hostTerminal.backend.write(
        nextPixels ? '\x1b[?1016h' : '\x1b[?1016l',
      );
    }
    final nextKbFlags = widget.virtualTerminal.kittyKeyboardFlags;
    if (_lastSyncedKittyKbFlags != nextKbFlags) {
      _lastSyncedKittyKbFlags = nextKbFlags;
      widget.hostTerminal.backend.write('\x1b[=$nextKbFlags;1u');
    }
  }

  void _onVtChanged() {
    _syncHostProtocols();
    if (mounted) setState(() {});
  }

  void _activateNotification(Osc99Notification notification) {
    widget.virtualTerminal.reportNotificationActivated(notification.id);
    widget.telemetry.activeNotification = null;
    widget.telemetry.lastNotification =
        '${notification.title}: ${notification.body} [ACK sent]';
    widget.focusNode.requestFocus();
    if (mounted) setState(() {});
  }

  void _dismissNotification(Osc99Notification notification) {
    widget.virtualTerminal.reportNotificationClosed(notification.id);
    widget.telemetry.activeNotification = null;
    widget.telemetry.lastNotification =
        '${notification.title}: ${notification.body} [Closed]';
    widget.focusNode.requestFocus();
    if (mounted) setState(() {});
  }

  Widget _buildViewportArea(BoxConstraints constraints) {
    final notif = widget.telemetry.activeNotification;
    final showToast =
        notif != null &&
        constraints.maxWidth >= 50 &&
        constraints.maxHeight >= 9;
    return Stack([
      Positioned(
        left: 0,
        top: 0,
        right: 0,
        bottom: 0,
        child: TerminalView(
          terminal: widget.virtualTerminal,
          focusNode: widget.focusNode,
          autofocus: true,
          onInput: widget.onEncodedInput,
        ),
      ),
      if (showToast)
        Positioned(
          right: 2,
          top: 1,
          width: 46,
          height: 5,
          child: _buildNotificationToast(notif),
        ),
    ]);
  }

  Widget _buildNotificationToast(Osc99Notification notif) {
    return DecoratedBox(
      decoration: BoxDecoration(
        backgroundColor: CharmColors.pepper,
        border: Border.all(const Style(foreground: CharmColors.dolly)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Column([
          SizedBox(
            height: 1,
            child: Text(
              'OSC 99 Toast [id=${notif.id}] — ${notif.title}',
              style: const Style(
                foreground: CharmColors.dolly,
                background: CharmColors.pepper,
                modifiers: Modifier.bold,
              ),
            ),
          ),
          SizedBox(
            height: 1,
            child: Text(
              notif.body,
              style: const Style(
                foreground: CharmColors.salt,
                background: CharmColors.pepper,
              ),
            ),
          ),
          SizedBox(
            height: 1,
            child: Row([
              Button(
                text: ' [Activate (ACK)] ',
                onPressed: () => _activateNotification(notif),
                style: const Style(
                  foreground: CharmColors.pepper,
                  background: CharmColors.julep,
                  modifiers: Modifier.bold,
                ),
              ),
              const SizedBox(width: 2, child: Text('')),
              Button(
                text: ' [Dismiss] ',
                onPressed: () => _dismissNotification(notif),
                style: const Style(
                  foreground: CharmColors.salt,
                  background: CharmColors.charple,
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vt = widget.virtualTerminal;
    final kbHex =
        '0x${vt.kittyKeyboardFlags.toRadixString(16).padLeft(2, '0')}';
    final imgCount = vt.imageRegistry.registeredImageIds.length;
    final pxMode = vt.sgrPixelsMouseMode ? 'ON' : 'OFF';
    final title = vt.windowTitle.isEmpty ? '(untitled)' : vt.windowTitle;

    return LayoutBuilder(
      builder: (context, constraints) => Column([
        if (constraints.maxHeight >= 1)
          SizedBox(
            height: 1,
            child: RichText(
              wrap: false,
              text: TextSpan(
                children: [
                  const TextSpan(
                    text: ' VirtualTerminal Wrapper ',
                    style: Style(
                      foreground: CharmColors.pepper,
                      background: CharmColors.charple,
                      modifiers: Modifier.bold,
                    ),
                  ),
                  TextSpan(
                    text:
                        ' Title: "$title" │ KbFlags: $kbHex │ ?1016: $pxMode │ Images: $imgCount │ Zone: ${vt.promptZone.name} ',
                    style: const Style(foreground: CharmColors.salt),
                  ),
                ],
              ),
            ),
          ),
        if (constraints.maxHeight >= 2)
          SizedBox(
            height: 1,
            child: RichText(
              wrap: false,
              text: TextSpan(
                children: [
                  TextSpan(
                    text: ' OSC99: ${widget.telemetry.lastNotification} ',
                    style: const Style(foreground: CharmColors.dolly),
                  ),
                  TextSpan(
                    text: '│ OSC52: ${widget.telemetry.lastClipboard}',
                    style: const Style(foreground: CharmColors.julep),
                  ),
                ],
              ),
            ),
          ),
        if (constraints.maxHeight >= 3)
          Expanded(child: _buildViewportArea(constraints)),
      ]),
    );
  }
}
