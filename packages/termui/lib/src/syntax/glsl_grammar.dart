import 'package:syntax_highlight_lite/syntax_highlight_lite.dart' as shl;

/// Language identifier used when registering GLSL with `syntax_highlight_lite`.
const String kGlslLanguageId = 'glsl';

/// TextMate JSON grammar for Ghostty and `fterm` Shadertoy GLSL shaders.
///
/// Covers standard GLSL comments, preprocessor directives, types, qualifiers,
/// control flow keywords, built-in math and texture functions, numeric
/// literals, `// @fterm-stage:` / `// @stage:` directives, and Shadertoy /
/// Ghostty / `fterm` uniform identifiers.
const String kGlslTextMateGrammarJson = r'''
{
  "name": "GLSL",
  "scopeName": "source.glsl",
  "patterns": [
    { "include": "#fterm-directive" },
    { "include": "#comments" },
    { "include": "#preprocessor" },
    { "include": "#strings" },
    { "include": "#shadertoy-uniforms" },
    { "include": "#builtin-variables" },
    { "include": "#keywords" },
    { "include": "#storage-types" },
    { "include": "#storage-modifiers" },
    { "include": "#constants" },
    { "include": "#builtin-functions" },
    { "include": "#numbers" }
  ],
  "repository": {
    "fterm-directive": {
      "name": "meta.directive.fterm.glsl",
      "match": "//[ \\t]*@(?:fterm-)?stage\\b[^\\n]*"
    },
    "comments": {
      "patterns": [
        {
          "name": "comment.line.double-slash.glsl",
          "match": "//[^\\n]*"
        },
        {
          "name": "comment.block.glsl",
          "begin": "/\\*",
          "end": "\\*/"
        }
      ]
    },
    "preprocessor": {
      "name": "meta.preprocessor.glsl",
      "match": "^[ \\t]*#[ \\t]*(?:define|undef|if|ifdef|ifndef|else|elif|endif|error|pragma|extension|version|line|include)\\b"
    },
    "strings": {
      "name": "string.quoted.double.glsl",
      "match": "\"(?:\\\\.|[^\"\\\\\\n])*\""
    },
    "shadertoy-uniforms": {
      "name": "variable.language.shadertoy.glsl",
      "match": "\\b(?:iChannel[0-3]|iChannelResolution|iPrevFrame|iResolution|iTime|iTimeDelta|iFrame|iFrameRate|iTimeCursorChange|iMouse|iDate|iPalette|iBackgroundColor|iForegroundColor|iCurrentCursor(?:Color|Style)?|iPreviousCursor(?:Color)?|iCursorColor|iCursorVisible|iFocus|iTimeFocus|iRegionRect|iCellSize|uParams[01]|CURSORSTYLE_\\w+)\\b"
    },
    "builtin-variables": {
      "name": "variable.language.glsl",
      "match": "\\b(?:gl_FragCoord|gl_FragColor|gl_FragDepth|gl_FrontFacing|gl_PointCoord|gl_Position|gl_VertexID|gl_InstanceID|fragColor|fragCoord)\\b"
    },
    "keywords": {
      "name": "keyword.control.glsl",
      "match": "\\b(?:if|else|for|while|do|switch|case|default|break|continue|return|discard)\\b"
    },
    "storage-types": {
      "name": "storage.type.glsl",
      "match": "\\b(?:void|bool|int|uint|float|double|struct|[bdiu]?vec[2-4]|d?mat[2-4](?:x[2-4])?|[iu]?sampler(?:2D|3D|Cube|2DArray|2DShadow))\\b"
    },
    "storage-modifiers": {
      "name": "storage.modifier.glsl",
      "match": "\\b(?:const|in|out|inout|uniform|layout|varying|attribute|flat|smooth|noperspective|centroid|invariant|precision|highp|mediump|lowp)\\b"
    },
    "constants": {
      "name": "constant.language.glsl",
      "match": "\\b(?:true|false)\\b"
    },
    "builtin-functions": {
      "name": "support.function.glsl",
      "match": "\\b(?:mainImage|texture(?:2D|Lod|Grad|Offset|Size)?|texelFetch|radians|degrees|sin|cos|tan|asin|acos|atan|sinh|cosh|tanh|pow|exp|log|exp2|log2|sqrt|inversesqrt|abs|sign|floor|trunc|round|ceil|fract|mod|min|max|clamp|mix|step|smoothstep|isnan|isinf|length|distance|dot|cross|normalize|faceforward|reflect|refract|matrixCompMult|outerProduct|transpose|determinant|inverse|dFdx|dFdy|fwidth|lessThan|lessThanEqual|greaterThan|greaterThanEqual|equal|notEqual|any|all|not)(?=\\s*\\()"
    },
    "numbers": {
      "name": "constant.numeric.glsl",
      "match": "\\b(?:0[xX][0-9a-fA-F]+[uU]?|(?:\\d+\\.\\d*|\\.\\d+)(?:[eE][+-]?\\d+)?[fF]?|\\d+[eE][+-]?\\d+[fF]?|\\d+[uU]?)\\b"
    }
  }
}
''';

/// Registers the GLSL TextMate grammar (`'glsl'`) with `syntax_highlight_lite`.
///
/// Safe to call multiple times; subsequent calls are no-ops.
void registerGlslLanguage() {
  shl.Highlighter.addLanguage(kGlslLanguageId, kGlslTextMateGrammarJson);
}
