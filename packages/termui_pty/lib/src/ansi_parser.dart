import 'dart:io';

/// Interface for receiving parsed ANSI terminal sequences.
abstract class TerminalHandler {
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
}

/// A highly optimized VT100/ANSI state machine parser.
class AnsiParser {
  final TerminalHandler handler;

  _ParserState _state = _ParserState.ground;
  final List<int> _textBuffer = [];
  final List<int> _params = [];
  int _currentParam = 0;
  bool _hasParam = false;
  final List<int> _intermediates = [];
  final List<int> _oscBuffer = [];
  bool _isOscTitle = false;

  AnsiParser(this.handler);

  void _flushText() {
    if (_textBuffer.isNotEmpty) {
      final text = String.fromCharCodes(_textBuffer);
      _log('printText(${text.length} chars): "$text"');
      handler.printText(text);
      _textBuffer.clear();
    }
  }

  void _log(String message) {
    try {
      File('parser.log').writeAsStringSync('$message\n', mode: FileMode.append);
    } catch (_) {}
  }

  void parse(String chunk) {
    final len = chunk.length;
    for (var i = 0; i < len; i++) {
      final c = chunk.codeUnitAt(i);

      // Handle C0 controls everywhere except OSC string
      if (c >= 0x00 && c <= 0x1F && _state != _ParserState.oscString) {
        if (c == 0x1B) { // ESC
          _flushText();
          _state = _ParserState.escape;
          _intermediates.clear();
          continue;
        } else if (c == 0x18 || c == 0x1A) { // CAN, SUB
          _state = _ParserState.ground;
          _execute(c);
          continue;
        }
        // Other C0 controls execute immediately
        _execute(c);
        continue;
      }

      switch (_state) {
        case _ParserState.ground:
          _textBuffer.add(c);
          break;

        case _ParserState.escape:
          if (c >= 0x20 && c <= 0x2F) {
            _intermediates.add(c);
            _state = _ParserState.escapeIntermediate;
          } else if (c == 0x5B) { // '['
            _params.clear();
            _currentParam = 0;
            _hasParam = false;
            _intermediates.clear();
            _state = _ParserState.csiEntry;
          } else if (c == 0x5D) { // ']'
            _oscBuffer.clear();
            _isOscTitle = false;
            _state = _ParserState.oscString;
          } else if (c >= 0x30 && c <= 0x4F) {
            _state = _ParserState.ground;
            handler.esc(String.fromCharCode(c));
          } else if (c >= 0x50 && c <= 0x5E) {
            _state = _ParserState.ground;
            handler.esc(String.fromCharCode(c));
          } else if (c == 0x60 || (c >= 0x7E)) {
            _state = _ParserState.ground;
          } else {
            _state = _ParserState.ground;
            handler.esc(String.fromCharCode(c));
          }
          break;

        case _ParserState.escapeIntermediate:
          if (c >= 0x20 && c <= 0x2F) {
            _intermediates.add(c);
          } else if (c >= 0x30 && c <= 0x7E) {
            _state = _ParserState.ground;
            handler.esc(String.fromCharCodes(_intermediates) + String.fromCharCode(c));
          }
          break;

        case _ParserState.csiEntry:
          if (c >= 0x30 && c <= 0x39) { // 0-9
            _currentParam = (_currentParam * 10) + (c - 0x30);
            _hasParam = true;
            _state = _ParserState.csiParam;
          } else if (c == 0x3B) { // ';'
            _params.add(_hasParam ? _currentParam : 0);
            _currentParam = 0;
            _hasParam = false;
            _state = _ParserState.csiParam;
          } else if (c >= 0x3C && c <= 0x3F) { // < = > ?
            _intermediates.add(c);
            _state = _ParserState.csiParam;
          } else if (c >= 0x20 && c <= 0x2F) {
            _intermediates.add(c);
            _state = _ParserState.csiIntermediate;
          } else if (c >= 0x40 && c <= 0x7E) {
            _state = _ParserState.ground;
            _dispatchCsi(c);
          }
          break;

        case _ParserState.csiParam:
          if (c >= 0x30 && c <= 0x39) {
            _currentParam = (_currentParam * 10) + (c - 0x30);
            _hasParam = true;
          } else if (c == 0x3B) { // ';'
            _params.add(_hasParam ? _currentParam : 0);
            _currentParam = 0;
            _hasParam = false;
          } else if (c >= 0x20 && c <= 0x2F) {
            _intermediates.add(c);
            _state = _ParserState.csiIntermediate;
          } else if (c >= 0x40 && c <= 0x7E) {
            if (_hasParam) {
              _params.add(_currentParam);
            }
            _state = _ParserState.ground;
            _dispatchCsi(c);
          } else if (c == 0x3A || (c >= 0x3C && c <= 0x3F)) {
            _state = _ParserState.csiIgnore;
          }
          break;

        case _ParserState.csiIntermediate:
          if (c >= 0x20 && c <= 0x2F) {
            _intermediates.add(c);
          } else if (c >= 0x40 && c <= 0x7E) {
            _state = _ParserState.ground;
            _dispatchCsi(c);
          } else if (c >= 0x30 && c <= 0x3F) {
            _state = _ParserState.csiIgnore;
          }
          break;

        case _ParserState.csiIgnore:
          if (c >= 0x40 && c <= 0x7E) {
            _state = _ParserState.ground;
          }
          break;

        case _ParserState.oscString:
          if (c == 0x07) { // BEL
            _state = _ParserState.ground;
            _dispatchOsc();
          } else if (c == 0x1B) { // ESC (ST)
            _state = _ParserState.escape;
            _dispatchOsc();
          } else if (c >= 0x20) {
            _oscBuffer.add(c);
          }
          break;
      }
    }
    _flushText();
  }

  void _execute(int charCode) {
    _flushText();
    _log('execute(charCode: $charCode)');
    handler.execute(charCode);
  }

  void _dispatchCsi(int commandCode) {
    final command = String.fromCharCode(commandCode);
    final intermediate = _intermediates.isNotEmpty ? String.fromCharCodes(_intermediates) : null;
    _log('csi(command: "$command", params: $_params, intermediate: $intermediate)');
    handler.csi(command, List.from(_params), intermediate: intermediate);
  }

  void _dispatchOsc() {
    final oscString = String.fromCharCodes(_oscBuffer);
    final parts = oscString.split(';');
    if (parts.isNotEmpty) {
      final command = int.tryParse(parts[0]) ?? -1;
      final payload = parts.length > 1 ? parts.sublist(1).join(';') : '';
      _log('osc(command: $command, payload: "$payload")');
      handler.osc(command, payload);
    }
  }
}
