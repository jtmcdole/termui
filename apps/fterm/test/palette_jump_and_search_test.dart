import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/shader_editor/shader_editor_controller.dart';
import 'package:fterm/src/ui/palette/palette_scrollback_jump.dart';
import 'package:fterm/src/ui/palette/palette_text_search.dart';
import 'package:fterm/src/workspace/fterm_pane_controller.dart';
import 'package:fterm/src/workspace/local_host_driver_io.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_flutter/termui_flutter.dart'
    show TerminalSearchHighlight;
import 'package:termui_pty/termui_pty.dart';

void main() {
  group('Scrollback jump (:) — terminal pane', () {
    test('resolves :1..N, :-N, percentages, :top, :bottom, :0, and clamping with evicted scrollback', () {
      final port = _TestTerminalPort(cols: 40, rows: 10)
        ..oldestScrollbackLine = 50
        ..scrollbackRows = <ScrollbackLine>[
          for (var i = 0; i < 40; i++)
            _makeScrollbackLine(40, 'hist-${50 + i}'),
        ];
      for (var r = 0; r < 10; r++) {
        port.writeLiveRow(r, 'live-$r');
      }
      final pane = _makePane(port);
      addTearDown(() {
        pane.dispose(disposePort: false);
        unawaited(port.dispose());
      });

      // Retained range: oldest=50, total=90+10=100 -> 50 total lines (1..50).
      expect(pane.oldestVirtualRow, 50);
      expect(pane.totalVirtualLines, 100);
      expect(pane.retainedScrollbackLines, 40);

      final first = resolveTerminalScrollbackJump(pane, '1');
      expect(first.directTarget?.targetVirtualRow, 50);
      expect(first.directTarget?.subtitle, contains('hist-50'));
      expect(
        first.candidates,
        equals(<ScrollbackJumpCandidate>[first.directTarget!]),
      );

      final tenth = resolveTerminalScrollbackJump(pane, '10');
      expect(tenth.directTarget?.targetVirtualRow, 59);
      expect(tenth.directTarget?.subtitle, contains('hist-59'));

      final lastLive = resolveTerminalScrollbackJump(pane, '50');
      expect(lastLive.directTarget?.targetVirtualRow, 99);
      expect(lastLive.directTarget?.subtitle, contains('live-9'));

      // Out-of-range positive line clamps to totalVirtualLines - 1.
      final clampedHigh = resolveTerminalScrollbackJump(pane, '9999');
      expect(clampedHigh.directTarget?.targetVirtualRow, 99);

      // Negative offsets from live bottom.
      final relLast = resolveTerminalScrollbackJump(pane, '-1');
      expect(relLast.directTarget?.targetVirtualRow, 99);

      final relTen = resolveTerminalScrollbackJump(pane, '-10');
      expect(relTen.directTarget?.targetVirtualRow, 90);
      expect(relTen.directTarget?.subtitle, contains('live-0'));

      final relZero = resolveTerminalScrollbackJump(pane, '-0');
      expect(relZero.directTarget?.targetVirtualRow, 99);

      final clampedLow = resolveTerminalScrollbackJump(pane, '-500');
      expect(clampedLow.directTarget?.targetVirtualRow, 50);

      // Percentages: 0%, 50%, 100%, and out-of-range clamping.
      final pct0 = resolveTerminalScrollbackJump(pane, '0%');
      expect(pct0.directTarget?.targetVirtualRow, 50);

      final pct50 = resolveTerminalScrollbackJump(pane, '50%');
      // 50 + ((99 - 50) * 0.5).round() = 50 + 25 = 75.
      expect(pct50.directTarget?.targetVirtualRow, 75);

      final pct100 = resolveTerminalScrollbackJump(pane, '100%');
      expect(pct100.directTarget?.targetVirtualRow, 99);

      final pctOver = resolveTerminalScrollbackJump(pane, '180%');
      expect(pctOver.directTarget?.targetVirtualRow, 99);

      // Keywords: top, bottom, 0 (case-insensitive & trimmed).
      final top = resolveTerminalScrollbackJump(pane, '  TOP ');
      expect(top.directTarget?.targetVirtualRow, 50);
      expect(top.directTarget?.isLandmark, isTrue);

      final bottom = resolveTerminalScrollbackJump(pane, 'Bottom');
      expect(bottom.directTarget?.targetVirtualRow, 99);
      expect(bottom.directTarget?.isLandmark, isTrue);

      final zero = resolveTerminalScrollbackJump(pane, '0');
      expect(zero.directTarget?.targetVirtualRow, 50);
      expect(zero.directTarget?.isLandmark, isTrue);
    });

    test(
      'scrollToVirtualRow centers target row in viewport and clamps cleanly',
      () {
        final port = _TestTerminalPort(cols: 40, rows: 10)
          ..oldestScrollbackLine = 50
          ..scrollbackRows = <ScrollbackLine>[
            for (var i = 0; i < 40; i++)
              _makeScrollbackLine(40, 'hist-${50 + i}'),
          ];
        final pane = _makePane(port);
        addTearDown(() {
          pane.dispose(disposePort: false);
          unawaited(port.dispose());
        });

        // sbWin.totalLines = 90, liveHeight = 10, retained = 40.
        // Centering row 75: targetTop = 75 - 5 = 70 -> offset = 90 - 70 = 20.
        pane.scrollToVirtualRow(75);
        expect(pane.scrollOffsetLines, 20);
        expect(pane.topVirtualRow, 70);

        // Without centering: targetTop = 75 -> offset = 90 - 75 = 15.
        pane.scrollToVirtualRow(75, centerInViewport: false);
        expect(pane.scrollOffsetLines, 15);
        expect(pane.topVirtualRow, 75);

        // Near oldest retained row clamps to retainedScrollbackLines (40).
        pane.scrollToVirtualRow(50);
        expect(pane.scrollOffsetLines, 40);
        expect(pane.topVirtualRow, 50);

        // Near live bottom clamps to 0.
        pane.scrollToVirtualRow(99);
        expect(pane.scrollOffsetLines, 0);
        expect(pane.topVirtualRow, 90);
      },
    );

    test('lists landmarks and reverse-chronological OSC 133 prompts with fuzzy filtering', () {
      final port = _TestTerminalPort(cols: 60, rows: 4)
        ..oldestScrollbackLine = 10
        ..scrollbackRows = <ScrollbackLine>[
          _makeScrollbackLine(60, r'$ echo hello'),
          _makeScrollbackLine(60, 'hello'),
          _makeScrollbackLine(60, r'$ git status --short'),
          _makeScrollbackLine(60, 'M lib/app.dart'),
          _makeScrollbackLine(60, r'$ flutter test'),
          _makeScrollbackLine(60, 'All tests passed'),
        ];
      port.writeLiveRow(0, r'$ dart analyze');
      // Include an evicted prompt (row 4 < oldest 10) to verify filtering.
      final host = _FakePromptHost(
        port: port,
        promptLines: <int>[4, 10, 12, 14, 16],
      );
      final pane = _makePane(port, localHost: host);
      addTearDown(() {
        pane.dispose(disposePort: false);
        unawaited(host.dispose());
      });

      final browse = resolveTerminalScrollbackJump(pane, '');
      expect(browse.directTarget, isNull);
      expect(browse.candidates.length, 6);
      expect(browse.candidates[0].title, 'Live Bottom');
      expect(browse.candidates[0].isLandmark, isTrue);
      expect(browse.candidates[1].title, 'Top of Scrollback');
      expect(browse.candidates[1].isLandmark, isTrue);
      // Reverse-chronological prompts (newest first, evicted row 4 excluded).
      expect(
        browse.candidates.skip(2).map((c) => c.targetVirtualRow).toList(),
        equals(<int>[16, 14, 12, 10]),
      );
      expect(browse.candidates[2].title, r'$ dart analyze');
      expect(browse.candidates[3].title, r'$ flutter test');

      // Fuzzy filter against prompts.
      final filtered = resolveTerminalScrollbackJump(pane, 'gstat');
      expect(filtered.directTarget, isNull);
      expect(filtered.candidates, hasLength(1));
      final match = filtered.candidates.single;
      expect(match.targetVirtualRow, 12);
      expect(match.title, r'$ git status --short');
      expect(match.matchedIndices, isNotEmpty);
      final chars = match.title.characters.toList();
      final matchedChars = <String>[
        for (final idx in match.matchedIndices) chars[idx].toLowerCase(),
      ].join();
      expect(matchedChars, 'gstat');

      // Non-matching text returns empty list with statusHint.
      final none = resolveTerminalScrollbackJump(pane, 'zzzz-no-match');
      expect(none.candidates, isEmpty);
      expect(none.statusHint, contains('No matching'));
    });

    test(
      'integrates real VirtualTerminal OSC 133;A prompts via IoLocalHostDriver',
      () async {
        final backend = _InMemoryRoutedPtyBackend();
        final driver = IoLocalHostDriver(
          backendFactory: ({
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
            initialCols: 40,
            initialRows: 4,
            maxScrollbackLines: 20,
          ),
        );
        final pane = _makePane(host.port, localHost: host);
        addTearDown(() => pane.dispose(disposePort: false));

        backend.emitUtf8(
          '\x1b]133;A\x07\$ first cmd\r\n'
          'out1\r\n'
          '\x1b]133;A\x07\$ second cmd\r\n'
          'out2\r\n'
          '\x1b]133;A\x07\$ third cmd\r\n'
          'out3\r\n',
        );
        await Future<void>.delayed(Duration.zero);

        expect(pane.promptLines.length, 3);
        final result = resolveTerminalScrollbackJump(pane, '');
        final promptTitles = result.candidates
            .where((c) => !c.isLandmark)
            .map((c) => c.title)
            .toList();
        expect(
          promptTitles,
          equals(<String>[r'$ third cmd', r'$ second cmd', r'$ first cmd']),
        );
      },
    );

    test('guards alternate screen panes cleanly', () {
      final port = _TestTerminalPort(cols: 40, rows: 8)
        ..modes = const TerminalPortModes(altScreen: true)
        ..scrollbackRows = <ScrollbackLine>[_makeScrollbackLine(40, 'hidden')];
      final pane = _makePane(port);
      addTearDown(() {
        pane.dispose(disposePort: false);
        unawaited(port.dispose());
      });

      final result = resolveTerminalScrollbackJump(pane, '1');
      expect(result.candidates, isEmpty);
      expect(result.directTarget, isNull);
      expect(result.statusHint, altScreenScrollbackJumpHint);

      pane.scrollToVirtualRow(0);
      expect(pane.scrollOffsetLines, 0);
      expect(pane.promptLines, isEmpty);
    });

    test('ScrollbackJumpCandidate and ScrollbackJumpResult value equality', () {
      const a = ScrollbackJumpCandidate(
        id: 'row-1',
        title: 'Prompt',
        subtitle: 'Line 1',
        targetVirtualRow: 1,
        matchedIndices: <int>[0, 1],
      );
      const b = ScrollbackJumpCandidate(
        id: 'row-1',
        title: 'Prompt',
        subtitle: 'Line 1',
        targetVirtualRow: 1,
        matchedIndices: <int>[0, 1],
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.toString(), contains('row-1'));

      const r1 = ScrollbackJumpResult(
        candidates: <ScrollbackJumpCandidate>[a],
        statusHint: 'ok',
        directTarget: a,
      );
      const r2 = ScrollbackJumpResult(
        candidates: <ScrollbackJumpCandidate>[b],
        statusHint: 'ok',
        directTarget: b,
      );
      expect(r1, equals(r2));
      expect(r1.hashCode, equals(r2.hashCode));
      expect(r1.toString(), contains('candidates: 1'));
    });
  });

  group('Scrollback jump (:) — Shader Editor', () {
    test('parses :1..lineCount, :-N, :N%, :top, :bottom, :0 with previews', () {
      final editor = ShaderEditorController(
        shaderName: 'test.glsl',
        initialSource:
            '// line 1\r\n'
            'uniform float iTime;\r\n'
            '\r\n'
            'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\r\n'
            '  fragColor = vec4(1.0);\r\n'
            '}',
      );
      addTearDown(editor.dispose);

      expect(editor.lineCount, 6);

      final line2 = resolveShaderEditorJump(editor, '2');
      expect(line2.directTarget?.editorLine, 2);
      expect(line2.directTarget?.targetVirtualRow, isNull);
      expect(line2.directTarget?.subtitle, 'uniform float iTime;');

      final blankLine = resolveShaderEditorJump(editor, '3');
      expect(blankLine.directTarget?.editorLine, 3);
      expect(blankLine.directTarget?.subtitle, contains('empty'));

      final clampedHigh = resolveShaderEditorJump(editor, '999');
      expect(clampedHigh.directTarget?.editorLine, 6);

      final relLast = resolveShaderEditorJump(editor, '-1');
      expect(relLast.directTarget?.editorLine, 6);
      expect(relLast.directTarget?.subtitle, '}');

      final relTwo = resolveShaderEditorJump(editor, '-2');
      expect(relTwo.directTarget?.editorLine, 5);
      expect(relTwo.directTarget?.subtitle, 'fragColor = vec4(1.0);');

      final pct0 = resolveShaderEditorJump(editor, '0%');
      expect(pct0.directTarget?.editorLine, 1);

      final pct50 = resolveShaderEditorJump(editor, '50%');
      // 1 + ((6 - 1) * 0.5).round() = 1 + 3 = 4.
      expect(pct50.directTarget?.editorLine, 4);

      final pct100 = resolveShaderEditorJump(editor, '100%');
      expect(pct100.directTarget?.editorLine, 6);

      final top = resolveShaderEditorJump(editor, 'top');
      expect(top.directTarget?.editorLine, 1);
      expect(top.directTarget?.isLandmark, isTrue);

      final bottom = resolveShaderEditorJump(editor, 'bottom');
      expect(bottom.directTarget?.editorLine, 6);
      expect(bottom.directTarget?.isLandmark, isTrue);

      final zero = resolveShaderEditorJump(editor, '0');
      expect(zero.directTarget?.editorLine, 1);

      final browse = resolveShaderEditorJump(editor, '');
      expect(browse.directTarget, isNull);
      expect(browse.candidates.map((c) => c.editorLine).toList(), <int>[1, 6]);

      // Apply jump directly to ShaderEditorController.
      expect(editor.jumpToLine(relTwo.directTarget!.editorLine!), isTrue);
      expect(editor.textController.value.selection.cursorLine, 4);
    });
  });

  group('Text search (%) — terminal pane', () {
    test('supports literal case-insensitive, case-sensitive (Aa), regex (.*), and invalid regex', () {
      final port = _TestTerminalPort(cols: 40, rows: 4)
        ..oldestScrollbackLine = 20
        ..scrollbackRows = <ScrollbackLine>[
          _makeScrollbackLine(40, 'Error: failed to connect'),
          _makeScrollbackLine(40, 'retry error count=2'),
        ];
      port
        ..writeLiveRow(0, 'ERROR_CODE=42')
        ..writeLiveRow(1, 'ok');
      final pane = _makePane(port);
      addTearDown(() {
        pane.dispose(disposePort: false);
        unawaited(port.dispose());
      });

      expect(searchTerminalPane(pane, ''), TerminalTextSearchResult.empty);
      expect(
        searchTerminalPane(pane, 'error', maxMatches: 0),
        TerminalTextSearchResult.empty,
      );

      // Case-insensitive literal.
      final ci = searchTerminalPane(pane, 'error');
      expect(ci.errorMessage, isNull);
      expect(ci.truncated, isFalse);
      expect(ci.matches, hasLength(3));
      expect(
        ci.matches
            .map((m) => (m.virtualRow, m.oneBasedLine, m.startCol, m.endCol))
            .toList(),
        equals(<(int?, int, int, int)>[
          (20, 1, 0, 5),
          (21, 2, 6, 11),
          (22, 3, 0, 5),
        ]),
      );

      // Case-sensitive literal (Aa).
      final cs = searchTerminalPane(pane, 'error', caseSensitive: true);
      expect(cs.matches, hasLength(1));
      expect(cs.matches.single.virtualRow, 21);
      expect(cs.matches.single.startCol, 6);
      expect(cs.matches.single.endCol, 11);

      // Regex search (.*) including end-of-line $ anchor on padded live rows.
      final rx = searchTerminalPane(pane, r'=\d+$', useRegex: true);
      expect(rx.errorMessage, isNull);
      expect(rx.matches, hasLength(2));
      expect(rx.matches[0].virtualRow, 21);
      expect(rx.matches[0].startCol, 17);
      expect(rx.matches[0].endCol, 19);
      expect(rx.matches[1].virtualRow, 22);
      expect(rx.matches[1].startCol, 10);
      expect(rx.matches[1].endCol, 13);

      // Zero-length regex matches are ignored cleanly.
      final zeroLen = searchTerminalPane(pane, r'^', useRegex: true);
      expect(zeroLen.matches, isEmpty);
      expect(zeroLen.errorMessage, isNull);

      // Invalid regex surfaces FormatException errorMessage without throwing.
      final invalid = searchTerminalPane(pane, '[unclosed', useRegex: true);
      expect(invalid.matches, isEmpty);
      expect(invalid.highlights, isEmpty);
      expect(invalid.errorMessage, isNotNull);
      expect(invalid.errorMessage, isNotEmpty);
    });

    test('maps wide-glyph CJK and emoji continuation cells (ch.isEmpty) accurately', () {
      final port = _TestTerminalPort(cols: 20, rows: 3)
        ..scrollbackRows = <ScrollbackLine>[
          ScrollbackLine(
            width: 20,
            characters: <String>['漢', '', '字', '', ' ', 'f', 'o', 'o'],
            attributes: Uint32List(8 * 3),
          ),
          ScrollbackLine(
            width: 20,
            characters: <String>['🚀', '', ' ', 'b', 'a', 'r', ' ', '🎉', ''],
            attributes: Uint32List(9 * 3),
          ),
        ];
      final pane = _makePane(port);
      addTearDown(() {
        pane.dispose(disposePort: false);
        unawaited(port.dispose());
      });

      // Wide CJK glyphs span 2 terminal cell columns each.
      final cjk = searchTerminalPane(pane, '漢字');
      expect(cjk.matches, hasLength(1));
      expect(cjk.matches.single.startCol, 0);
      expect(cjk.matches.single.endCol, 4);
      expect(
        cjk.matches.single.snippet.substring(
          cjk.matches.single.snippetMatchStart,
          cjk.matches.single.snippetMatchEnd,
        ),
        '漢字',
      );

      // ASCII after two wide CJK glyphs starts at col 5 (not 3).
      final afterCjk = searchTerminalPane(pane, 'foo');
      expect(afterCjk.matches, hasLength(1));
      expect(afterCjk.matches.single.startCol, 5);
      expect(afterCjk.matches.single.endCol, 8);

      // Surrogate-pair emoji spans cols 0..2 and trailing emoji cols 7..9.
      final rocket = searchTerminalPane(pane, '🚀');
      expect(rocket.matches, hasLength(1));
      expect(rocket.matches.single.startCol, 0);
      expect(rocket.matches.single.endCol, 2);

      final bar = searchTerminalPane(pane, 'bar');
      expect(bar.matches, hasLength(1));
      expect(bar.matches.single.startCol, 3);
      expect(bar.matches.single.endCol, 6);

      final party = searchTerminalPane(pane, '🎉');
      expect(party.matches, hasLength(1));
      expect(party.matches.single.startCol, 7);
      expect(party.matches.single.endCol, 9);
    });

    test('regex search in Unicode mode matches surrogate-pair emoji once without splitting surrogates', () {
      final port = _TestTerminalPort(cols: 20, rows: 2)
        ..scrollbackRows = <ScrollbackLine>[
          ScrollbackLine(
            width: 20,
            characters: <String>['🚀', '', ' ', 'a'],
            attributes: Uint32List(4 * 3),
          ),
        ];
      final pane = _makePane(port);
      addTearDown(() {
        pane.dispose(disposePort: false);
        unawaited(port.dispose());
      });

      final nonSpace = searchTerminalPane(pane, r'\S', useRegex: true);
      expect(nonSpace.errorMessage, isNull);
      expect(nonSpace.matches, hasLength(2));
      expect(nonSpace.matches[0].startCol, 0);
      expect(nonSpace.matches[0].endCol, 2);
      expect(nonSpace.matches[0].matchLength, 2);
      expect(nonSpace.matches[1].startCol, 3);
      expect(nonSpace.matches[1].endCol, 4);

      final anyChar = searchTerminalPane(pane, '.', useRegex: true);
      expect(anyChar.matches, hasLength(3));
      expect(anyChar.matches[0].startCol, 0);
      expect(anyChar.matches[0].endCol, 2);
    });

    test(
      'skips uncached remote empty slices without issuing scrollback fetches',
      () async {
        const sessionId = SessionId('remote-search-1');
        final server = _FakeRelayHarness();
        addTearDown(server.close);
        final transport = WsClientTransport(channelFactory: server.openChannel);
        final repo = CastClientRepository(
          transport: transport,
          enableReconnect: false,
        );
        addTearDown(repo.dispose);

        await repo.connect();
        server.send(const AuthAcceptedFrame(role: .client));
        await Future<void>.delayed(Duration.zero);

        final port = repo.openTerminalPort(
          sessionId,
          portId: 'remote-pane-1',
          initialCols: 20,
          initialRows: 2,
        );
        await Future<void>.delayed(Duration.zero);

        final liveBuf = tui.Buffer.blank(20, 2)
          ..writeString(0, 0, 'live needle here', const tui.Style())
          ..writeString(0, 1, 'bottom row', const tui.Style());
        server.send(
          BufferSnapshotFrame(
            snapshot: BufferSnapshot.fromBuffer(
              sessionId: sessionId,
              seq: 1,
              buffer: liveBuf,
              cursor: const CursorState(x: 0, y: 1, visible: true),
              modes: TerminalModes.defaults,
              scrollback: const ScrollbackWindow(
                clearSeq: 0,
                oldestLine: 5000,
                totalLines: 5004,
              ),
            ),
          ),
        );
        for (var i = 0; i < 40 && port.slot.buffer == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(port.slot.buffer, isNotNull);

        // Hydrate only row 5000; rows 5001, 5002, and 5003 stay uncached.
        port.slot.ingestScrollbackChunk(
          ScrollbackChunkFrame(
            sessionId: sessionId,
            requestId: 1,
            clearSeq: 0,
            startLine: 5000,
            rows: <EncodedScrollbackRow>[
              EncodedScrollbackRow(
                isWrapped: false,
                characters: 'cached needle row'.split(''),
                attributes: Uint32List(17 * 3),
              ),
            ],
          ),
        );

        final pane = _makePane(port, remoteSessionId: sessionId);
        addTearDown(() => pane.dispose(disposePort: false));

        expect(pane.oldestVirtualRow, 5000);
        expect(pane.totalVirtualLines, 5006);
        // Confirm uncached rows return empty non-null slices.
        final uncached = pane.lookupVirtualLine(5001);
        expect(uncached, isNotNull);
        expect(uncached!.characters, isEmpty);

        server.received.clear();
        final result = searchTerminalPane(pane, 'needle');

        expect(result.errorMessage, isNull);
        expect(result.matches, hasLength(2));
        expect(result.matches[0].virtualRow, 5000);
        expect(result.matches[0].startCol, 7);
        expect(result.matches[0].endCol, 13);
        expect(result.matches[1].virtualRow, 5004);
        expect(result.matches[1].startCol, 5);
        expect(result.matches[1].endCol, 11);

        // Zero network scrollback requests triggered during search.
        expect(server.received.whereType<RequestScrollbackFrame>(), isEmpty);
      },
    );

    test(
      'enforces maxMatches truncation cap and switches active highlights',
      () {
        final port = _TestTerminalPort(cols: 40, rows: 3)
          ..scrollbackRows = <ScrollbackLine>[
            _makeScrollbackLine(40, 'hit hit hit'),
            _makeScrollbackLine(40, 'hit hit'),
          ];
        final pane = _makePane(port);
        addTearDown(() {
          pane.dispose(disposePort: false);
          unawaited(port.dispose());
        });

        // Exact cap (5 hits total) is not truncated.
        final exact = searchTerminalPane(pane, 'hit', maxMatches: 5);
        expect(exact.matches, hasLength(5));
        expect(exact.truncated, isFalse);

        // Smaller cap truncates cleanly.
        final capped = searchTerminalPane(pane, 'hit', maxMatches: 3);
        expect(capped.matches, hasLength(3));
        expect(capped.truncated, isTrue);

        // Default highlights mark index 0 active.
        expect(capped.highlights, hasLength(3));
        expect(capped.highlights[0].isActive, isTrue);
        expect(capped.highlights[1].isActive, isFalse);
        expect(capped.highlights[2].isActive, isFalse);

        // Switching active index updates only the targeted highlight.
        final switched = buildHighlightsForMatches(capped.matches, 2);
        expect(
          switched,
          equals(<TerminalSearchHighlight>[
            const TerminalSearchHighlight(
              virtualRow: 0,
              startCol: 0,
              endCol: 3,
            ),
            const TerminalSearchHighlight(
              virtualRow: 0,
              startCol: 4,
              endCol: 7,
            ),
            const TerminalSearchHighlight(
              virtualRow: 0,
              startCol: 8,
              endCol: 11,
              isActive: true,
            ),
          ]),
        );

        expect(
          buildHighlightsForMatches(const <TerminalTextMatch>[], 0),
          isEmpty,
        );
      },
    );

    test('searches active alternate screen rows cleanly', () {
      final port = _TestTerminalPort(cols: 30, rows: 4)
        ..modes = const TerminalPortModes(altScreen: true)
        ..scrollbackRows = <ScrollbackLine>[
          _makeScrollbackLine(30, 'primary match hidden'),
        ];
      port.writeLiveRow(2, 'alt match visible');
      final pane = _makePane(port);
      addTearDown(() {
        pane.dispose(disposePort: false);
        unawaited(port.dispose());
      });

      final result = searchTerminalPane(pane, 'match');
      expect(result.matches, hasLength(1));
      expect(result.matches.single.virtualRow, 2);
      expect(result.matches.single.oneBasedLine, 3);
      expect(result.matches.single.startCol, 4);
      expect(result.matches.single.endCol, 9);
    });

    test('TerminalTextMatch and TerminalTextSearchResult value equality', () {
      const m1 = TerminalTextMatch(
        virtualRow: 3,
        oneBasedLine: 4,
        startCol: 1,
        endCol: 5,
        snippet: 'xtesty',
        snippetMatchStart: 1,
        snippetMatchEnd: 5,
        matchLength: 4,
      );
      const m2 = TerminalTextMatch(
        virtualRow: 3,
        oneBasedLine: 4,
        startCol: 1,
        endCol: 5,
        snippet: 'xtesty',
        snippetMatchStart: 1,
        snippetMatchEnd: 5,
        matchLength: 4,
      );
      expect(m1, equals(m2));
      expect(m1.hashCode, equals(m2.hashCode));
      expect(m1.toString(), contains('virtualRow: 3'));

      final r1 = TerminalTextSearchResult(
        matches: const <TerminalTextMatch>[m1],
        highlights: buildHighlightsForMatches(const <TerminalTextMatch>[m1], 0),
      );
      final r2 = TerminalTextSearchResult(
        matches: const <TerminalTextMatch>[m2],
        highlights: buildHighlightsForMatches(const <TerminalTextMatch>[m2], 0),
      );
      expect(r1, equals(r2));
      expect(r1.hashCode, equals(r2.hashCode));
      expect(r1.toString(), contains('matches: 1'));
    });
  });

  group('Text search (%) — Shader Editor', () {
    test('searches GLSL lines with literal, case, regex, error, cap, and jumpToLine roundtrip', () {
      final editor = ShaderEditorController(
        shaderName: 'glow.glsl',
        initialSource:
            '// 🚀 glow shader\r\n'
            'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\r\n'
            '  vec2 uv = fragCoord / iResolution.xy;\r\n'
            '  fragColor = vec4(uv, 0.5, 1.0);\r\n'
            '}',
      );
      addTearDown(editor.dispose);

      expect(searchShaderEditor(editor, ''), TerminalTextSearchResult.empty);

      // Case-insensitive search finds both FragColor / fragColor / fragCoord.
      final ci = searchShaderEditor(editor, 'frag');
      expect(ci.highlights, isEmpty);
      expect(ci.matches, hasLength(4));
      expect(ci.matches[0].virtualRow, isNull);
      expect(ci.matches[0].editorLine, 2);
      expect(ci.matches[0].editorColumn, 25);
      expect(ci.matches[0].matchLength, 4);

      // Case-sensitive search.
      final cs = searchShaderEditor(editor, 'FRAG', caseSensitive: true);
      expect(cs.matches, isEmpty);

      // Regex search + invalid regex.
      final rx = searchShaderEditor(editor, r'vec[24]', useRegex: true);
      expect(rx.matches, hasLength(4));

      final badRx = searchShaderEditor(editor, '(unclosed', useRegex: true);
      expect(badRx.matches, isEmpty);
      expect(badRx.errorMessage, isNotNull);

      // Truncation cap.
      final capped = searchShaderEditor(editor, 'frag', maxMatches: 2);
      expect(capped.matches, hasLength(2));
      expect(capped.truncated, isTrue);

      // Emoji-prefixed line round-trips cleanly through jumpToLine.
      final emojiLine = searchShaderEditor(editor, 'glow');
      expect(emojiLine.matches, hasLength(1));
      final match = emojiLine.matches.single;
      expect(match.editorLine, 1);
      expect(
        match.snippet.substring(match.snippetMatchStart, match.snippetMatchEnd),
        'glow',
      );
      expect(
        editor.jumpToLine(
          match.editorLine!,
          oneBasedColumn: match.editorColumn!,
          selectionLength: match.matchLength,
        ),
        isTrue,
      );
      final sel = editor.textController.value.selection;
      expect(sel.cursorLine, 0);
      expect(sel.isCollapsed, isFalse);
      final selected = editor.source.characters
          .getRange(sel.baseOffset, sel.extentOffset)
          .string;
      expect(selected, 'glow');
    });

    test('Unicode regex does not split surrogate pairs and jumpToLine selects mid-grapheme combining marks', () {
      final editor = ShaderEditorController(
        shaderName: 'unicode.glsl',
        initialSource: '// 🚀 cafe\u0301',
      );
      addTearDown(editor.dispose);

      // Unicode regex \S matches surrogate-pair emoji once (length 2), not twice.
      final rx = searchShaderEditor(editor, r'\S', useRegex: true);
      expect(rx.errorMessage, isNull);
      final emojiMatch = rx.matches.firstWhere((m) => m.editorColumn == 4);
      expect(emojiMatch.matchLength, 2);
      expect(rx.matches.where((m) => m.editorColumn == 5), isEmpty);

      // Mid-grapheme combining mark (U+0301 at UTF-16 offset 10 -> 1-based col 11)
      // must floor startCol to include the containing grapheme ('e\u0301').
      final markResult = searchShaderEditor(editor, '\u0301');
      expect(markResult.matches, hasLength(1));
      final mark = markResult.matches.single;
      expect(
        editor.jumpToLine(
          mark.editorLine!,
          oneBasedColumn: mark.editorColumn!,
          selectionLength: mark.matchLength,
        ),
        isTrue,
      );
      final sel = editor.textController.value.selection;
      expect(sel.isCollapsed, isFalse);
      final selected = editor.source.characters
          .getRange(sel.baseOffset, sel.extentOffset)
          .string;
      expect(selected, 'e\u0301');
    });
  });
}

FtermPaneController _makePane(
  TerminalPort port, {
  LocalPaneHost? localHost,
  SessionId? remoteSessionId,
}) => FtermPaneController(
  paneId: 'test-pane',
  port: port,
  localHost: localHost,
  remoteSessionId: remoteSessionId,
  colorResolver: TerminalColorResolver(
    theme: tui.TerminalColorTheme.termuiDark,
    settings: const TerminalThemeSettings(),
  ),
  resizeDebounce: Duration.zero,
);

ScrollbackLine _makeScrollbackLine(int width, String text) {
  final chars = text.characters.toList(growable: false);
  return ScrollbackLine(
    width: width,
    characters: chars,
    attributes: Uint32List(chars.length * 3),
  );
}

final class _TestTerminalPort implements TerminalPort {
  final tui.Buffer _buffer;
  final Set<void Function()> _listeners = <void Function()>{};
  final Completer<int> _exitCode = Completer<int>();

  int oldestScrollbackLine = 0;
  int clearSeq = 0;
  List<ScrollbackLine> scrollbackRows = const <ScrollbackLine>[];
  @override
  TerminalPortModes modes = TerminalPortModes.defaults;

  _TestTerminalPort({required int cols, required int rows})
    : _buffer = tui.Buffer.blank(cols, rows);

  void writeLiveRow(int row, String text) {
    _buffer.writeString(0, row, text, const tui.Style());
  }

  @override
  String get id => 'test-port';

  @override
  int get renderRevision => 0;

  @override
  int get fullSyncRevision => 0;

  @override
  List<DirtyCellSpan> get dirtySpans => const <DirtyCellSpan>[];

  @override
  tui.Buffer get buffer => _buffer;

  @override
  int get cols => _buffer.width;

  @override
  int get rows => _buffer.height;

  @override
  (int cols, int rows) get activePtySize => (_buffer.width, _buffer.height);

  @override
  CursorStateData get cursor => CursorStateData.origin;

  @override
  ScrollbackWindowData get scrollbackWindow => (
    clearSeq: clearSeq,
    oldestLine: oldestScrollbackLine,
    totalLines: oldestScrollbackLine + scrollbackRows.length,
  );

  @override
  String get windowTitle => 'test';

  @override
  String? get workingDirectory => '/tmp';

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);

  @override
  void addTitleListener(void Function(String title) listener) {}

  @override
  void removeTitleListener(void Function(String title) listener) {}

  @override
  void addBellListener(void Function() listener) {}

  @override
  void removeBellListener(void Function() listener) {}

  @override
  void addAudioListener(void Function(TerminalAudioEvent event) listener) {}

  @override
  void removeAudioListener(void Function(TerminalAudioEvent event) listener) {}

  @override
  void addShaderListener(
    void Function(TerminalShaderApcEvent event) listener,
  ) {}

  @override
  void removeShaderListener(
    void Function(TerminalShaderApcEvent event) listener,
  ) {}

  @override
  void setShaderCapabilities(TerminalShaderCapabilities capabilities) {}

  @override
  void addClipboardListener(
    void Function(String selection, String text) listener,
  ) {}

  @override
  void removeClipboardListener(
    void Function(String selection, String text) listener,
  ) {}

  @override
  void sendInput(Uint8List utf8Bytes) {}

  @override
  void setViewportSize(
    int cols,
    int rows, {
    int cellPixelWidth = 0,
    int cellPixelHeight = 0,
  }) {}

  @override
  List<ScrollbackLine?> readScrollbackSlice(int startLine, int count) {
    if (scrollbackRows.isEmpty) return const <ScrollbackLine?>[];
    return List<ScrollbackLine?>.generate(count, (i) {
      final offset = (startLine + i) - oldestScrollbackLine;
      if (offset < 0 || offset >= scrollbackRows.length) return null;
      return scrollbackRows[offset];
    });
  }

  @override
  Future<void> dispose() async {
    if (!_exitCode.isCompleted) _exitCode.complete(0);
  }
}

final class _FakePromptHost implements PromptIndexedPaneHost {
  @override
  final TerminalPort port;

  @override
  final List<int> promptLines;

  final StreamController<LocalShareSnapshot> _shareController =
      StreamController<LocalShareSnapshot>.broadcast();

  _FakePromptHost({required this.port, required this.promptLines});

  @override
  String get id => 'fake-prompt-host';

  @override
  Future<int> get exitCode => port.exitCode;

  @override
  LocalShareSnapshot get shareSnapshot => LocalShareSnapshot.unshared;

  @override
  Stream<LocalShareSnapshot> get shareUpdates => _shareController.stream;

  @override
  Future<SessionId> startShare({
    required Uri serverUri,
    required String casterToken,
    required String title,
    String? uploadDirPath,
    IapTokenProvider? iapTokenProvider,
    CasterTransportOpener? channelOpener,
  }) => throw UnimplementedError();

  @override
  Future<void> stopShare() async {}

  @override
  void setColorScheme(tui.TerminalBrightness brightness) {}

  @override
  bool isLiveRowWrapped(int row) => false;

  @override
  Future<void> dispose() async {
    await _shareController.close();
    await port.dispose();
  }
}

final class _InMemoryRoutedPtyBackend implements RoutedPtyBackend {
  final StreamController<Uint8List> _output =
      StreamController<Uint8List>.broadcast();
  final Completer<int> _exit = Completer<int>();

  void emitUtf8(String text) {
    if (!_output.isClosed) {
      _output.add(Uint8List.fromList(utf8.encode(text)));
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

final class _FakeRelayHarness {
  final List<CastMessage> received = <CastMessage>[];
  StreamController<Uint8List>? _serverToClient;
  StreamController<Uint8List>? _clientToServer;

  Future<StreamChannel<Uint8List>> openChannel() async {
    final s2c = StreamController<Uint8List>();
    final c2s = StreamController<Uint8List>();
    _serverToClient = s2c;
    _clientToServer = c2s;
    c2s.stream.listen((bytes) {
      received.add(BufferFrameCodec.decode(bytes));
    });
    return StreamChannel<Uint8List>(s2c.stream, c2s.sink);
  }

  void send(CastMessage frame) {
    _serverToClient?.add(BufferFrameCodec.encode(frame));
  }

  Future<void> close() async {
    await _serverToClient?.close();
    await _clientToServer?.close();
  }
}
