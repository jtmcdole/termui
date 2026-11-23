import 'dart:convert';
import 'dart:typed_data';

import '../ui/cell_transform.dart';
import '../ui/shader_region.dart';

/// Pure-Dart encoder for `ESC _ S <k=v,...>[;<base64>] ST` artistic shader and
/// per-cell transform APC sequences.
///
/// Mirrors the `\x1b_G` (Kitty graphics) and `\x1b_A` (audio) APC grammars
/// without a mandatory space after `S`. Semicolon `;` is reserved strictly for
/// base64 payload separation, while wrapped region `rects` use `/`.
abstract final class ShaderApcEncoder {
  /// Maximum decoded UTF-8 byte length for a CLI-uploaded GLSL shader (`32 KiB`).
  static const int maxGlslBytes = 32 * 1024;

  /// Default raw byte chunk size for chunked `a=define` uploads (`4 KiB`).
  static const int defaultDefineChunkBytes = 4096;

  /// Maximum raw packed transform bytes per `a=xforms` wire frame (`750 * 64 = 48,000`
  /// bytes, producing `64,000` base64 chars so the complete APC stays `<= 64 KiB`).
  static const int maxTransformChunkRawBytes =
      750 * CellTransformCodec.strideBytes;

  /// Encodes a capability query (`\x1b_Sa=query\x1b\\`).
  static String encodeQuery() => '\x1b_Sa=query\x1b\\';

  /// Encodes a host capability reply (`\x1b_Sa=caps,...\x1b\\`).
  static String encodeCapsReply({
    required String backend,
    required bool glsl,
    bool xform = true,
    required bool region,
    int maxSlots = 16,
    int maxRegions = ShaderRegion.maxRegionsPerPane,
  }) =>
      '\x1b_Sa=caps,backend=$backend,glsl=${glsl ? 1 : 0},'
      'xform=${xform ? 1 : 0},region=${region ? 1 : 0},'
      'max_slots=$maxSlots,max_regions=$maxRegions\x1b\\';

  /// Encodes a chunked CLI GLSL shader upload (`a=define`).
  ///
  /// Throws [ArgumentError] if [id] is invalid, [glslSource] is empty, or its
  /// UTF-8 encoding exceeds [maxGlslBytes] (`32 KiB`).
  static List<String> encodeDefine({
    required String id,
    required String glslSource,
    bool persist = false,
    int chunkRawBytes = defaultDefineChunkBytes,
  }) {
    _validateIdentifier(id, 'id');
    final bytes = utf8.encode(glslSource);
    if (bytes.isEmpty || bytes.length > maxGlslBytes) {
      throw ArgumentError.value(
        bytes.length,
        'glslSource',
        'GLSL source must be 1..$maxGlslBytes UTF-8 bytes',
      );
    }
    final stride = chunkRawBytes.clamp(3, 45 * 1024);
    final alignedStride = stride - (stride % 3);
    final effectiveStride = alignedStride > 0 ? alignedStride : 3;
    final frames = <String>[];
    var offset = 0;
    while (offset < bytes.length) {
      final end = (offset + effectiveStride < bytes.length)
          ? offset + effectiveStride
          : bytes.length;
      final isMore = end < bytes.length;
      final chunk = base64Encode(Uint8List.sublistView(bytes, offset, end));
      final header = offset == 0
          ? _defineFirstHeader(id, persist: persist, isMore: isMore)
          : 'a=define,id=$id,m=${isMore ? 1 : 0}';
      frames.add('\x1b_S$header;$chunk\x1b\\');
      offset = end;
    }
    return frames;
  }

  static String _defineFirstHeader(
    String id, {
    required bool persist,
    required bool isMore,
  }) {
    final persistPart = persist ? ',persist=1' : '';
    return 'a=define,id=$id$persistPart,m=${isMore ? 1 : 0}';
  }

  /// Encodes a scoped [ShaderRegion] attachment or update (`a=region`).
  static String encodeRegion(ShaderRegion region) {
    _validateIdentifier(region.id, 'region.id');
    _validateIdentifier(region.shaderId, 'region.shaderId');
    if (region.sourceRects.isEmpty) {
      return encodeRemoveRegion(region.id);
    }
    final rects = [
      for (final r in region.sourceRects)
        '${r.x}:${r.y}:${r.width}:${r.height}',
    ].join('/');
    final pad = region.padding.clamped();
    final parts = <String>[
      'a=region',
      'id=${region.id}',
      's=${region.shaderId}',
      'rects=$rects',
      if (pad != CellPadding.zero)
        'pad=${pad.top}:${pad.right}:${pad.bottom}:${pad.left}',
      if (region.stage != ShaderRegionStage.overGlyphs)
        'stage=${region.stage.wireName}',
      if (region.zIndex != 0) 'z=${region.zIndex}',
      if (region.persist) 'persist=1',
      ..._formatNonZeroParams(region.params),
    ];
    return '\x1b_S${parts.join(',')}\x1b\\';
  }

  /// Encodes removal of a scoped region by [id] (`a=region,id=<id>,del=1`).
  static String encodeRemoveRegion(String id) {
    _validateIdentifier(id, 'id');
    return '\x1b_Sa=region,id=$id,del=1\x1b\\';
  }

  /// Encodes a single-cell transform or removal (`a=xform`).
  static String encodeTransform({
    required int col,
    required int row,
    required CellTransform? transform,
  }) {
    final safeCol = col.clamp(0, 0xFFFF);
    final safeRow = row.clamp(0, 0xFFFF);
    if (transform == null) {
      return '\x1b_Sa=xform,c=$safeCol,r=$safeRow,del=1\x1b\\';
    }
    final clean = transform.sanitized();
    if (clean.isIdentity) {
      return '\x1b_Sa=xform,c=$safeCol,r=$safeRow,del=1\x1b\\';
    }
    final parts = <String>[
      'a=xform',
      'c=$safeCol',
      'r=$safeRow',
      if (clean.dx != 0.0) 'dx=${_fmtFloat(clean.dx)}',
      if (clean.dy != 0.0) 'dy=${_fmtFloat(clean.dy)}',
      if (clean.scaleX != 1.0) 'sx=${_fmtFloat(clean.scaleX)}',
      if (clean.scaleY != 1.0) 'sy=${_fmtFloat(clean.scaleY)}',
      if (clean.rotationRad != 0.0) 'rot=${_fmtFloat(clean.rotationRad)}',
      if (clean.alpha != 1.0) 'al=${_fmtFloat(clean.alpha)}',
      if (clean.zLayer != 0) 'z=${clean.zLayer}',
      if (clean.tween case final tw?) ..._formatTweenParams(tw),
    ];
    return '\x1b_S${parts.join(',')}\x1b\\';
  }

  static List<String> _formatTweenParams(CellTween tw) => <String>[
    'aid=${tw.animationId}',
    if (tw.endDx != 0.0) 'edx=${_fmtFloat(tw.endDx)}',
    if (tw.endDy != 0.0) 'edy=${_fmtFloat(tw.endDy)}',
    if (tw.endScaleX != 1.0) 'esx=${_fmtFloat(tw.endScaleX)}',
    if (tw.endScaleY != 1.0) 'esy=${_fmtFloat(tw.endScaleY)}',
    if (tw.endRotationRad != 0.0) 'erot=${_fmtFloat(tw.endRotationRad)}',
    if (tw.endAlpha != 1.0) 'ea=${_fmtFloat(tw.endAlpha)}',
    'dur=${_fmtFloat(tw.durationSec)}',
    if (tw.easing != CellTweenEasing.linear) 'ease=${tw.easing.wireName}',
    if (tw.fromCurrent) 'cur=1',
    if (tw.clearOnFinish) 'clr=1',
  ];

  /// Encodes a batch of up to `4,096` cell transforms into one or more
  /// `<= 64 KiB` chunked `a=xforms` APC sequences using the `64`-byte stride.
  static List<String> encodeTransformsBatch(
    List<CellTransformEntry> entries, {
    bool replace = false,
    int maxChunkRawBytes = maxTransformChunkRawBytes,
  }) {
    final packed = CellTransformCodec.packBatch(entries);
    if (packed.isEmpty) {
      return replace ? const ['\x1b_Sa=reset,target=xforms\x1b\\'] : const [];
    }
    final clampedRaw = maxChunkRawBytes.clamp(
      CellTransformCodec.strideBytes,
      maxTransformChunkRawBytes,
    );
    final aligned = clampedRaw - (clampedRaw % CellTransformCodec.strideBytes);
    final stride = aligned >= CellTransformCodec.strideBytes
        ? aligned
        : CellTransformCodec.strideBytes;
    final frames = <String>[];
    var offset = 0;
    while (offset < packed.length) {
      final end = (offset + stride < packed.length)
          ? offset + stride
          : packed.length;
      final isMore = end < packed.length;
      final b64 = base64Encode(Uint8List.sublistView(packed, offset, end));
      final replacePart = (offset == 0 && replace) ? ',replace=1' : '';
      frames.add('\x1b_Sa=xforms$replacePart,m=${isMore ? 1 : 0};$b64\x1b\\');
      offset = end;
    }
    return frames;
  }

  /// Encodes a full-pane shader activation or clear (`a=set`).
  static String encodeSet({
    String stage = 'post',
    String? presetId,
    String? shaderId,
    Float32List? params,
    bool clear = false,
  }) {
    final parts = <String>['a=set', 'stage=$stage'];
    if (clear) {
      parts.add('clear=1');
    } else if (presetId != null) {
      _validateIdentifier(presetId, 'presetId');
      parts.add('preset=$presetId');
    } else if (shaderId != null) {
      _validateIdentifier(shaderId, 'shaderId');
      parts.add('id=$shaderId');
    }
    if (params != null && !clear) {
      parts.addAll(_formatNonZeroParams(ShaderRegion.sanitizeParams(params)));
    }
    return '\x1b_S${parts.join(',')}\x1b\\';
  }

  /// Encodes a uniform update (`a=uniform`) without recompiling the target shader.
  static String encodeUniform({String? id, required Map<int, double> params}) {
    if (id != null) _validateIdentifier(id, 'id');
    final parts = <String>['a=uniform', if (id != null) 'id=$id'];
    for (final entry in params.entries) {
      final idx = entry.key;
      final value = entry.value;
      if (idx < 0 || idx >= ShaderRegion.paramCount || !value.isFinite) {
        continue;
      }
      final clamped = value
          .clamp(ShaderRegion.minParamValue, ShaderRegion.maxParamValue)
          .toDouble();
      parts.add('p$idx=${_fmtFloat(clamped)}');
    }
    return '\x1b_S${parts.join(',')}\x1b\\';
  }

  /// Encodes a CLI shader/transform reset (`a=reset,target=...`).
  static String encodeReset({String target = 'all'}) =>
      '\x1b_Sa=reset,target=$target\x1b\\';

  static List<String> _formatNonZeroParams(Float32List params) => <String>[
    for (var i = 0; i < params.length && i < ShaderRegion.paramCount; i++)
      if (params[i] != 0.0 && params[i].isFinite) 'p$i=${_fmtFloat(params[i])}',
  ];

  static String _fmtFloat(double value) {
    if (!value.isFinite) return '0';
    final fixed = value.toStringAsFixed(4);
    var end = fixed.length;
    while (end > 1 && fixed.codeUnitAt(end - 1) == 0x30) {
      end--;
    }
    if (end > 1 && fixed.codeUnitAt(end - 1) == 0x2E) {
      end--;
    }
    final trimmed = fixed.substring(0, end);
    return trimmed == '-0' ? '0' : trimmed;
  }

  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_.-]{1,64}$');

  static void _validateIdentifier(String id, String name) {
    if (!_idPattern.hasMatch(id)) {
      throw ArgumentError.value(
        id,
        name,
        'Identifier must match ^[A-Za-z0-9_.-]{1,64}\$',
      );
    }
  }
}
