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

    test(
      'H10: light themes enforce >= 3.0 contrast on hardcoded bracket colors',
      () {
        const code = 'void mainImage(out vec4 c) { c = vec4(sin(iTime)); }';
        for (final theme in const <TerminalColorTheme>[
          TerminalColorTheme.termuiLight,
          TerminalColorTheme.solarizedLight,
          TerminalColorTheme.highContrastLight,
        ]) {
          final hl = SyntaxTextHighlighter(
            language: kGlslLanguageId,
            theme: theme,
          );
          final buf = _paintRichText(
            hl.highlight(code),
            width: code.length + 2,
            height: 1,
          );
          for (var x = 0; x < code.length; x++) {
            if (buf.getCharacter(x, 0) == ' ') continue;
            final ratio = TerminalContrast.contrastRatio(
              Color.argb(buf.getForeground(x, 0)),
              theme.background,
            );
            expect(
              ratio,
              greaterThanOrEqualTo(3.0),
              reason:
                  'Low contrast for "${buf.getCharacter(x, 0)}" at col $x on $theme',
            );
          }
        }
      },
    );

    test(
      'H5 & M8: buildFieldSpan caches wrapped span and children are unmodifiable',
      () {
        final hl = SyntaxTextHighlighter(language: kGlslLanguageId);
        const code = 'float x = 1.0;';
        const bgStyle = Style(background: Color(0x14, 0x17, 0x1F));

        final plain = hl.highlight(code);
        expect(() => plain.children.clear(), throwsUnsupportedError);

        final withDiag = hl.highlight(
          code,
          diagnostics: const <TextDiagnosticSpan>[
            TextDiagnosticSpan(
              line: 1,
              column: 1,
              length: 5,
              underlineColor: Colors.red,
            ),
          ],
        );
        expect(() => withDiag.children.clear(), throwsUnsupportedError);

        final wrapped1 = hl.buildFieldSpan(code, bgStyle);
        final wrapped2 = hl.buildFieldSpan(code, bgStyle);
        expect(identical(wrapped1, wrapped2), isTrue);
        expect(() => wrapped1.children.clear(), throwsUnsupportedError);

        final wrappedOtherStyle = hl.buildFieldSpan(
          code,
          const Style(background: Color(0x22, 0x22, 0x22)),
        );
        expect(identical(wrapped1, wrappedOtherStyle), isFalse);
      },
    );

    test(
      'M6: malformed or conflicting grammarJson throws ArgumentError without poisoning cache',
      () {
        registerGlslLanguage();
        expect(
          () => SyntaxTextHighlighter(
            language: kGlslLanguageId,
            grammarJson: '{not valid json',
          ),
          throwsArgumentError,
        );
        expect(
          () => SyntaxTextHighlighter(
            language: 'bad_json_lang',
            grammarJson: '{bad',
          ),
          throwsArgumentError,
        );
        expect(
          () => SyntaxTextHighlighter(
            language: 'bad_array_lang',
            grammarJson: '[]',
          ),
          throwsArgumentError,
        );
        expect(
          () => SyntaxTextHighlighter(
            language: 'bad_empty_obj_lang',
            grammarJson: '{}',
          ),
          throwsArgumentError,
        );
        expect(
          () => SyntaxTextHighlighter(
            language: 'bad_regex_lang',
            grammarJson:
                '{"name":"X","scopeName":"source.x","patterns":[{"match":"[unclosed"}]}',
          ),
          throwsArgumentError,
        );
        // Broken #include throws ArgumentError and does NOT poison the language key.
        expect(
          () => SyntaxTextHighlighter(
            language: 'recoverable_lang',
            grammarJson:
                '{"name":"X","scopeName":"source.x","patterns":[{"include":"#missing"}]}',
          ),
          throwsArgumentError,
        );
        const validGrammar =
            '{"name":"Rec","scopeName":"source.rec","patterns":[{"name":"keyword.rec","match":"\\\\bfoo\\\\b"}]}';
        final recovered = SyntaxTextHighlighter(
          language: 'recoverable_lang',
          grammarJson: validGrammar,
        );
        expect(recovered.highlight('foo').children, isNotEmpty);

        // Idempotent re-registration succeeds; conflicting re-registration throws.
        expect(
          () => SyntaxTextHighlighter(
            language: 'recoverable_lang',
            grammarJson: validGrammar,
          ),
          returnsNormally,
        );
        expect(
          () => SyntaxTextHighlighter(
            language: 'recoverable_lang',
            grammarJson:
                '{"name":"Rec2","scopeName":"source.rec2","patterns":[{"name":"keyword.rec2","match":"\\\\bbar\\\\b"}]}',
          ),
          throwsArgumentError,
        );
      },
    );

    test(
      'M7: 300 diagnostic overlay stays fast on 2000-line doc and preserves overlap priority',
      () {
        final source = [
          for (var i = 0; i < 2000; i++)
            'vec4 c$i = texture(iChannel0, uv) + sin(iTime * 0.5) * float($i);',
        ].join('\n');
        final hl = SyntaxTextHighlighter(language: kGlslLanguageId)
          ..highlight(source);
        final diags = [
          for (var i = 1; i <= 300; i++)
            TextDiagnosticSpan(
              line: i * 6,
              column: 12,
              length: 7,
              underlineColor: Colors.red,
            ),
        ];
        // Warm up JIT for the diagnostic overlay path before measuring.
        hl.highlight(source, diagnostics: diags);
        var bestMs = 1 << 30;
        for (var run = 0; run < 3; run++) {
          final sw = Stopwatch()..start();
          hl.highlight(source, diagnostics: diags);
          sw.stop();
          if (sw.elapsedMilliseconds < bestMs) {
            bestMs = sw.elapsedMilliseconds;
          }
        }
        expect(bestMs, lessThan(100));

        // Overlapping diagnostics keep first-in-list priority and preserve non-overlapping tail.
        const overlapCode = 'float value = 1.0;';
        final overlapSpan = hl.highlight(
          overlapCode,
          diagnostics: const <TextDiagnosticSpan>[
            TextDiagnosticSpan(
              line: 1,
              column: 7,
              length: 3,
              underlineColor: Colors.red,
            ),
            TextDiagnosticSpan(
              line: 1,
              column: 5,
              length: 8,
              underlineColor: Colors.yellow,
            ),
          ],
        );
        final overlapBuf = _paintRichText(overlapSpan, width: 20, height: 1);
        expect(overlapBuf.getUnderlineColor(4, 0), equals(Colors.yellow.argb));
        expect(overlapBuf.getUnderlineColor(6, 0), equals(Colors.red.argb));
        expect(overlapBuf.getUnderlineColor(8, 0), equals(Colors.red.argb));
        expect(overlapBuf.getUnderlineColor(9, 0), equals(Colors.yellow.argb));
      },
    );

    test(
      'M10: mid-surrogate and combining-mark diagnostics snap to grapheme boundaries',
      () {
        final highlighter = SyntaxTextHighlighter(
          language: kGlslLanguageId,
          theme: TerminalColorTheme.termuiDark,
        );
        final emojiSpan = highlighter.highlight(
          '// 🔥 comment',
          diagnostics: const <TextDiagnosticSpan>[
            TextDiagnosticSpan(
              line: 1,
              column: 5,
              length: 1,
              underlineColor: Colors.yellow,
            ),
          ],
        );
        final emojiChars = <StyledChar>[];
        emojiSpan.buildStyledChars(emojiChars, Style.empty);
        expect(emojiChars[3].char, equals('🔥'));
        expect(emojiChars[3].style.underlineColor, equals(Colors.yellow));

        final combiningSpan = highlighter.highlight(
          '// e\u0301 ok',
          diagnostics: const <TextDiagnosticSpan>[
            TextDiagnosticSpan(
              line: 1,
              column: 5,
              length: 1,
              underlineColor: Colors.red,
            ),
          ],
        );
        final combiningChars = <StyledChar>[];
        combiningSpan.buildStyledChars(combiningChars, Style.empty);
        expect(combiningChars[3].char, equals('e\u0301'));
        expect(combiningChars[3].style.underlineColor, equals(Colors.red));
      },
    );
  });
}
