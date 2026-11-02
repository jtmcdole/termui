import 'dart:math' as math;

/// Interface for receiving parsed ANSI terminal sequences.
abstract interface class TerminalHandler {
  /// Print raw printable text.
  void printText(String text);

  /// Execute a C0/C1 control character (e.g., \n, \r, \b).
  void execute(int charCode);

  /// Execute a CSI (Control Sequence Introducer) command.
  void csi(String command, List<int> params, {String? intermediate});

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
}

/// A highly optimized VT100/ANSI state machine parser.
final class AnsiParser {
  static const int _maxOscLength = 8192;
  static const int _maxOsc52Length = 1_400_000;

  /// The terminal handler that processes parsed escape sequences.
  final TerminalHandler handler;

  _ParserState _state = _ParserState.ground;
  final List<int> _textBuffer = [];
  final List<int> _params = [];
  int _currentParam = 0;
  bool _hasParam = false;
  final List<int> _intermediates = [];
  final List<int> _oscBuffer = [];
  bool _oscOverflowed = false;

  /// Creates a new [AnsiParser] instance bound to the given [handler].
  AnsiParser(this.handler);

  void _flushText() {
    if (_textBuffer.isNotEmpty) {
      final text = String.fromCharCodes(_textBuffer);
      handler.printText(text);
      _textBuffer.clear();
    }
  }

  /// Parses a chunk of VT100/ANSI string text and updates the bound handler.
  void parse(String chunk) {
    final len = chunk.length;
    for (var i = 0; i < len; i++) {
      final c = chunk.codeUnitAt(i);
      if (c >= 0x00 && c <= 0x1F && _state != _ParserState.oscString) {
        _handleC0Control(c);
        continue;
      }
      _dispatchStateChar(c);
    }
    _flushText();
  }

  void _handleC0Control(int c) {
    if (_state == _ParserState.oscEscape) {
      _resetOsc();
      _state = _ParserState.ground;
    }
    if (c == 0x1B) {
      _flushText();
      _state = _ParserState.escape;
      _intermediates.clear();
      return;
    }
    if (c == 0x18 || c == 0x1A) {
      _state = _ParserState.ground;
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
    }
  }

  void _handleEscape(int c) {
    if (c >= 0x20 && c <= 0x2F) {
      _intermediates.add(c);
      _state = _ParserState.escapeIntermediate;
      return;
    }
    if (c == 0x5B) {
      _params.clear();
      _currentParam = 0;
      _hasParam = false;
      _intermediates.clear();
      _state = _ParserState.csiEntry;
      return;
    }
    if (c == 0x5D) {
      _resetOsc();
      _state = _ParserState.oscString;
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

  void _handleCsiEntry(int c) {
    if (c >= 0x30 && c <= 0x39) {
      _currentParam = math.min(0xFFFF, (_currentParam * 10) + (c - 0x30));
      _hasParam = true;
      _state = _ParserState.csiParam;
    } else if (c == 0x3B) {
      _params.add(0);
      _currentParam = 0;
      _hasParam = false;
      _state = _ParserState.csiParam;
    } else if (c >= 0x3C && c <= 0x3F) {
      _intermediates.add(c);
      _state = _ParserState.csiParam;
    } else if (c >= 0x20 && c <= 0x2F) {
      _intermediates.add(c);
      _state = _ParserState.csiIntermediate;
    } else if (c >= 0x40 && c <= 0x7E) {
      _state = _ParserState.ground;
      _dispatchCsi(c);
    }
  }

  void _flushCurrentParam() {
    if (_hasParam) {
      _params.add(_currentParam);
      _currentParam = 0;
      _hasParam = false;
    }
  }

  void _handleCsiParam(int c) {
    if (c >= 0x30 && c <= 0x39) {
      _currentParam = math.min(0xFFFF, (_currentParam * 10) + (c - 0x30));
      _hasParam = true;
    } else if (c == 0x3B) {
      _params.add(_hasParam ? _currentParam : 0);
      _currentParam = 0;
      _hasParam = false;
    } else if (c >= 0x20 && c <= 0x2F) {
      _flushCurrentParam();
      _intermediates.add(c);
      _state = _ParserState.csiIntermediate;
    } else if (c >= 0x40 && c <= 0x7E) {
      _flushCurrentParam();
      _state = _ParserState.ground;
      _dispatchCsi(c);
    } else if (c == 0x3A || (c >= 0x3C && c <= 0x3F)) {
      _state = _ParserState.csiIgnore;
    }
  }

  void _handleCsiIntermediate(int c) {
    if (c >= 0x20 && c <= 0x2F) {
      _intermediates.add(c);
    } else if (c >= 0x40 && c <= 0x7E) {
      _state = _ParserState.ground;
      _dispatchCsi(c);
    } else if (c >= 0x30 && c <= 0x3F) {
      _state = _ParserState.csiIgnore;
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

  void _execute(int charCode) {
    _flushText();
    handler.execute(charCode);
  }

  void _dispatchCsi(int commandCode) {
    final command = String.fromCharCode(commandCode);
    final intermediate = _intermediates.isNotEmpty
        ? String.fromCharCodes(_intermediates)
        : null;
    handler.csi(command, List.from(_params), intermediate: intermediate);
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
