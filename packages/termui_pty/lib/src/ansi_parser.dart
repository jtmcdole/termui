import 'dart:math' as math;

/// Interface for receiving parsed ANSI terminal sequences.
abstract interface class TerminalHandler {
  /// Print raw printable text.
  void printText(String text);

  /// Execute a C0/C1 control character (e.g., \n, \r, \b).
  void execute(int charCode);

  /// Execute a CSI (Control Sequence Introducer) command.
  ///
  /// When any parameter contains colon-delimited ITU-T T.416 subparameters
  /// (e.g. `38:2::66:133:244` or `4:3`), [subparams] has the same length as
  /// [params], with `subparams[i]` holding the values after the first `:` for
  /// parameter `i` (or `null` when parameter `i` had no `:`). When no `:`
  /// appears in the sequence, [subparams] is `null`.
  void csi(
    String command,
    List<int> params, {
    String? intermediate,
    List<List<int>?>? subparams,
  });

  /// Execute an OSC (Operating System Command).
  void osc(int command, String payload);

  /// Execute a standard Escape sequence.
  void esc(String command);
}

enum _ParserState {
  ground,
  escape,
  escapeIntermediate,
  csiEntry,
  csiParam,
  csiIntermediate,
  csiIgnore,
  oscString,
  oscEscape,
  dcsString,
  dcsEscape,
}

enum _TmuxInner { ignored, payload, pendingSt, terminated }

/// A highly optimized VT100/ANSI state machine parser.
final class AnsiParser {
  static const int _maxOscLength = 8192;
  static const int _maxOsc52Length = 1_400_000;
  static const int _maxCsiParams = 64;
  static const int _maxCsiSubparams = 16;
  static const int _tmuxHeaderLength = 5;
  static const List<int> _tmuxOscPrefix = [
    0x74, // t
    0x6D, // m
    0x75, // u
    0x78, // x
    0x3B, // ;
    0x1B, // ESC
    0x5D, // ]
  ];

  /// The terminal handler that processes parsed escape sequences.
  final TerminalHandler handler;

  _ParserState _state = _ParserState.ground;
  final List<int> _textBuffer = [];
  final List<int> _params = [];
  final List<List<int>?> _subparams = [];
  List<int>? _currentSubparams;
  int _currentParam = 0;
  bool _hasParam = false;
  final List<int> _intermediates = [];
  final List<int> _oscBuffer = [];
  bool _oscOverflowed = false;
  int _dcsPrefixLen = -1;
  _TmuxInner _tmuxInner = .ignored;

  /// Creates a new [AnsiParser] instance bound to the given [handler].
  AnsiParser(this.handler);

  void _flushText() {
    if (_textBuffer.isNotEmpty) {
      final text = String.fromCharCodes(_textBuffer);
      handler.printText(text);
      _textBuffer.clear();
    }
  }

  bool _consumesRawControl(int c) =>
      _state == .oscString ||
      _state == .dcsString ||
      (_state == .dcsEscape && c == 0x1B && _dcsPrefixLen >= _tmuxHeaderLength);

  /// Parses a chunk of VT100/ANSI string text and updates the bound handler.
  void parse(String chunk) {
    final len = chunk.length;
    for (var i = 0; i < len; i++) {
      final c = chunk.codeUnitAt(i);
      if (c >= 0x00 && c <= 0x1F && !_consumesRawControl(c)) {
        _handleC0Control(c);
        continue;
      }
      _dispatchStateChar(c);
    }
    _flushText();
  }

  void _handleC0Control(int c) {
    if (_state == .oscEscape || _state == .dcsEscape) {
      _resetDcs();
      _state = .ground;
    }
    if (c == 0x1B) {
      _flushText();
      _state = _ParserState.escape;
      _intermediates.clear();
      return;
    }
    if (c == 0x18 || c == 0x1A) {
      _resetCsi();
      _state = .ground;
    }
    _execute(c);
  }

  void _dispatchStateChar(int c) {
    switch (_state) {
      case _ParserState.ground:
        _textBuffer.add(c);
      case _ParserState.escape:
        _handleEscape(c);
      case _ParserState.escapeIntermediate:
        _handleEscapeIntermediate(c);
      case _ParserState.csiEntry:
        _handleCsiEntry(c);
      case _ParserState.csiParam:
        _handleCsiParam(c);
      case _ParserState.csiIntermediate:
        _handleCsiIntermediate(c);
      case _ParserState.csiIgnore:
        if (c >= 0x40 && c <= 0x7E) {
          _state = _ParserState.ground;
        }
      case _ParserState.oscString:
        _handleOscChar(c);
      case _ParserState.oscEscape:
        _handleOscEscape(c);
      case .dcsString:
        _handleDcsChar(c);
      case .dcsEscape:
        _handleDcsEscape(c);
    }
  }

  static bool _isControlStringIntroducer(int c) =>
      c == 0x50 || c == 0x58 || c == 0x5E || c == 0x5F;

  void _handleEscape(int c) {
    if (c >= 0x20 && c <= 0x2F) {
      _intermediates.add(c);
      _state = _ParserState.escapeIntermediate;
      return;
    }
    if (c == 0x5B) {
      _resetCsi();
      _state = _ParserState.csiEntry;
      return;
    }
    if (c == 0x5D) {
      _resetOsc();
      _state = _ParserState.oscString;
      return;
    }
    if (_isControlStringIntroducer(c)) {
      _enterDcs(allowTmuxPassthrough: c == 0x50);
      return;
    }
    _state = _ParserState.ground;
    if (c != 0x60 && c < 0x7E) {
      handler.esc(String.fromCharCode(c));
    }
  }

  void _handleEscapeIntermediate(int c) {
    if (c >= 0x20 && c <= 0x2F) {
      _intermediates.add(c);
    } else if (c >= 0x30 && c <= 0x7E) {
      _state = _ParserState.ground;
      handler.esc(
        String.fromCharCodes(_intermediates) + String.fromCharCode(c),
      );
    }
  }

  void _resetCsi() {
    _params.clear();
    _subparams.clear();
    _currentSubparams = null;
    _currentParam = 0;
    _hasParam = false;
    _intermediates.clear();
  }

  void _handleCsiEntry(int c) {
    if (c >= 0x3C && c <= 0x3F) {
      _intermediates.add(c);
      _state = .csiParam;
    } else if (c >= 0x20 && c <= 0x7E) {
      _state = .csiParam;
      _handleCsiParam(c);
    }
  }

  void _finishParamSlot() {
    final value = _hasParam ? _currentParam : 0;
    if (_currentSubparams case final subparams?) {
      if (subparams.length < _maxCsiSubparams) {
        subparams.add(value);
      }
      _currentSubparams = null;
    } else if (_params.length < _maxCsiParams) {
      _params.add(value);
      if (_subparams.isNotEmpty) {
        _subparams.add(null);
      }
    }
    _currentParam = 0;
    _hasParam = false;
  }

  void _advanceSubparam() {
    final value = _hasParam ? _currentParam : 0;
    if (_currentSubparams case final subparams?) {
      if (subparams.length < _maxCsiSubparams) {
        subparams.add(value);
      }
    } else if (_params.length < _maxCsiParams) {
      while (_subparams.length < _params.length) {
        _subparams.add(null);
      }
      _params.add(value);
      final list = <int>[];
      _currentSubparams = list;
      _subparams.add(list);
    }
    _currentParam = 0;
    _hasParam = false;
  }

  void _flushCurrentParam() {
    if (_currentSubparams != null || _hasParam || _params.isNotEmpty) {
      _finishParamSlot();
    }
  }

  void _handleCsiParam(int c) {
    if (c >= 0x30 && c <= 0x39) {
      _currentParam = math.min(0xFFFF, (_currentParam * 10) + (c - 0x30));
      _hasParam = true;
    } else if (c == 0x3B) {
      _finishParamSlot();
    } else if (c == 0x3A) {
      _advanceSubparam();
    } else if (c >= 0x20 && c <= 0x2F) {
      _flushCurrentParam();
      _intermediates.add(c);
      _state = .csiIntermediate;
    } else if (c >= 0x40 && c <= 0x7E) {
      _flushCurrentParam();
      _state = .ground;
      _dispatchCsi(c);
    } else if (c >= 0x3C && c <= 0x3F) {
      _resetCsi();
      _state = .csiIgnore;
    }
  }

  void _handleCsiIntermediate(int c) {
    if (c >= 0x20 && c <= 0x2F) {
      _intermediates.add(c);
    } else if (c >= 0x40 && c <= 0x7E) {
      _state = .ground;
      _dispatchCsi(c);
    } else if (c >= 0x30 && c <= 0x3F) {
      _resetCsi();
      _state = .csiIgnore;
    }
  }

  void _handleOscChar(int c) {
    if (c == 0x07) {
      _state = _ParserState.ground;
      _finishOsc();
    } else if (c == 0x1B) {
      _state = _ParserState.oscEscape;
    } else if (c == 0x18 || c == 0x1A) {
      _resetOsc();
      _state = _ParserState.ground;
    } else if (c >= 0x20) {
      _appendOscChar(c);
    }
  }

  void _handleOscEscape(int c) {
    if (c == 0x5C) {
      _state = _ParserState.ground;
      _finishOsc();
      return;
    }
    _resetOsc();
    _intermediates.clear();
    _handleEscape(c);
  }

  void _appendOscChar(int c) {
    if (_oscOverflowed) return;
    final limit = _isOsc52Prefix() ? _maxOsc52Length : _maxOscLength;
    if (_oscBuffer.length < limit) {
      _oscBuffer.add(c);
    } else {
      _oscBuffer.clear();
      _oscOverflowed = true;
    }
  }

  bool _isOsc52Prefix() =>
      _oscBuffer.length >= 3 &&
      _oscBuffer[0] == 0x35 &&
      _oscBuffer[1] == 0x32 &&
      _oscBuffer[2] == 0x3B;

  void _finishOsc() {
    if (!_oscOverflowed) {
      _dispatchOsc();
    }
    _resetOsc();
  }

  void _resetOsc() {
    _oscBuffer.clear();
    _oscOverflowed = false;
  }

  void _enterDcs({required bool allowTmuxPassthrough}) {
    _resetOsc();
    _dcsPrefixLen = allowTmuxPassthrough ? 0 : -1;
    _tmuxInner = allowTmuxPassthrough ? .payload : .ignored;
    _state = .dcsString;
  }

  void _handleDcsChar(int c) {
    switch (c) {
      case 0x1B:
        _state = .dcsEscape;
      case 0x9C:
        _state = .ground;
        _finishDcs();
      case 0x18 || 0x1A:
        _resetDcs();
        _state = .ground;
      default:
        _appendDcsChar(c);
    }
  }

  void _handleDcsEscape(int c) {
    if (c == 0x5C) {
      _state = .ground;
      _finishDcs();
      return;
    }
    if (c == 0x1B && _dcsPrefixLen >= _tmuxHeaderLength) {
      _state = .dcsString;
      _appendDcsChar(0x1B);
      return;
    }
    _resetDcs();
    _intermediates.clear();
    _handleEscape(c);
  }

  void _appendDcsChar(int c) {
    if (_dcsPrefixLen < 0 || _tmuxInner == .ignored) return;
    if (_dcsPrefixLen < _tmuxOscPrefix.length) {
      _advanceTmuxOscPrefix(c);
      return;
    }
    _tmuxInner = switch (_tmuxInner) {
      .payload when c == 0x07 => .terminated,
      .payload when c == 0x1B => .pendingSt,
      .pendingSt => c == 0x5C ? .terminated : .ignored,
      final state => state,
    };
    if (_tmuxInner == .payload && c >= 0x20) {
      _appendOscChar(c);
    }
  }

  void _advanceTmuxOscPrefix(int c) {
    if (c == _tmuxOscPrefix[_dcsPrefixLen]) {
      _dcsPrefixLen++;
      return;
    }
    if (_dcsPrefixLen < _tmuxHeaderLength) _dcsPrefixLen = -1;
    _tmuxInner = .ignored;
  }

  void _finishDcs() {
    if (_tmuxInner == .terminated) {
      _finishOsc();
    }
    _resetDcs();
  }

  void _resetDcs() {
    _resetOsc();
    _dcsPrefixLen = -1;
    _tmuxInner = .ignored;
  }

  void _execute(int charCode) {
    _flushText();
    handler.execute(charCode);
  }

  void _dispatchCsi(int commandCode) {
    final command = String.fromCharCode(commandCode);
    final intermediate = _intermediates.isNotEmpty
        ? String.fromCharCodes(_intermediates)
        : null;
    final params = [..._params];
    final subparams = _subparams.isNotEmpty ? [..._subparams] : null;
    _resetCsi();
    handler.csi(
      command,
      params,
      intermediate: intermediate,
      subparams: subparams,
    );
  }

  void _dispatchOsc() {
    final oscString = String.fromCharCodes(_oscBuffer);
    final semi = oscString.indexOf(';');
    final command =
        int.tryParse(semi < 0 ? oscString : oscString.substring(0, semi)) ?? -1;
    final payload = semi < 0 ? '' : oscString.substring(semi + 1);
    handler.osc(command, payload);
  }
}
