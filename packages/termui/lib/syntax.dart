/// Opt-in TextMate syntax highlighting bridge emitting `termui` [TextSpan]
/// trees for both `RichText` and `TextField.spanBuilder`.
library;

export 'src/syntax/glsl_grammar.dart'
    show kGlslLanguageId, kGlslTextMateGrammarJson, registerGlslLanguage;
export 'src/syntax/syntax_highlighter.dart'
    show SyntaxTextHighlighter, TextDiagnosticSpan;
