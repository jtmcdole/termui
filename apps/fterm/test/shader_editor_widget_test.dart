import 'dart:async';

import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/shader_editor/shader_editor_controller.dart';
import 'package:fterm/src/shader_editor/shader_editor_pane.dart';
import 'package:fterm/src/shader_editor/shader_editor_view.dart';
import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/termui.dart' as tui;
import 'package:termui_flutter/termui_flutter.dart';

String _rowText(tui.Buffer buf, int y) =>
    [for (var x = 0; x < buf.width; x++) buf.getCharacter(x, y)]
        .join()
        .trimRight();

int _findInRow(tui.Buffer buf, int y, String needle) =>
    _rowText(buf, y).indexOf(needle);

void main() {
  setUp(() {
    tui.FocusManager.instance.setPrimaryFocus(null);
  });

  group(
    'ShaderEditorPane rendering, syntax coloring, and SGR 58 squiggles',
    () {
      test('renders GLSL TextSpan syntax colors, gutter markers, and red/amber SGR 58 curly squiggles at SourceSpan columns', () async {
        const source =
            '// @fterm-stage: fg\n'
            'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
            '  vec4 col = texture(iChannel0, fragCoord / iResolution.xy);\n'
            '  float bad = unknownVar / 0.0;\n'
            '  fragColor = col + bad;\n'
            '}';

        final controller = ShaderEditorController(
          shaderName: 'glow.glsl',
          sourcePath: '/shaders/glow.glsl',
          initialSource: source,
          initialPreviewMode: ShaderEditorPreviewMode.foreground,
          onCompile: (src, mode) async => const <ShaderDiagnostic>[
            ShaderDiagnostic(
              severity: ShaderDiagnosticSeverity.error,
              origin: ShaderDiagnosticOrigin.compiler,
              message: "undeclared identifier 'unknownVar'",
              line: 4,
              column: 15,
              length: 10,
            ),
          ],
        );
        final pane = ShaderEditorPane(
          paneId: 'editor-1',
          controller: controller,
          initialCols: 100,
          initialRows: 16,
        );
        addTearDown(() {
          pane.dispose();
          controller.dispose();
        });

        await controller.triggerCompileNow();

        final buf = pane.readDisplayBuffer();
        // Header bar (row 0) and hint ribbon (row 1).
        final headerRow = _rowText(buf, 0);
        expect(headerRow, contains('glow.glsl'));
        expect(headerRow, contains('[OFF|BG|FG]'));
        expect(headerRow, contains('[Solo]'));
        expect(headerRow, contains('[Save Alt+S]'));

        final hintRow = _rowText(buf, 1);
        expect(hintRow, contains('@fterm-stage:FG'));
        expect(hintRow, contains('iChannel0'));
        expect(hintRow, contains('1 error'));
        expect(hintRow, contains('1 warning'));

        final gutterW = ShaderEditorView.gutterWidthForLines(6);
        // Line 1 (row 2): '// @fterm-stage: fg' has bold directive styling.
        expect(buf.getCharacter(gutterW, 2), equals('/'));
        expect(
          tui.Modifier.has(buf.getModifiers(gutterW, 2), tui.Modifier.bold),
          isTrue,
        );

        // Line 2 (row 3): 'void' has distinct color from 'mainImage'.
        final voidFg = buf.getForeground(gutterW, 3);
        final mainFg = buf.getForeground(gutterW + 5, 3);
        expect(voidFg, isNot(equals(0)));
        expect(voidFg, isNot(equals(tui.Colors.black.argb)));
        expect(mainFg, isNot(equals(voidFg)));

        // Line 4 (row 5): error marker '●' in gutter col 0.
        expect(buf.getCharacter(0, 5), equals('●'));

        // 'unknownVar' on line 4 col 15 (0-based col 14) has red SGR 58 curly squiggle.
        final errStartX = gutterW + 14;
        expect(buf.getCharacter(errStartX, 5), equals('u'));
        final errUnderlineColor = buf.getUnderlineColor(errStartX, 5);
        expect(errUnderlineColor, isNot(equals(0)));
        expect(
          tui.Modifier.getUnderlineStyle(buf.getModifiers(errStartX, 5)),
          equals(tui.UnderlineStyle.curly),
        );

        // '/ 0.0' lint warning on line 4 col 26 (0-based col 25) has amber curly squiggle.
        final warnStartX = gutterW + 25;
        expect(buf.getCharacter(warnStartX, 5), equals('/'));
        final warnUnderlineColor = buf.getUnderlineColor(warnStartX, 5);
        expect(warnUnderlineColor, isNot(equals(0)));
        expect(warnUnderlineColor, isNot(equals(errUnderlineColor)));
        expect(
          tui.Modifier.getUnderlineStyle(buf.getModifiers(warnStartX, 5)),
          equals(tui.UnderlineStyle.curly),
        );

        // SourceSpan resolution matches exact text.
        final errSpan = controller.spanForDiagnostic(controller.diagnostics[0]);
        expect(errSpan, isNotNull);
        expect(errSpan!.text, equals('unknownVar'));

        // Diagnostics footer renders at bottom rows.
        final footerRow0 = _rowText(buf, 14);
        final footerRow1 = _rowText(buf, 15);
        expect(footerRow0, contains('4:15'));
        expect(footerRow0, contains('unknownVar'));
        expect(footerRow1, contains('4:26'));
        expect(footerRow1, contains('Division by literal zero'));
      });
    },
  );

  group('resolvePreviewShaderConfig Solo vs Blend vs Off vs E-Stop', () {
    final wsBgPass = ShaderPassSpec(
      id: 'ws-bg',
      stage: TerminalShaderStage.background,
      preset: TerminalShaderPreset.wallpaperWave,
    );
    final wsFgPass = ShaderPassSpec(
      id: 'ws-fg',
      stage: TerminalShaderStage.foreground,
      preset: TerminalShaderPreset.scanlineOverlay,
    );
    final workspaceConfig = TerminalShaderConfig(
      backgroundPasses: <ShaderPassSpec>[wsBgPass],
      foregroundPasses: <ShaderPassSpec>[wsFgPass],
      backgroundOpacity: 0.9,
      enabled: true,
    );

    test('enforces Solo override by default, Blend with Workspace when toggled, Off when disabled, and E-Stop bypass', () {
      final controller = ShaderEditorController(
        shaderName: 'draft.glsl',
        initialSource:
            'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
            '  fragColor = vec4(1.0);\n'
            '}',
        initialPreviewMode: ShaderEditorPreviewMode.background,
      );
      final pane = ShaderEditorPane(paneId: 'p1', controller: controller);
      addTearDown(() {
        pane.dispose();
        controller.dispose();
      });

      // Default is Solo: overrides workspace passes with ONLY draft BG pass & 0.75 opacity.
      expect(
        controller.chainComposition,
        equals(ShaderEditorChainComposition.solo),
      );
      final soloBg = pane.resolvePreviewShaderConfig(workspaceConfig);
      expect(soloBg.enabled, isTrue);
      expect(soloBg.backgroundPasses.map((p) => p.id), equals(['editor:p1']));
      expect(soloBg.foregroundPasses, isEmpty);
      expect(soloBg.backgroundOpacity, closeTo(0.75, 1e-6));

      // Toggle to Blend: composes draft BG pass after workspace BG pass and keeps workspace FG pass.
      controller.toggleChainComposition();
      expect(
        controller.chainComposition,
        equals(ShaderEditorChainComposition.blendWithWorkspace),
      );
      final blendBg = pane.resolvePreviewShaderConfig(workspaceConfig);
      expect(blendBg.enabled, isTrue);
      expect(
        blendBg.backgroundPasses.map((p) => p.id),
        equals(['ws-bg', 'editor:p1']),
      );
      expect(blendBg.foregroundPasses.map((p) => p.id), equals(['ws-fg']));

      // Switch preview to FG in Blend mode: restores opaque 1.0 and appends draft FG pass.
      controller.setPreviewMode(ShaderEditorPreviewMode.foreground);
      final blendFg = pane.resolvePreviewShaderConfig(workspaceConfig);
      expect(blendFg.backgroundPasses.map((p) => p.id), equals(['ws-bg']));
      expect(
        blendFg.foregroundPasses.map((p) => p.id),
        equals(['ws-fg', 'editor:p1']),
      );
      expect(blendFg.backgroundOpacity, closeTo(1.0, 1e-6));

      // Solo FG mode overrides workspace passes with ONLY draft FG pass.
      controller.toggleChainComposition();
      final soloFg = pane.resolvePreviewShaderConfig(workspaceConfig);
      expect(soloFg.backgroundPasses, isEmpty);
      expect(soloFg.foregroundPasses.map((p) => p.id), equals(['editor:p1']));

      // Preview OFF disables passes on the editor tab.
      controller.setPreviewMode(ShaderEditorPreviewMode.off);
      final previewOff = pane.resolvePreviewShaderConfig(workspaceConfig);
      expect(previewOff.enabled, isFalse);
      expect(previewOff.backgroundPasses, isEmpty);
      expect(previewOff.foregroundPasses, isEmpty);

      // E-Stop active on workspaceConfig disables all passes even when preview is BG.
      controller.setPreviewMode(ShaderEditorPreviewMode.background);
      final eStopped = pane.resolvePreviewShaderConfig(
        workspaceConfig.copyWith(enabled: false),
      );
      expect(eStopped.enabled, isFalse);
      expect(eStopped.backgroundPasses, isEmpty);
      expect(eStopped.foregroundPasses, isEmpty);
    });
  });

  group('Gutter sync, hotkeys, clicks, undo/redo, debounce, and close prompt', () {
    test('syncs line-number gutter with controller.scrollOffset across scroll events', () {
      final lines = [
        '// @fterm-stage: bg',
        'void mainImage(out vec4 fragColor, in vec2 fragCoord) {',
        for (var i = 3; i <= 25; i++) '  float v$i = $i.0;',
        '  fragColor = vec4(1.0);',
        '}',
      ];
      final controller = ShaderEditorController(
        shaderName: 'long.glsl',
        initialSource: lines.join('\n'),
      );
      final pane = ShaderEditorPane(
        paneId: 'scroll-pane',
        controller: controller,
        initialCols: 70,
        initialRows: 10,
      );
      addTearDown(() {
        pane.dispose();
        controller.dispose();
      });

      // Initially top code line (row 2) shows line 1.
      expect(_rowText(pane.readDisplayBuffer(), 2), startsWith('   1 '));

      // Scroll via mouse wheel down inside code body.
      final gutterW = ShaderEditorView.gutterWidthForLines(lines.length);
      pane.handleInputEvent(
        ev.MouseEvent(
          x: gutterW + 3,
          y: 4,
          button: ev.MouseButton.wheelDown,
          type: ev.MouseEventType.press,
        ),
      );
      expect(controller.textController.scrollOffset, equals(3));
      expect(_rowText(pane.readDisplayBuffer(), 2), startsWith('   4 '));

      // PageDown moves cursor and keeps gutter synchronized.
      pane.handleInputEvent(const ev.KeyEvent('', ev.KeyType.pageDown));
      final expectedTop = controller.textController.scrollOffset + 1;
      expect(_rowText(pane.readDisplayBuffer(), 2), contains('$expectedTop '));
    });

    test('F2 inserts and cycles @fterm-stage annotation, F4 and footer click jump to diagnostics', () async {
      const source =
          'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
          '  float a = 1.0 / 0.0;\n'
          '  discard;\n'
          '  fragColor = vec4(a);\n'
          '}';
      final controller = ShaderEditorController(
        shaderName: 'lint.glsl',
        initialSource: source,
        initialPreviewMode: ShaderEditorPreviewMode.background,
      );
      final pane = ShaderEditorPane(
        paneId: 'hotkeys',
        controller: controller,
        initialCols: 90,
        initialRows: 14,
      );
      addTearDown(() {
        pane.dispose();
        controller.dispose();
      });

      // Press F2: inserts inferred '// @fterm-stage: bg' at top.
      expect(controller.hasExplicitStageDirective, isFalse);
      pane.handleInputEvent(const ev.KeyEvent('', ev.KeyType.f2));
      expect(controller.hasExplicitStageDirective, isTrue);
      expect(controller.source, startsWith('// @fterm-stage: bg\n'));

      // Press F2 again: cycles bg -> fg -> both.
      pane.handleInputEvent(const ev.KeyEvent('', ev.KeyType.f2));
      expect(controller.source, startsWith('// @fterm-stage: fg\n'));
      pane.handleInputEvent(const ev.KeyEvent('', ev.KeyType.f2));
      expect(controller.source, startsWith('// @fterm-stage: both\n'));

      // Diagnostics should now include '/ 0.0' on line 3 and 'discard;' on line 4.
      expect(controller.diagnostics.length, equals(2));

      // Press F4: jumps to first diagnostic (line 3 -> 0-based line 2).
      pane.handleInputEvent(const ev.KeyEvent('', ev.KeyType.f4));
      expect(controller.textController.value.selection.cursorLine, equals(2));

      // Press F4 again: jumps to second diagnostic (line 4 -> 0-based line 3).
      pane.handleInputEvent(const ev.KeyEvent('', ev.KeyType.f4));
      expect(controller.textController.value.selection.cursorLine, equals(3));

      // Clicking first footer row (bottom - 1, 1-based y = rows - 1) jumps back to index 0.
      pane.handleInputEvent(
        const ev.MouseEvent(
          x: 5,
          y: 13,
          button: ev.MouseButton.left,
          type: ev.MouseEventType.press,
        ),
      );
      expect(controller.selectedDiagnosticIndex, equals(0));
      expect(controller.textController.value.selection.cursorLine, equals(2));
    });

    test('supports typing, Tab indentation, paste, undo/redo, header clicks, BG opacity auto-reveal, and dirty close prompt', () async {
      var savedCount = 0;
      var closeConfirmedCount = 0;
      final controller = ShaderEditorController(
        shaderName: 'edit.glsl',
        initialSource:
            '// @fterm-stage: bg\n'
            'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
            '  fragColor = vec4(0.0);\n'
            '}',
        onSave: (name, path, src) async {
          savedCount++;
          return true;
        },
      );
      final pane = ShaderEditorPane(
        paneId: 'edit-pane',
        controller: controller,
        initialCols: 110,
        initialRows: 12,
        onCloseConfirmed: () => closeConfirmedCount++,
      );
      addTearDown(() {
        pane.dispose();
        controller.dispose();
      });

      expect(pane.isDirty, isFalse);
      expect(controller.previewBackgroundOpacity, closeTo(1.0, 1e-6));

      // Click 'BG' in header bar -> auto-reveals background opacity to 0.75.
      final buf0 = pane.readDisplayBuffer();
      final bgX = _findInRow(buf0, 0, '|BG|') + 1;
      pane.handleInputEvent(
        ev.MouseEvent(
          x: bgX + 1,
          y: 1,
          button: ev.MouseButton.left,
          type: ev.MouseEventType.press,
        ),
      );
      expect(
        controller.previewMode,
        equals(ShaderEditorPreviewMode.background),
      );
      expect(controller.previewBackgroundOpacity, closeTo(0.75, 1e-6));

      // Click '[-]' and '[+]' opacity buttons and '[BG:Theme]' swatch.
      final minusX = _findInRow(pane.readDisplayBuffer(), 0, '[-]');
      pane.handleInputEvent(
        ev.MouseEvent(
          x: minusX + 2,
          y: 1,
          button: ev.MouseButton.left,
          type: ev.MouseEventType.press,
        ),
      );
      expect(controller.previewBackgroundOpacity, closeTo(0.70, 1e-6));

      final swatchX = _findInRow(pane.readDisplayBuffer(), 0, '[BG:Theme]');
      pane.handleInputEvent(
        ev.MouseEvent(
          x: swatchX + 2,
          y: 1,
          button: ev.MouseButton.left,
          type: ev.MouseEventType.press,
        ),
      );
      expect(
        controller.previewBackgroundPreset,
        equals(ShaderEditorBackgroundPreset.dark),
      );
      expect(pane.previewBackgroundColorOverride, isNotNull);

      // Type Tab (inserts 2 spaces) and committed text, then Undo & Redo.
      final original = controller.source;
      pane.handleInputEvent(const ev.KeyEvent('', ev.KeyType.tab));
      expect(controller.source, startsWith('  // @fterm-stage: bg'));
      expect(pane.isDirty, isTrue);

      pane.handleCommittedText('x');
      expect(controller.source, startsWith('  x// @fterm-stage: bg'));

      // Ctrl+Z undoes 'x', second Ctrl+Z undoes Tab.
      pane.handleInputEvent(
        const ev.KeyEvent(
          'z',
          ev.KeyType.character,
          modifiers: {ev.Modifier.control},
        ),
      );
      expect(controller.source, startsWith('  // @fterm-stage: bg'));
      pane.handleInputEvent(
        const ev.KeyEvent(
          'z',
          ev.KeyType.character,
          modifiers: {ev.Modifier.control},
        ),
      );
      expect(controller.source, equals(original));

      // Ctrl+Shift+Z redoes Tab.
      pane.handleInputEvent(
        const ev.KeyEvent(
          'z',
          ev.KeyType.character,
          modifiers: {ev.Modifier.control, ev.Modifier.shift},
        ),
      );
      expect(controller.source, startsWith('  // @fterm-stage: bg'));
      expect(pane.isDirty, isTrue);

      // Dirty close prompt: requestClose returns false and renders confirm banner.
      expect(controller.requestClose(), isFalse);
      expect(controller.confirmingClose, isTrue);
      expect(
        _rowText(pane.readDisplayBuffer(), 0),
        contains('Unsaved changes'),
      );
      expect(pane.readCursorVisible(), isFalse);

      // Escape cancels close confirmation.
      pane.handleInputEvent(const ev.KeyEvent('', ev.KeyType.escape));
      expect(controller.confirmingClose, isFalse);
      expect(pane.readCursorVisible(), isTrue);

      // Request close again and press 'y' -> saves & confirms close.
      expect(controller.requestClose(), isFalse);
      pane.handleInputEvent(const ev.KeyEvent('y', ev.KeyType.character));
      await Future<void>.delayed(Duration.zero);
      expect(savedCount, equals(1));
      expect(closeConfirmedCount, equals(1));
      expect(pane.isDirty, isFalse);

      // Clean buffer closes immediately without prompt.
      expect(controller.requestClose(), isTrue);

      // Dirty buffer + 'n' discards without saving and confirms close.
      pane.handleInputEvent(const ev.PasteEvent('// extra\n'));
      expect(pane.isDirty, isTrue);
      expect(controller.requestClose(), isFalse);
      pane.handleInputEvent(const ev.KeyEvent('n', ev.KeyType.character));
      expect(savedCount, equals(1));
      expect(closeConfirmedCount, equals(2));

      // Alt+S saves directly.
      pane.handleInputEvent(
        const ev.KeyEvent(
          's',
          ev.KeyType.character,
          modifiers: {ev.Modifier.alt},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(savedCount, equals(2));
      expect(pane.isDirty, isFalse);
    });

    testWidgets(
      'debounces edits at 350ms and drops stale async compile generations',
      (tester) async {
        final completers = <Completer<List<ShaderDiagnostic>>>[];
        final compiledSources = <String>[];

        final controller = ShaderEditorController(
          shaderName: 'gen.glsl',
          initialSource:
              '// @fterm-stage: bg\n'
              'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
              '  fragColor = vec4(1.0);\n'
              '}',
          initialPreviewMode: ShaderEditorPreviewMode.background,
          onCompile: (src, mode) {
            compiledSources.add(src);
            final c = Completer<List<ShaderDiagnostic>>();
            completers.add(c);
            return c.future;
          },
        );
        final pane = ShaderEditorPane(
          paneId: 'gen-pane',
          controller: controller,
        );
        addTearDown(() {
          pane.dispose();
          controller.dispose();
        });

        // Edit 1 -> wait 200ms (still debounced, no compile yet).
        controller.textController.text =
            '// @fterm-stage: bg\n'
            'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
            '  fragColor = vec4(firstErr);\n'
            '}';
        await tester.pump(const Duration(milliseconds: 200));
        expect(compiledSources, isEmpty);

        // Wait another 150ms -> total 350ms -> generation 1 starts.
        await tester.pump(const Duration(milliseconds: 150));
        expect(compiledSources.length, equals(1));
        expect(controller.isCompiling, isTrue);
        final gen1 = controller.compileGeneration;

        // Edit 2 before gen 1 completes -> wait 350ms -> generation 2 starts.
        controller.textController.text =
            '// @fterm-stage: bg\n'
            'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
            '  fragColor = vec4(0.5);\n'
            '}';
        await tester.pump(const Duration(milliseconds: 350));
        expect(compiledSources.length, equals(2));
        expect(controller.compileGeneration, greaterThan(gen1));

        // Generation 2 completes cleanly first.
        await tester.pump(const Duration(milliseconds: 12));
        completers[1].complete(const <ShaderDiagnostic>[]);
        await tester.pump();
        expect(controller.isCompiling, isFalse);
        expect(controller.diagnostics, isEmpty);
        expect(controller.lastCompileDurationMs, isNotNull);

        // Stale generation 1 finishes later with an error -> MUST be dropped.
        completers[0].complete(const <ShaderDiagnostic>[
          ShaderDiagnostic(
            severity: ShaderDiagnosticSeverity.error,
            origin: ShaderDiagnosticOrigin.compiler,
            message: 'stale error from gen 1',
            line: 3,
            column: 20,
            length: 8,
          ),
        ]);
        await tester.pump();
        expect(controller.diagnostics, isEmpty);
      },
    );

    test('handles viewport resize, theme switch, focus events, cursor position, and compiler exceptions', () async {
      final controller = ShaderEditorController(
        shaderName: 'misc.glsl',
        initialSource:
            '// @fterm-stage: bg\n'
            'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
            '  fragColor = vec4(1.0);\n'
            '}',
        initialPreviewMode: ShaderEditorPreviewMode.background,
        onCompile: (src, mode) async {
          throw const ShaderCompileException(
            shaderId: 'misc.glsl',
            message: 'syntax error',
            lineNumber: 2,
          );
        },
      );
      final pane = ShaderEditorPane(
        paneId: 'misc',
        controller: controller,
        initialCols: 80,
        initialRows: 12,
      );
      addTearDown(() {
        pane.dispose();
        controller.dispose();
      });

      var bufferChanges = 0;
      var previewChanges = 0;
      void onBufferChange() => bufferChanges++;
      pane.bufferListenable.addListener(onBufferChange);
      pane.previewConfigListenable.addListener(() => previewChanges++);

      expect(pane.shaderName, equals('misc.glsl'));
      expect(pane.sourcePath, isNull);
      expect(pane.source, contains('mainImage'));
      expect(pane.previewBackgroundOpacity, closeTo(0.75, 1e-6));
      expect(controller.backgroundModeOpacity, closeTo(0.75, 1e-6));
      expect(pane.bufferListenable.value.width, equals(80));
      expect(
        (pane.bufferListenable as TerminalBufferChangeSignal)
            .cellContentRevision,
        greaterThanOrEqualTo(0),
      );

      await controller.triggerCompileNow();
      expect(controller.errorCount, equals(1));
      expect(controller.diagnostics.first.line, equals(2));
      expect(previewChanges, greaterThan(0));

      // Multi-character committed text and markSaved().
      pane.handleCommittedText('// note\n');
      expect(pane.isDirty, isTrue);
      controller.markSaved();
      expect(pane.isDirty, isFalse);

      // Shim validation error surfaces directly without invoking compiler.
      controller.textController.text =
          '#version 460\nvoid mainImage(out vec4 c, in vec2 f) {}';
      await controller.triggerCompileNow();
      expect(controller.errorCount, greaterThan(0));
      expect(controller.infoCount, greaterThanOrEqualTo(0));

      // Direct setFocused + confirm-close committed text path.
      pane.setFocused(false);
      expect(pane.readCursorVisible(), isFalse);
      pane.setFocused(true);
      expect(pane.readCursorVisible(), isTrue);
      expect(controller.requestClose(), isFalse);
      pane.handleCommittedText('n');
      expect(controller.confirmingClose, isFalse);

      pane.updateViewportSize(100, 20, 8.0, 16.0);
      expect(pane.readDisplayBuffer().width, equals(100));
      expect(pane.readDisplayBuffer().height, equals(20));

      pane.setTheme(tui.TerminalColorTheme.termuiLight);
      pane.handleInputEvent(const ev.FocusOutEvent());
      expect(pane.readCursorVisible(), isFalse);
      pane.handleInputEvent(const ev.FocusInEvent());
      expect(pane.readCursorVisible(), isTrue);

      final pos = pane.readCursorPosition();
      expect(pos.row, greaterThanOrEqualTo(2));
      expect(pos.col, greaterThanOrEqualTo(0));
      expect(bufferChanges, greaterThan(0));
      pane.bufferListenable.removeListener(onBufferChange);
    });

    test('uses default cell background (0) in code body and gutter in BG mode so TerminalSurface backgroundOpacity reveals background shaders', () {
      const source =
          'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
          '  fragColor = vec4(1.0);\n'
          '}';
      final controller = ShaderEditorController(
        shaderName: 'bg_preview.glsl',
        initialSource: source,
        initialPreviewMode: ShaderEditorPreviewMode.background,
      );
      final pane = ShaderEditorPane(
        paneId: 'bg-alpha',
        controller: controller,
        initialCols: 80,
        initialRows: 12,
      );
      addTearDown(() {
        pane.dispose();
        controller.dispose();
      });

      final buf = pane.readDisplayBuffer();
      final gutterW = ShaderEditorView.gutterWidthForLines(3);
      // Code cells (row 3 = line 2, non-cursor row) must use bg == 0 so
      // TerminalSurface applies previewBackgroundOpacity instead of painting
      // an opaque 0xFF cell rect over the background shader.
      expect(buf.getBackground(gutterW + 2, 3), equals(0));
      expect(buf.getBackground(gutterW + 30, 3), equals(0));
      // Gutter cell in BG preview mode also uses default bg == 0.
      expect(buf.getBackground(1, 3), equals(0));
    });

    test('supports inline Save As prompt via Alt+Shift+S and [Save As] chip with filename validation and auto-.glsl suffix', () async {
      final savedCalls = <(String, String?, String)>[];
      final controller = ShaderEditorController(
        shaderName: 'shader_1.glsl',
        sourcePath: null,
        initialSource: 'void mainImage(out vec4 c, in vec2 f) {}',
        onSave: (name, path, src) async {
          savedCalls.add((name, path, src));
          return true;
        },
      );
      final pane = ShaderEditorPane(
        paneId: 'save-as-pane',
        controller: controller,
        initialCols: 120,
        initialRows: 12,
      );
      addTearDown(() {
        pane.dispose();
        controller.dispose();
      });

      // Header shows [Save As] chip for untitled shaders.
      expect(_rowText(pane.readDisplayBuffer(), 0), contains('[Save As]'));

      // Trigger Save As via Alt+Shift+S -> opens inline prompt & hides body cursor.
      pane.handleInputEvent(
        const ev.KeyEvent(
          's',
          ev.KeyType.character,
          modifiers: {ev.Modifier.alt, ev.Modifier.shift},
        ),
      );
      expect(controller.promptingSaveAs, isTrue);
      expect(controller.saveAsDraftName, equals('shader_1.glsl'));
      expect(pane.readCursorVisible(), isFalse);
      expect(
        _rowText(pane.readDisplayBuffer(), 0),
        contains('Save As:  shader_1.glsl█'),
      );

      // Ctrl+U clears draft, typing invalid path triggers validation error.
      pane.handleInputEvent(
        const ev.KeyEvent(
          'u',
          ev.KeyType.character,
          modifiers: {ev.Modifier.control},
        ),
      );
      expect(controller.saveAsDraftName, isEmpty);
      pane.handleCommittedText('../bad');
      pane.handleInputEvent(const ev.KeyEvent('', ev.KeyType.enter));
      await Future<void>.delayed(Duration.zero);
      expect(controller.promptingSaveAs, isTrue);
      expect(controller.saveAsError, isNotNull);
      expect(savedCalls, isEmpty);

      // Clear, type valid stem without extension, backspace 1 char, re-type, Enter -> saves with .glsl.
      pane.handleInputEvent(
        const ev.KeyEvent(
          'u',
          ev.KeyType.character,
          modifiers: {ev.Modifier.control},
        ),
      );
      pane.handleCommittedText('aurora_ringx');
      pane.handleInputEvent(const ev.KeyEvent('', ev.KeyType.backspace));
      pane.handleInputEvent(const ev.KeyEvent('s', ev.KeyType.character));
      pane.handleInputEvent(const ev.KeyEvent('', ev.KeyType.enter));
      await Future<void>.delayed(Duration.zero);

      expect(controller.promptingSaveAs, isFalse);
      expect(controller.shaderName, equals('aurora_rings.glsl'));
      expect(controller.sourcePath, equals('aurora_rings.glsl'));
      expect(controller.isDirty, isFalse);
      expect(savedCalls, hasLength(1));
      expect(savedCalls.single.$1, equals('aurora_rings.glsl'));
      expect(savedCalls.single.$2, isNull);
      expect(
        _rowText(pane.readDisplayBuffer(), 0),
        contains('aurora_rings.glsl'),
      );

      // Esc cancels Save As without saving.
      controller.beginSaveAs();
      expect(controller.promptingSaveAs, isTrue);
      pane.handleInputEvent(const ev.KeyEvent('', ev.KeyType.escape));
      expect(controller.promptingSaveAs, isFalse);
    });

    test('selects and deletes multi-line code blocks with Shift+Down and Backspace in ShaderEditorPane', () {
      const source =
          'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
          '  float a = 1.0;\n'
          '  float b = 2.0;\n'
          '  fragColor = vec4(1.0);\n'
          '}';
      final controller = ShaderEditorController(
        shaderName: 'select.glsl',
        initialSource: source,
      );
      final pane = ShaderEditorPane(
        paneId: 'select-pane',
        controller: controller,
        initialCols: 90,
        initialRows: 12,
      );
      addTearDown(() {
        pane.dispose();
        controller.dispose();
      });

      // Move to line 2 col 0, select lines 2 & 3 with Shift+Down twice.
      pane.handleInputEvent(const ev.KeyEvent('', ev.KeyType.down));
      pane.handleInputEvent(
        const ev.KeyEvent('', ev.KeyType.down, modifiers: {ev.Modifier.shift}),
      );
      pane.handleInputEvent(
        const ev.KeyEvent('', ev.KeyType.down, modifiers: {ev.Modifier.shift}),
      );
      expect(
        controller.textController.selectedText,
        equals('  float a = 1.0;\n  float b = 2.0;\n'),
      );

      // Backspace removes both lines in one undoable step.
      pane.handleInputEvent(const ev.KeyEvent('', ev.KeyType.backspace));
      expect(
        controller.source,
        equals(
          'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
          '  fragColor = vec4(1.0);\n'
          '}',
        ),
      );

      // Ctrl+Z restores the deleted block completely.
      pane.handleInputEvent(
        const ev.KeyEvent(
          'z',
          ev.KeyType.character,
          modifiers: {ev.Modifier.control},
        ),
      );
      expect(controller.source, equals(source));
    });

    test('drops stale in-flight compile during debounce window, rejects dotfile/illegal Save As names, and shows inline error on failed saveAs', () async {
      // M3: Empty-stem dotfiles and Windows-illegal chars rejected.
      expect(ShaderEditorController.normalizeSaveAsFilename('.glsl'), isNull);
      expect(ShaderEditorController.normalizeSaveAsFilename('.frag'), isNull);
      expect(
        ShaderEditorController.normalizeSaveAsFilename('bad:name.glsl'),
        isNull,
      );
      expect(
        ShaderEditorController.normalizeSaveAsFilename('bad*name'),
        isNull,
      );

      const validShader =
          'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
          '  fragColor = vec4(1.0);\n'
          '}';
      final firstCompile = Completer<List<ShaderDiagnostic>>();
      var compileCalls = 0;
      final controller = ShaderEditorController(
        shaderName: 'race.glsl',
        initialSource: validShader,
        debounceDuration: const Duration(seconds: 10),
        onCompile: (source, mode) {
          compileCalls++;
          if (compileCalls == 1) return firstCompile.future;
          return Future<List<ShaderDiagnostic>>.value(
            const <ShaderDiagnostic>[],
          );
        },
        onSave: (_, _, _) async => false,
      );
      addTearDown(controller.dispose);

      // Start compile generation 1.
      final firstRun = controller.triggerCompileNow();
      expect(controller.isCompiling, isTrue);

      // Edit before generation 1 finishes; debounce window is 10s.
      controller.textController.text = '$validShader\n// edit 2';
      expect(controller.isCompiling, isFalse);

      // Resolve stale generation 1 BEFORE debounce timer fires.
      firstCompile.complete(const <ShaderDiagnostic>[
        ShaderDiagnostic(
          severity: ShaderDiagnosticSeverity.error,
          origin: ShaderDiagnosticOrigin.compiler,
          message: 'stale error from gen 1',
          line: 2,
          column: 1,
        ),
      ]);
      await firstRun;

      // Stale error must NOT overwrite diagnostics during debounce window.
      expect(
        controller.diagnostics.where(
          (d) => d.origin == ShaderDiagnosticOrigin.compiler,
        ),
        isEmpty,
      );

      // L2: Failed saveAs sets inline error and keeps Save As prompt open.
      controller.beginSaveAs();
      controller.clearSaveAsDraft();
      controller.appendSaveAsText('failing_name');
      final saveResult = await controller.confirmSaveAs();
      expect(saveResult, isFalse);
      expect(controller.promptingSaveAs, isTrue);
      expect(controller.saveAsError, contains('failing_name.glsl'));
    });
  });

  group('PR #475 review regression coverage (controller, pane, view)', () {
    test('H3: jumpToDiagnostic and insertStageAnnotation align grapheme offsets on CRLF buffers', () {
      const crlf =
          '// @fterm-stage: bg\r\n'
          '// comment\r\n'
          'void mainImage(out vec4 c, in vec2 p) {\r\n'
          '  discard;\r\n'
          '}\r\n';
      final ctrl = ShaderEditorController(
        shaderName: 'win.glsl',
        initialSource: crlf,
      );
      addTearDown(ctrl.dispose);

      final idx = ctrl.diagnostics.indexWhere(
        (d) => d.message.contains('discard'),
      );
      expect(idx, greaterThanOrEqualTo(0));
      ctrl.jumpToDiagnostic(idx);
      final off = ctrl.textController.value.selection.baseOffset;
      expect(
        ctrl.source.characters.skip(off).take(7).string,
        equals('discard'),
      );

      // insertStageAnnotation on CRLF without existing directive preserves CRLF and cursor offset.
      const crlfNoStage =
          '// header\r\n'
          'void mainImage(out vec4 c, in vec2 p) {\r\n'
          '  c = vec4(1.0);\r\n'
          '}\r\n';
      final ctrl2 = ShaderEditorController(
        shaderName: 'win2.glsl',
        initialSource: crlfNoStage,
      );
      addTearDown(ctrl2.dispose);
      ctrl2.textController.value = tui.TextEditingValue(
        text: crlfNoStage,
        selection: const tui.TextSelection.collapsed(
          offset: 10, // start of 'void mainImage...'
          line: 1,
          column: 0,
        ),
      );
      ctrl2.insertStageAnnotation(ShaderStageHint.background);
      expect(ctrl2.source, startsWith('// @fterm-stage: bg\r\n'));
      final afterOff = ctrl2.textController.value.selection.baseOffset;
      expect(
        ctrl2.source.characters.skip(afterOff).take(14).string,
        equals('void mainImage'),
      );
    });

    test('H4: ShaderEditorPane.dispose preserves caller-injected controller and watchdog while disposing owned watchdog', () {
      final controller = ShaderEditorController(shaderName: 'owned.glsl');
      final sharedWatchdog = GpuFrameWatchdog();
      addTearDown(() {
        controller.dispose();
        sharedWatchdog.dispose();
      });

      final paneWithInjected = ShaderEditorPane(
        paneId: 'injected',
        controller: controller,
        gpuFrameWatchdog: sharedWatchdog,
      );
      paneWithInjected.dispose();

      expect(sharedWatchdog.isDisposed, isFalse);
      void noop() {}
      controller.addListener(noop);
      controller.removeListener(noop);

      final paneWithOwnedWatchdog = ShaderEditorPane(
        paneId: 'owned-wd',
        controller: controller,
      );
      final ownedWatchdog = paneWithOwnedWatchdog.gpuFrameWatchdog;
      paneWithOwnedWatchdog.dispose();
      expect(ownedWatchdog.isDisposed, isTrue);
    });

    test('H6: concurrent save() and saveAs() drop stale completions and preserve dirty close guard', () async {
      final saveCompleters = <Completer<bool>>[];
      final ctrl = ShaderEditorController(
        shaderName: 'race.glsl',
        initialSource: 'v0',
        onSave: (_, _, _) {
          final c = Completer<bool>();
          saveCompleters.add(c);
          return c.future;
        },
      );
      addTearDown(ctrl.dispose);

      // Stale save() must not revert clean state after newer save() succeeds.
      ctrl.textController.text = 'v1';
      final s1 = ctrl.save();
      ctrl.textController.text = 'v2';
      final s2 = ctrl.save();
      saveCompleters[1].complete(true);
      expect(await s2, isTrue);
      expect(ctrl.isDirty, isFalse);

      saveCompleters[0].complete(true);
      expect(await s1, isFalse);
      expect(ctrl.isDirty, isFalse);

      // Save completing for older snapshot while newer unsaved edit exists keeps confirmingClose active.
      ctrl.textController.text = 'v3';
      final s3 = ctrl.save();
      ctrl.textController.text = 'v4';
      expect(ctrl.requestClose(), isFalse);
      expect(ctrl.confirmingClose, isTrue);
      saveCompleters[2].complete(true);
      await s3;
      expect(ctrl.isDirty, isTrue);
      expect(ctrl.confirmingClose, isTrue);

      // Stale saveAs() must not overwrite shaderName/sourcePath set by newer saveAs().
      final a1 = ctrl.saveAs('first_name');
      final a2 = ctrl.saveAs('second_name');
      saveCompleters[4].complete(true);
      expect(await a2, isTrue);
      expect(ctrl.shaderName, equals('second_name.glsl'));
      saveCompleters[3].complete(true);
      expect(await a1, isFalse);
      expect(ctrl.shaderName, equals('second_name.glsl'));
      expect(ctrl.sourcePath, equals('second_name.glsl'));
    });

    testWidgets(
      'H7: keystroke and arrow move emit one buffer notification and large buffers debounce static diagnostics',
      (tester) async {
        const src =
            '// @fterm-stage: bg\n'
            'void mainImage(out vec4 c, in vec2 p) {\n'
            '  c = vec4(1.0);\n'
            '}\n';
        final ctrl = ShaderEditorController(
          shaderName: 'perf.glsl',
          initialSource: src,
        );
        final pane = ShaderEditorPane(
          paneId: 'perf',
          controller: ctrl,
          initialCols: 80,
          initialRows: 12,
        );
        addTearDown(() {
          pane.dispose();
          ctrl.dispose();
        });

        var notifies = 0;
        pane.bufferListenable.addListener(() => notifies++);

        pane.handleInputEvent(const ev.KeyEvent('a', ev.KeyType.character));
        expect(notifies, equals(1));

        notifies = 0;
        pane.handleInputEvent(const ev.KeyEvent('', ev.KeyType.right));
        expect(notifies, equals(1));

        notifies = 0;
        pane.handleCommittedText('b');
        expect(notifies, equals(1));

        // Large buffer (>= 8192 chars) debounces static diagnostics instead of running synchronously per edit.
        final padding = List<String>.filled(
          260,
          '// 0123456789abcdef0123456789abcdef',
        ).join('\n');
        final largeSrc =
            '// @fterm-stage: bg\n$padding\n'
            'void mainImage(out vec4 c, in vec2 p) {\n'
            '  c = vec4(1.0);\n'
            '}\n';
        final largeCtrl = ShaderEditorController(
          shaderName: 'large.glsl',
          initialSource: largeSrc,
        );
        addTearDown(largeCtrl.dispose);
        expect(largeCtrl.diagnostics, isEmpty);

        largeCtrl.textController.text =
            '$largeSrc\n// trailing\nvoid extra() { discard; }\n';
        // Not yet evaluated synchronously during typing.
        expect(largeCtrl.diagnostics, isEmpty);

        // Fires after staticCheckDebounce (120ms).
        await tester.pump(ShaderEditorController.staticCheckDebounce);
        expect(
          largeCtrl.diagnostics.any((d) => d.message.contains('discard')),
          isTrue,
        );
      },
    );

    test('H8: Ctrl/Alt/Meta+N and Ctrl/Alt/Meta+Y do not discard or save-close in confirm prompt', () async {
      var closed = false;
      var saved = 0;
      final ctrl = ShaderEditorController(
        shaderName: 'd.glsl',
        initialSource: 'a',
        onSave: (_, _, _) async {
          saved++;
          return true;
        },
      );
      final pane = ShaderEditorPane(
        paneId: 'd',
        controller: ctrl,
        onCloseConfirmed: () => closed = true,
      );
      addTearDown(() {
        pane.dispose();
        ctrl.dispose();
      });

      pane.handleInputEvent(const ev.KeyEvent('x', ev.KeyType.character));
      expect(ctrl.requestClose(), isFalse);
      expect(ctrl.confirmingClose, isTrue);

      for (final mod in const [
        ev.Modifier.control,
        ev.Modifier.alt,
        ev.Modifier.meta,
      ]) {
        pane.handleInputEvent(
          ev.KeyEvent('n', ev.KeyType.character, modifiers: {mod}),
        );
        pane.handleInputEvent(
          ev.KeyEvent('y', ev.KeyType.character, modifiers: {mod}),
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(saved, equals(0));
      expect(ctrl.confirmingClose, isTrue);
    });

    test('M2: setRuntimeCompileError refreshes updated diagnostics list and compilerLog', () {
      const validBg =
          '// @fterm-stage: bg\nvoid mainImage(out vec4 c, in vec2 p) { c = vec4(1.0); }\n';
      final ctrl = ShaderEditorController(
        shaderName: 'rt.glsl',
        initialSource: validBg,
      );
      addTearDown(ctrl.dispose);

      const d1 = ShaderDiagnostic(
        severity: ShaderDiagnosticSeverity.error,
        origin: ShaderDiagnosticOrigin.compiler,
        message: 'first detail',
        line: 2,
        column: 5,
      );
      const d2 = ShaderDiagnostic(
        severity: ShaderDiagnosticSeverity.error,
        origin: ShaderDiagnosticOrigin.compiler,
        message: 'updated detail A',
        line: 2,
        column: 9,
      );
      const d3 = ShaderDiagnostic(
        severity: ShaderDiagnosticSeverity.error,
        origin: ShaderDiagnosticOrigin.compiler,
        message: 'updated detail B',
        line: 2,
        column: 15,
      );
      ctrl.setRuntimeCompileError(
        const ShaderCompileException(
          shaderId: 'editor:p1',
          lineNumber: 2,
          message: 'link fail',
          diagnostics: [d1],
        ),
      );
      expect(ctrl.diagnostics.map((d) => d.message), contains('first detail'));

      ctrl.setRuntimeCompileError(
        const ShaderCompileException(
          shaderId: 'editor:p1',
          lineNumber: 2,
          message: 'link fail',
          diagnostics: [d2, d3],
        ),
      );
      expect(
        ctrl.diagnostics.map((d) => d.message),
        containsAll(<String>['updated detail A', 'updated detail B']),
      );
    });

    test('M3: cycleStageAnnotation cycles bg -> fg -> both -> bg when static analysis fails', () {
      final ctrl = ShaderEditorController(
        shaderName: 'draft.glsl',
        initialSource: '// @fterm-stage: bg\nvoid incomplete(',
      );
      addTearDown(ctrl.dispose);
      expect(ctrl.lastAnalysis, isNull);

      ctrl.cycleStageAnnotation();
      expect(ctrl.source.split('\n').first, equals('// @fterm-stage: fg'));
      expect(ctrl.detectedStageHint, equals(ShaderStageHint.foreground));

      ctrl.cycleStageAnnotation();
      expect(ctrl.source.split('\n').first, equals('// @fterm-stage: both'));
      expect(ctrl.detectedStageHint, equals(ShaderStageHint.any));

      ctrl.cycleStageAnnotation();
      expect(ctrl.source.split('\n').first, equals('// @fterm-stage: bg'));
      expect(ctrl.detectedStageHint, equals(ShaderStageHint.background));
    });

    test('M7: Save & Close aborts on Esc cancel during async save and deduplicates double-clicks', () async {
      final gate1 = Completer<bool>();
      var saves = 0;
      var closes = 0;
      final ctrl = ShaderEditorController(
        shaderName: 'close.glsl',
        initialSource: 'a',
        onSave: (_, _, _) {
          saves++;
          return saves == 1 ? gate1.future : Future<bool>.value(true);
        },
      );
      final pane = ShaderEditorPane(
        paneId: 'm7',
        controller: ctrl,
        initialCols: 110,
        initialRows: 10,
        onCloseConfirmed: () => closes++,
      );
      addTearDown(() {
        pane.dispose();
        ctrl.dispose();
      });

      // Press Y, then Esc before save finishes -> must NOT close.
      ctrl.textController.insertText('b');
      ctrl.requestClose();
      pane.handleInputEvent(const ev.KeyEvent('y', ev.KeyType.character));
      pane.handleInputEvent(const ev.KeyEvent('escape', ev.KeyType.escape));
      gate1.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(saves, equals(1));
      expect(closes, equals(0));

      // Double-clicking [Y: Save & Close] runs only one save and one close.
      final gate2 = Completer<bool>();
      var saves2 = 0;
      var closes2 = 0;
      final ctrl2 = ShaderEditorController(
        shaderName: 'close2.glsl',
        initialSource: 'a',
        onSave: (_, _, _) {
          saves2++;
          return gate2.future;
        },
      );
      final pane2 = ShaderEditorPane(
        paneId: 'm7b',
        controller: ctrl2,
        initialCols: 110,
        initialRows: 10,
        onCloseConfirmed: () => closes2++,
      );
      addTearDown(() {
        pane2.dispose();
        ctrl2.dispose();
      });

      ctrl2.textController.insertText('c');
      ctrl2.requestClose();
      final btnX = _findInRow(
        pane2.readDisplayBuffer(),
        0,
        '[Y: Save & Close]',
      );
      expect(btnX, greaterThan(0));
      pane2.handleInputEvent(
        ev.MouseEvent(
          x: btnX + 2,
          y: 1,
          button: ev.MouseButton.left,
          type: ev.MouseEventType.press,
        ),
      );
      pane2.handleInputEvent(
        ev.MouseEvent(
          x: btnX + 2,
          y: 1,
          button: ev.MouseButton.left,
          type: ev.MouseEventType.press,
        ),
      );
      gate2.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(saves2, equals(1));
      expect(closes2, equals(1));
    });

    test(
      'M9: short and narrow split viewports avoid layout overflow caution tape',
      () {
        const src =
            'void mainImage(out vec4 c, in vec2 p) {\n'
            '  float a = 1.0 / 0.0;\n'
            '  float b = 2.0 / 0.0;\n'
            '  float d = 3.0 / 0.0;\n'
            '  float e = 4.0 / 0.0;\n'
            '  discard;\n'
            '}\n';
        final ctrl = ShaderEditorController(
          shaderName: 'tiny.glsl',
          initialSource: src,
        );
        final pane = ShaderEditorPane(
          paneId: 'tiny',
          controller: ctrl,
          initialCols: 60,
          initialRows: 5,
        );
        addTearDown(() {
          pane.dispose();
          ctrl.dispose();
        });

        for (final (cols, rows) in const <(int, int)>[
          (60, 5),
          (60, 2),
          (60, 1),
          (3, 6),
        ]) {
          pane.updateViewportSize(cols, rows, 8, 16);
          final buf = pane.readDisplayBuffer();
          expect(
            buf.characters.contains('▜'),
            isFalse,
            reason: 'Unexpected overflow caution tape at ${cols}x$rows',
          );
        }
      },
    );

    test('M10: normalizeSaveAsFilename rejects Windows reserved stems, trailing/leading dots, and DEL bytes', () {
      for (final bad in const <String>[
        'CON',
        'nul.glsl',
        'PRN.frag',
        'AUX',
        'COM1',
        'LPT9.glsl',
        'CON.extra.glsl',
        '...',
        '..glsl',
        '.glsl',
        '.frag',
        'foo.',
        'foo .glsl',
        'a\x7fb',
      ]) {
        expect(
          ShaderEditorController.normalizeSaveAsFilename(bad),
          isNull,
          reason: 'Expected "$bad" to be rejected',
        );
      }
      expect(
        ShaderEditorController.normalizeSaveAsFilename('my.effect.glsl'),
        equals('my.effect.glsl'),
      );
      expect(
        ShaderEditorController.normalizeSaveAsFilename('effect.FRAG'),
        equals('effect.FRAG'),
      );
      expect(
        ShaderEditorController.normalizeSaveAsFilename('aurora'),
        equals('aurora.glsl'),
      );
    });

    test('M11: newlines in diagnostics and shaderName are sanitized without truncating text or shifting hits', () {
      final ctrl = ShaderEditorController(
        shaderName: 'a\nb.glsl',
        initialSource:
            '// @fterm-stage: bg\nvoid mainImage(out vec4 c, in vec2 p) {}\n',
      );
      ctrl.setRuntimeCompileError(
        const ShaderCompileException(
          shaderId: 'editor:p1',
          message: 'GLSL error:\nundeclared identifier foo',
          lineNumber: 2,
        ),
      );
      final pane = ShaderEditorPane(
        paneId: 'p1',
        controller: ctrl,
        initialCols: 100,
        initialRows: 10,
      );
      addTearDown(() {
        pane.dispose();
        ctrl.dispose();
      });

      final buf = pane.readDisplayBuffer();
      final row0 = _rowText(buf, 0);
      expect(row0, contains('a b.glsl'));
      expect(row0, contains('[OFF|BG|FG]'));
      final lastRow = _rowText(buf, buf.height - 1);
      expect(lastRow, contains('GLSL error: undeclared identifier foo'));
    });

    test('L1: mouse release over header ends TextField drag selection', () {
      final ctrl = ShaderEditorController(
        shaderName: 'drag.glsl',
        initialSource:
            '// @fterm-stage: bg\nvoid mainImage(out vec4 c, in vec2 p) {}\n',
      );
      final pane = ShaderEditorPane(
        paneId: 'drag',
        controller: ctrl,
        initialCols: 80,
        initialRows: 12,
      );
      addTearDown(() {
        pane.dispose();
        ctrl.dispose();
      });

      pane.handleInputEvent(
        const ev.MouseEvent(
          x: 10,
          y: 3,
          button: ev.MouseButton.left,
          type: ev.MouseEventType.press,
        ),
      );
      pane.handleInputEvent(
        const ev.MouseEvent(
          x: 10,
          y: 1,
          button: ev.MouseButton.left,
          type: ev.MouseEventType.release,
        ),
      );
      pane.handleInputEvent(
        const ev.MouseEvent(
          x: 20,
          y: 3,
          button: ev.MouseButton.left,
          type: ev.MouseEventType.drag,
        ),
      );
      expect(ctrl.textController.selectedText, isEmpty);
    });

    test('L2: wide glyph clipped at right edge reports cursor invisible', () {
      final ctrl = ShaderEditorController(
        shaderName: 'wide.glsl',
        initialSource: '// @fterm-stage: bg\n// 中文测试中文\n',
      );
      final pane = ShaderEditorPane(
        paneId: 'wide',
        controller: ctrl,
        initialCols: 15,
        initialRows: 10,
      );
      addTearDown(() {
        pane.dispose();
        ctrl.dispose();
      });

      pane.handleInputEvent(const ev.KeyEvent('down', ev.KeyType.down));
      for (var i = 0; i < 6; i++) {
        pane.handleInputEvent(const ev.KeyEvent('right', ev.KeyType.right));
      }
      ctrl.textController.horizontalScrollOffset = 0;
      expect(pane.readCursorVisible(), isFalse);
    });

    test('L3: Save As validation error remains visible at 60 columns on header and ribbon', () async {
      final ctrl = ShaderEditorController(
        shaderName: 'my_long_shader_name.glsl',
        initialSource: 'a',
      );
      final pane = ShaderEditorPane(
        paneId: 'narrow-save-as',
        controller: ctrl,
        initialCols: 60,
        initialRows: 10,
      );
      addTearDown(() {
        pane.dispose();
        ctrl.dispose();
      });

      ctrl.beginSaveAs();
      ctrl.appendSaveAsText('/bad');
      await ctrl.confirmSaveAs();

      final buf = pane.readDisplayBuffer();
      final row0 = _rowText(buf, 0);
      final row1 = _rowText(buf, 1);
      expect(row0, contains('valid filename'));
      expect(row1, contains('Enter a valid filename'));
    });
  });
}
