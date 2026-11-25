import 'package:termui/syntax.dart';
import 'package:termui/termui.dart';
import 'package:test/test.dart';

Buffer _paintRichText(TextSpan span, {int width = 80, int height = 10}) {
  final widget = RichText(text: span, wrap: false);
  final element = widget.createElement();
  element.mount(null);
  element.layout(BoxConstraints.tight(Size(width, height)));
  final buffer = Buffer.blank(width, height);
  element.paint(buffer, Offset.zero);
  element.unmount();
  return buffer;
}

void main() {
  group('GLSL syntax highlighting via RichText', () {
    test(
      'tokenizes directives, comments, keywords, types, functions, numbers, and Shadertoy uniforms',
      () {
        registerGlslLanguage();
        final highlighter = SyntaxTextHighlighter(
          language: kGlslLanguageId,
          theme: TerminalColorTheme.termuiDark,
        );

        const source =
            '// @fterm-stage: fg\n'
            '// regular comment\n'
            'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
            '  vec2 uv = fragCoord / iResolution.xy;\n'
            '  vec4 col = texture(iChannel0, uv) + uParams0 * 0.5;\n'
            '  if (iCurrentCursorStyle == CURSORSTYLE_BLOCK) return;\n'
            '  fragColor = col;\n'
            '}';

        final span = highlighter.highlight(source);
        final buffer = _paintRichText(span, width: 70, height: 8);

        // Line 0: // @fterm-stage: fg -> bold directive distinct from plain comment.
        final directiveFg = buffer.getForeground(0, 0);
        final commentFg = buffer.getForeground(0, 1);
        expect(directiveFg, isNot(equals(0)));
        expect(directiveFg, isNot(equals(Colors.black.argb)));
        expect(directiveFg, isNot(equals(commentFg)));
        expect(Modifier.has(buffer.getModifiers(0, 0), Modifier.bold), isTrue);
        expect(
          Modifier.has(buffer.getModifiers(0, 1), Modifier.italic),
          isTrue,
        );

        // Line 2: 'void' (type, bold) at col 0, 'mainImage' (function) at col 5.
        final voidFg = buffer.getForeground(0, 2);
        final mainImageFg = buffer.getForeground(5, 2);
        expect(voidFg, isNot(equals(Colors.black.argb)));
        expect(mainImageFg, isNot(equals(voidFg)));
        expect(Modifier.has(buffer.getModifiers(0, 2), Modifier.bold), isTrue);

        // Line 3: 'iResolution' (Shadertoy uniform, bold) starts at col 24.
        final iResCol = '  vec2 uv = fragCoord / '.length;
        expect(buffer.getCharacter(iResCol, 3), equals('i'));
        final uniformFg = buffer.getForeground(iResCol, 3);
        expect(uniformFg, isNot(equals(voidFg)));
        expect(
          Modifier.has(buffer.getModifiers(iResCol, 3), Modifier.bold),
          isTrue,
        );

        // Line 4: 'iChannel0' and 'uParams0' share Shadertoy uniform styling.
        final iChanCol = '  vec4 col = texture('.length;
        final uParamsCol = '  vec4 col = texture(iChannel0, uv) + '.length;
        expect(buffer.getForeground(iChanCol, 4), equals(uniformFg));
        expect(buffer.getForeground(uParamsCol, 4), equals(uniformFg));

        // Line 5: 'if' and 'return' are keywords; 'CURSORSTYLE_BLOCK' is uniform.
        final ifCol = 2;
        final returnCol =
            '  if (iCurrentCursorStyle == CURSORSTYLE_BLOCK) '.length;
        final cursorStyleCol = '  if (iCurrentCursorStyle == '.length;
        expect(
          buffer.getForeground(ifCol, 5),
          equals(buffer.getForeground(returnCol, 5)),
        );
        expect(buffer.getForeground(cursorStyleCol, 5), equals(uniformFg));
      },
    );

    test(
      'never falls back to black text on dark themes for unstyled or unknown scopes',
      () {
        const customGrammar = r'''
{
  "name": "Custom",
  "scopeName": "source.custom",
  "patterns": [
    { "name": "meta.unthemed.custom", "match": "\\bmysteryToken\\b" }
  ]
}
''';
        final highlighter = SyntaxTextHighlighter(
          language: 'custom_unthemed_test',
          theme: TerminalColorTheme.solarizedDark,
          grammarJson: customGrammar,
        );

        final span = highlighter.highlight('plain mysteryToken 123');
        final buffer = _paintRichText(span, width: 30, height: 1);

        for (var x = 0; x < 'plain mysteryToken 123'.length; x++) {
          final ch = buffer.getCharacter(x, 0);
          if (ch == ' ') continue;
          final fg = buffer.getForeground(x, 0);
          expect(fg, isNot(equals(0)));
          expect(fg, isNot(equals(Colors.black.argb)));
        }

        // Switching to light theme updates colors and stays readable.
        highlighter.setTheme(TerminalColorTheme.termuiLight);
        final lightSpan = highlighter.highlight('plain mysteryToken 123');
        final lightBuffer = _paintRichText(lightSpan, width: 30, height: 1);
        expect(
          lightBuffer.getForeground(0, 0),
          isNot(equals(buffer.getForeground(0, 0))),
        );
        expect(highlighter.theme, equals(TerminalColorTheme.termuiLight));
      },
    );

    test(
      'reuses cached TextSpan on unchanged repaints and avoids re-tokenizing on diagnostic-only updates',
      () {
        final highlighter = SyntaxTextHighlighter(
          language: kGlslLanguageId,
          theme: TerminalColorTheme.termuiDark,
        );
        const code = 'vec4 c = vec4(1.0);';

        final first = highlighter.highlight(code);
        final second = highlighter.highlight(code);
        expect(identical(first, second), isTrue);
        expect(highlighter.debugHighlightCount, equals(1));

        // Diagnostic overlay update reuses base tokenization without re-parsing.
        const diag = TextDiagnosticSpan(
          line: 1,
          column: 10,
          length: 4,
          underlineColor: Colors.red,
        );
        final withDiag = highlighter.highlight(code, diagnostics: [diag]);
        final withDiagRepeat = highlighter.highlight(code, diagnostics: [diag]);
        expect(identical(withDiag, withDiagRepeat), isTrue);
        expect(highlighter.debugHighlightCount, equals(1));

        // Changing source code triggers a fresh tokenization pass.
        highlighter.highlight('vec4 d = vec4(2.0);');
        expect(highlighter.debugHighlightCount, equals(2));
      },
    );

    test(
      'overlays SGR 58 curly squiggles while preserving token foreground color',
      () {
        final highlighter = SyntaxTextHighlighter(
          language: kGlslLanguageId,
          theme: TerminalColorTheme.termuiDark,
        );
        const code = 'float x = iTime;\nvec3 bad = unknownVar;';
        const errorColor = Color(0xFF, 0x55, 0x55);
        const warnColor = Color(0xFF, 0xBB, 0x33);

        final cleanBuf = _paintRichText(
          highlighter.highlight(code),
          width: 40,
          height: 2,
        );
        final diagSpan = highlighter.highlight(
          code,
          diagnostics: const <TextDiagnosticSpan>[
            TextDiagnosticSpan(
              line: 1,
              column: 11,
              length: 5,
              underlineColor: warnColor,
              underlineStyle: UnderlineStyle.curly,
            ),
            TextDiagnosticSpan(
              line: 2,
              column: 12,
              length: 10,
              underlineColor: errorColor,
              underlineStyle: UnderlineStyle.curly,
            ),
          ],
        );
        final diagBuf = _paintRichText(diagSpan, width: 40, height: 2);

        // 'iTime' on line 0 cols 10..14 keeps its syntax foreground + gets amber curly squiggle.
        for (var col = 10; col < 15; col++) {
          expect(
            diagBuf.getForeground(col, 0),
            equals(cleanBuf.getForeground(col, 0)),
          );
          expect(diagBuf.getUnderlineColor(col, 0), equals(warnColor.argb));
          expect(
            Modifier.getUnderlineStyle(diagBuf.getModifiers(col, 0)),
            equals(UnderlineStyle.curly),
          );
        }
        // Adjacent ';' at col 15 has no squiggle.
        expect(diagBuf.getUnderlineColor(15, 0), equals(0));

        // 'unknownVar' on line 1 cols 11..20 gets red curly squiggle.
        for (var col = 11; col < 21; col++) {
          expect(diagBuf.getUnderlineColor(col, 1), equals(errorColor.argb));
          expect(
            Modifier.getUnderlineStyle(diagBuf.getModifiers(col, 1)),
            equals(UnderlineStyle.curly),
          );
        }
        expect(diagBuf.getUnderlineColor(10, 1), equals(0));
      },
    );

    test(
      'handles empty input, out-of-range diagnostics, and buildFieldSpan in TextField',
      () {
        final highlighter = SyntaxTextHighlighter(
          language: kGlslLanguageId,
          theme: TerminalColorTheme.termuiDark,
        );

        final emptySpan = highlighter.highlight('');
        expect(emptySpan.text, equals(''));

        const code = 'vec2 p = vec2(0.0);\n\nfloat y = 1.0;';
        final span = highlighter.highlight(
          code,
          diagnostics: const <TextDiagnosticSpan>[
            // Empty line 2 is skipped cleanly without throwing.
            TextDiagnosticSpan(
              line: 2,
              column: 1,
              length: 4,
              underlineColor: Colors.red,
            ),
            // Out-of-bounds line/column clamps safely to final line.
            TextDiagnosticSpan(
              line: 99,
              column: 99,
              length: 5,
              underlineColor: Colors.yellow,
            ),
          ],
        );
        final buf = _paintRichText(span, width: 30, height: 3);
        expect(buf.getUnderlineColor(13, 2), equals(Colors.yellow.argb));

        // Verify buildFieldSpan works directly with TextField.spanBuilder.
        final controller = TextEditingController(text: 'float a = 1.0;');
        final field = TextField(
          controller: controller,
          multiline: true,
          focused: false,
          style: const Style(background: Color(0x14, 0x17, 0x1F)),
          spanBuilder: (text, baseStyle) => highlighter.buildFieldSpan(
            text,
            baseStyle,
            diagnostics: const <TextDiagnosticSpan>[
              TextDiagnosticSpan(
                line: 1,
                column: 1,
                length: 5,
                underlineColor: Colors.red,
              ),
            ],
          ),
        );
        final element = field.createElement();
        element.mount(null);
        element.layout(BoxConstraints.tight(const Size(20, 2)));
        final fieldBuf = Buffer.blank(20, 2);
        element.paint(fieldBuf, Offset.zero);
        element.unmount();

        expect(fieldBuf.getCharacter(0, 0), equals('f'));
        expect(fieldBuf.getUnderlineColor(0, 0), equals(Colors.red.argb));
        expect(
          fieldBuf.getBackground(0, 0),
          equals(const Color(0x14, 0x17, 0x1F).argb),
        );
      },
    );

    test(
      'throws ArgumentError for unregistered language and highlights .5 and 1. floats',
      () {
        expect(
          () => SyntaxTextHighlighter(language: 'unregistered_lang_xyz'),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('grammarJson'),
            ),
          ),
        );

        final highlighter = SyntaxTextHighlighter(
          language: kGlslLanguageId,
          theme: TerminalColorTheme.termuiDark,
        );
        final span = highlighter.highlight('float a = .5 + 1.;');
        final buf = _paintRichText(span, width: 24, height: 1);
        // Leading-dot '.5' and trailing-dot '1.' should share numeric foreground.
        expect(buf.getForeground(10, 0), equals(buf.getForeground(11, 0)));
        expect(buf.getForeground(15, 0), equals(buf.getForeground(16, 0)));
        expect(buf.getForeground(10, 0), equals(buf.getForeground(15, 0)));
      },
    );
  });
}
