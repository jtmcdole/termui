import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/workspace/fterm_pane_controller.dart';
import 'package:fterm/src/workspace/local_host_driver_io.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart'
    show TerminalColorResolver, TerminalThemeSettings;
import 'package:termui_pty/termui_pty.dart';

void main() {
  test(
    'IoLocalHostDriver exposes VirtualTerminal.isRowWrapped and FtermPaneController.lookupLinkLine resolves wrapped live & scrollback rows',
    () async {
      final backend = _InMemoryRoutedPtyBackend();
      final driver = IoLocalHostDriver(
        backendFactory:
            ({
              required executable,
              required arguments,
              required initialCols,
              required initialRows,
              required pixelWidth,
              required pixelHeight,
              workingDirectory,
              environment,
            }) => backend,
        isWindows: false,
      );
      addTearDown(driver.dispose);

      final host = await driver.openShell(
        const LocalShellConfig(
          executable: '/bin/sh',
          initialCols: 20,
          initialRows: 4,
        ),
      );
      final pane = FtermPaneController(
        paneId: 'local-1',
        port: host.port,
        localHost: host,
        colorResolver: TerminalColorResolver(
          settings: const TerminalThemeSettings(),
          theme: tui.TerminalColorTheme.termuiDark,
        ),
        resizeDebounce: Duration.zero,
      );
      addTearDown(() => pane.dispose(disposePort: false));

      // Emit 3 lines into scrollback, then a 31-char URL that soft-wraps across live rows.
      backend.emitText(
        'line0\r\nline1\r\nline2\r\nhttps://example.com/wrapped-url',
      );
      await Future<void>.delayed(Duration.zero);

      var wrappedRow = -1;
      for (var r = 0; r < 4; r++) {
        if (host.isLiveRowWrapped(r)) {
          wrappedRow = r;
          break;
        }
      }
      expect(wrappedRow, greaterThan(0));
      expect(pane.lookupLinkLine(wrappedRow)?.isWrapped, isTrue);

      final detail = tui.TerminalSelectionController.resolveLinkSpanDetailAt(
        lookup: pane.lookupLinkLine,
        col: 2,
        virtualRow: wrappedRow,
      );
      expect(detail?.link.uri, equals('https://example.com/wrapped-url'));

      // Negative viewportRow resolves scrollback lines above the visible viewport.
      expect(pane.topVirtualRow, greaterThan(0));
      expect(pane.lookupLinkLine(-1), isNotNull);
    },
  );
}

final class _InMemoryRoutedPtyBackend implements RoutedPtyBackend {
  final StreamController<Uint8List> _output =
      StreamController<Uint8List>.broadcast();
  final Completer<int> _exit = Completer<int>();

  void emitText(String text) {
    if (!_output.isClosed) {
      _output.add(Uint8List.fromList(text.codeUnits));
    }
  }

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void write(Uint8List bytes) {}

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  void kill() {
    if (!_exit.isCompleted) _exit.complete(0);
  }

  @override
  Future<void> dispose() async {
    kill();
    await _output.close();
  }
}
