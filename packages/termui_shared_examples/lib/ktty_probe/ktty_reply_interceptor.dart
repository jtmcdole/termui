import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'ktty_probe_report.dart';

enum _InterceptorState { ground, esc, csi, osc, dcs, apc, stringEsc }

/// Stateful wire-stream pre-filter that intercepts terminal query responses,
/// updates [report], and forwards user input sequences cleanly to `InputParser`.
final class KttyReplyInterceptor {
  static const int _maxSequenceBytes = 65536;

  static final RegExp _decrqmRegex = RegExp(r'^\?(\d+);(\d+)\$y$');
  static final RegExp _kittyKbQueryRegex = RegExp(r'^\?(\d+)u$');
  static final RegExp _xtwinops16Regex = RegExp(r'^6;(\d+);(\d+)t$');
  static final RegExp _xtwinops18Regex = RegExp(r'^8;(\d+);(\d+)t$');
  static final RegExp _sgrMouseBodyRegex = RegExp(
    r'^<(\d+);(\d+);(\d+)([Mm])$',
  );
  static final RegExp _da1Regex = RegExp(r'^\?([\d;]*)c$');
  static final RegExp _da2Regex = RegExp(r'^>([\d;]*)c$');
  static final RegExp _apcIdRegex = RegExp(r'i=(\d+)');
  static final RegExp _rgbSlashRegex = RegExp(
    r'^rgb:([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})$',
  );
  static final RegExp _hexHashRegex = RegExp(r'^#([0-9a-fA-F]{6})$');

  /// Target capability report populated as replies arrive.
  final KttyProbeReport report;

  /// Whether `?1016` SGR-Pixels mouse mode has been requested by the probe app.
  bool sgrPixelsRequested = false;

  _InterceptorState _state = .ground;
  _InterceptorState _stringKind = .osc;
  final List<int> _seqBytes = [];
  bool _overflowed = false;

  /// Creates a [KttyReplyInterceptor] updating [report].
  KttyReplyInterceptor(this.report);

  /// Whether the interceptor is currently holding a lone `ESC` (`0x1B`) byte
  /// awaiting disambiguation from a split escape sequence.
  bool get hasPendingBareEsc => _state == .esc;

  /// Processes a raw input [chunk], updating [report] for recognized terminal
  /// query replies and returning passthrough bytes for `InputParser`.
  Uint8List processChunk(List<int> chunk) {
    final passthrough = BytesBuilder(copy: false);
    for (final byte in chunk) {
      _processByte(byte, passthrough);
    }
    return passthrough.takeBytes();
  }

  /// Flushes a pending bare `ESC` (`0x1B`) byte as standalone user input.
  Uint8List flushPendingEsc() {
    if (_state != .esc) return Uint8List(0);
    _state = .ground;
    _seqBytes.clear();
    return Uint8List.fromList(const [0x1B]);
  }

  void _processByte(int byte, BytesBuilder out) {
    switch (_state) {
      case .ground:
        _handleGround(byte, out);
      case .esc:
        _handleEsc(byte, out);
      case .csi:
        _handleCsi(byte, out);
      case .osc || .dcs || .apc:
        _handleControlString(byte, out);
      case .stringEsc:
        _handleStringEsc(byte, out);
    }
  }

  void _handleGround(int byte, BytesBuilder out) {
    if (byte == 0x1B) {
      _state = .esc;
      _seqBytes
        ..clear()
        ..add(0x1B);
      _overflowed = false;
      return;
    }
    out.addByte(byte);
  }

  void _handleEsc(int byte, BytesBuilder out) {
    switch (byte) {
      case 0x5B: // '[' -> CSI
        _seqBytes.add(byte);
        _state = .csi;
      case 0x5D: // ']' -> OSC
        _beginControlString(.osc, byte);
      case 0x50: // 'P' -> DCS
        _beginControlString(.dcs, byte);
      case 0x5F: // '_' -> APC
        _beginControlString(.apc, byte);
      case 0x1B: // Consecutive ESC: emit previous bare ESC, stay in .esc
        out.addByte(0x1B);
      default:
        out
          ..addByte(0x1B)
          ..addByte(byte);
        _seqBytes.clear();
        _state = .ground;
    }
  }

  void _beginControlString(_InterceptorState kind, int introByte) {
    _seqBytes.add(introByte);
    _state = kind;
    _stringKind = kind;
  }

  void _appendBounded(int byte) {
    if (_overflowed) return;
    if (_seqBytes.length < _maxSequenceBytes) {
      _seqBytes.add(byte);
    } else {
      _seqBytes.clear();
      _overflowed = true;
    }
  }

  void _handleCsi(int byte, BytesBuilder out) {
    if (byte == 0x1B) {
      _flushRawBufferIfValid(out);
      _state = .esc;
      _seqBytes
        ..clear()
        ..add(0x1B);
      _overflowed = false;
      return;
    }
    _appendBounded(byte);
    if (byte >= 0x20 && byte <= 0x3F) return;

    if (byte >= 0x40 && byte <= 0x7E && !_overflowed) {
      final passthroughBytes = _inspectCompleteCsi();
      if (passthroughBytes != null) out.add(passthroughBytes);
    } else if (!_overflowed) {
      out.add(_seqBytes);
    }
    _resetToGround();
  }

  void _handleControlString(int byte, BytesBuilder out) {
    if (byte == 0x07) {
      _appendBounded(byte);
      _finishControlString(terminatorLength: 1, out: out);
      return;
    }
    if (byte == 0x18 || byte == 0x1A) {
      _resetToGround();
      return;
    }
    if (byte == 0x1B) {
      _state = .stringEsc;
      return;
    }
    _appendBounded(byte);
  }

  void _handleStringEsc(int byte, BytesBuilder out) {
    if (byte == 0x5C) {
      _appendBounded(0x1B);
      _appendBounded(0x5C);
      _finishControlString(terminatorLength: 2, out: out);
      return;
    }
    _resetToGround();
    _handleEsc(byte, out);
  }

  void _finishControlString({
    required int terminatorLength,
    required BytesBuilder out,
  }) {
    if (!_overflowed && _seqBytes.length >= 2 + terminatorLength) {
      final payloadBytes = _seqBytes.sublist(
        2,
        _seqBytes.length - terminatorLength,
      );
      final payload = utf8.decode(payloadBytes, allowMalformed: true);
      final forward = switch (_stringKind) {
        .dcs => _inspectDcsPayload(payload),
        .osc => _inspectOscPayload(payload),
        .apc => _inspectApcPayload(payload),
        _ => true,
      };
      if (forward) out.add(_seqBytes);
    }
    _resetToGround();
  }

  void _flushRawBufferIfValid(BytesBuilder out) {
    if (!_overflowed && _seqBytes.isNotEmpty) {
      out.add(_seqBytes);
    }
  }

  void _resetToGround() {
    _state = .ground;
    _seqBytes.clear();
    _overflowed = false;
  }

  List<int>? _inspectCompleteCsi() {
    final body = String.fromCharCodes(_seqBytes.getRange(2, _seqBytes.length));
    if (body.startsWith('<')) return _inspectSgrMouseCsi(body);
    if (_handleDeviceOrWindowCsi(body)) return null;

    final kb = _kittyKbQueryRegex.firstMatch(body);
    if (kb != null) {
      report.recordKittyKeyboardFlags(int.tryParse(kb.group(1)!) ?? 0);
    }
    return _seqBytes;
  }

  bool _handleDeviceOrWindowCsi(String body) {
    final decrqm = _decrqmRegex.firstMatch(body);
    if (decrqm != null) {
      report.recordDecrqm(
        int.tryParse(decrqm.group(1)!) ?? 0,
        int.tryParse(decrqm.group(2)!) ?? 0,
      );
      return true;
    }

    final cellPx = _xtwinops16Regex.firstMatch(body);
    if (cellPx != null) {
      report.recordCellPixelSize(
        int.tryParse(cellPx.group(2)!) ?? 0,
        int.tryParse(cellPx.group(1)!) ?? 0,
      );
      return true;
    }

    final win = _xtwinops18Regex.firstMatch(body);
    if (win != null) {
      report.recordTextAreaSize(
        int.tryParse(win.group(2)!) ?? 0,
        int.tryParse(win.group(1)!) ?? 0,
      );
      return true;
    }

    return _handleDeviceAttrsCsi(body);
  }

  bool _handleDeviceAttrsCsi(String body) {
    final da2 = _da2Regex.firstMatch(body);
    if (da2 != null) {
      report.recordDa2(da2.group(1) ?? '');
      return true;
    }
    final da1 = _da1Regex.firstMatch(body);
    if (da1 != null) {
      report.recordDa1Sentinel(da1.group(1) ?? '');
      return true;
    }
    return false;
  }

  List<int> _inspectSgrMouseCsi(String body) {
    final m = _sgrMouseBodyRegex.firstMatch(body);
    if (m == null) return _seqBytes;
    final btn = int.tryParse(m.group(1)!) ?? 0;
    final rawX = int.tryParse(m.group(2)!) ?? 1;
    final rawY = int.tryParse(m.group(3)!) ?? 1;
    final suffix = m.group(4)!;

    final pixelsActive =
        sgrPixelsRequested && report['decrqm_1016']?.status == .supported;
    if (!pixelsActive) {
      report.recordWireMousePacket(
        'SGR(?1006) btn=$btn cell=($rawX,$rawY) CSI<$btn;$rawX;$rawY$suffix',
      );
      return _seqBytes;
    }

    final cw = report.cellPixelWidth > 0 ? report.cellPixelWidth : 9;
    final ch = report.cellPixelHeight > 0 ? report.cellPixelHeight : 18;
    final col = ((math.max(1, rawX) - 1) ~/ cw) + 1;
    final row = ((math.max(1, rawY) - 1) ~/ ch) + 1;
    report.recordWireMousePacket(
      'SGR-Pixels(?1016) btn=$btn px=($rawX,$rawY) -> cell=($col,$row)',
    );
    return ascii.encode('\x1b[<$btn;$col;$row$suffix');
  }

  bool _inspectDcsPayload(String payload) {
    if (payload.startsWith('>|')) {
      report.recordXtVersion(payload.substring(2));
    }
    return false;
  }

  bool _inspectOscPayload(String payload) {
    final semi = payload.indexOf(';');
    if (semi <= 0) return false;
    final code = int.tryParse(payload.substring(0, semi));
    final rest = payload.substring(semi + 1);
    if (code == 10 || code == 11) {
      report.recordOscColor(code!, rest, parseOscColorSpecToHex(rest));
      return false;
    }
    if (code == 52) {
      _tryRecordOsc52(rest);
      return true;
    }
    if (code == 99) {
      _recordOsc99Reply(rest);
      return false;
    }
    return false;
  }

  void _recordOsc99Reply(String rest) {
    final semi = rest.indexOf(';');
    final meta = semi >= 0 ? rest.substring(0, semi) : rest;
    var id = '?';
    var kind = 'activated';
    for (final kv in meta.split(':')) {
      if (kv.startsWith('i=')) {
        id = kv.substring(2);
      } else if (kv == 'p=close') {
        kind = 'closed (p=close)';
      }
    }
    report.recordOsc99Ack('id=$id $kind (OSC 99;$meta;)');
  }

  void _tryRecordOsc52(String rest) {
    final semi = rest.indexOf(';');
    if (semi < 0) return;
    final b64 = rest.substring(semi + 1).trim();
    if (b64.isEmpty || b64 == '?') return;
    try {
      final decoded = utf8.decode(base64Decode(b64), allowMalformed: true);
      report.recordOsc52Reply(decoded);
    } on FormatException {
      // Ignore malformed base64 clipboard replies.
    }
  }

  bool _inspectApcPayload(String payload) {
    if (!payload.startsWith('G') && !payload.startsWith('_G')) return false;
    final semi = payload.indexOf(';');
    final control = semi >= 0 ? payload.substring(0, semi) : payload;
    final status = semi >= 0 ? payload.substring(semi + 1) : '';
    final match = _apcIdRegex.firstMatch(control);
    final id = match != null ? int.tryParse(match.group(1)!) : null;
    if (id != null) {
      report.recordApcReply(id, status);
      return false;
    }
    return false;
  }

  /// Normalizes an XParseColor string (`rgb:RRRR/GGGG/BBBB` or `#RRGGBB`) to `#RRGGBB`.
  static String? parseOscColorSpecToHex(String raw) {
    final trimmed = raw.trim();
    final hexMatch = _hexHashRegex.firstMatch(trimmed);
    if (hexMatch != null) return '#${hexMatch.group(1)!.toUpperCase()}';

    final rgbMatch = _rgbSlashRegex.firstMatch(trimmed);
    if (rgbMatch == null) return null;
    final r = _scaleHexChannelToByte(rgbMatch.group(1)!);
    final g = _scaleHexChannelToByte(rgbMatch.group(2)!);
    final b = _scaleHexChannelToByte(rgbMatch.group(3)!);
    if (r == null || g == null || b == null) return null;
    return '#${_hex2(r)}${_hex2(g)}${_hex2(b)}';
  }

  static int? _scaleHexChannelToByte(String channel) {
    final val = int.tryParse(channel, radix: 16);
    if (val == null) return null;
    return switch (channel.length) {
      1 => val * 17,
      2 => val,
      3 => val >>> 4,
      4 => val >>> 8,
      _ => null,
    };
  }

  static String _hex2(int byte) =>
      (byte & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase();
}
