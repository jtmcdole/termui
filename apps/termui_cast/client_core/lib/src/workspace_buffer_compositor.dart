import 'package:termui/termui.dart';

import 'scrollback_page_cache.dart';
import 'session_slot.dart';

/// Virtual-line lookup and Rainbow Road hyperlink styling helpers shared by
/// headless client consumers (`fterm`).
abstract final class WorkspaceBufferCompositor {
  static const int _hoveredLinkBg = 0xFF1B263B;
  static const double _rainbowCycleMs = 1200.0;
  static const double _rainbowCellStepDegrees = 18.0;

  /// Animation cadence matching the Rainbow Road hover wave.
  static const Duration rainbowHoverTickInterval = Duration(milliseconds: 40);

  /// Dark pill background color applied under Rainbow Road hovered links.
  static const int rainbowLinkBackgroundArgb = _hoveredLinkBg;

  /// Modifiers (`bold | underline`) applied to Rainbow Road hovered links.
  static const int rainbowLinkModifiers = Modifier.underline | Modifier.bold;

  /// Looks up virtual row [virtualY] across cached scrollback and [liveBuffer].
  static VirtualLineSlice? lookupVirtualLine(
    SessionSlot slot,
    Buffer liveBuffer,
    int virtualY,
  ) {
    final totalLines = slot.scrollbackCache.totalLines;
    if (virtualY < totalLines) {
      final sbRow = slot.scrollbackCache.rowAt(virtualY);
      if (sbRow == null) {
        return (isWrapped: false, characters: const <String>[], uris: null);
      }
      return (
        isWrapped: sbRow.isWrapped,
        characters: sbRow.characters,
        uris: sbRow.expandUris(),
      );
    }
    final liveY = virtualY - totalLines;
    if (liveY < 0 || liveY >= liveBuffer.height) return null;
    final start = liveY * liveBuffer.width;
    final end = start + liveBuffer.width;
    return (
      isWrapped: slot.isLiveRowWrapped(liveY),
      characters: liveBuffer.characters.sublist(start, end),
      uris: liveBuffer.sliceUris(start, end),
    );
  }

  /// Computes the Rainbow Road wave phase in `[0.0, 360.0)` degrees for epoch
  /// millisecond [nowMs].
  static double rainbowPhaseHueAt(int nowMs) =>
      (nowMs % _rainbowCycleMs) / _rainbowCycleMs * 360.0;

  /// Computes the Rainbow Road foreground ARGB color for cell [cellIndex]
  /// given a precomputed [phaseHue] in degrees.
  static int rainbowLinkForegroundAtPhase(int cellIndex, double phaseHue) =>
      _rainbowArgb(phaseHue - cellIndex * _rainbowCellStepDegrees);

  /// Computes the Rainbow Road foreground ARGB color for cell [cellIndex]
  /// within a hovered link at epoch millisecond [nowMs].
  static int rainbowLinkForegroundAt(int cellIndex, int nowMs) =>
      rainbowLinkForegroundAtPhase(cellIndex, rainbowPhaseHueAt(nowMs));

  static int _rainbowArgb(double hueDegrees) {
    final h = ((hueDegrees % 360.0) + 360.0) % 360.0 / 60.0;
    const c = 0.85;
    const m = 1.0 - c;
    final x = c * (1.0 - (h % 2.0 - 1.0).abs());
    final double r;
    final double g;
    final double b;
    switch (h.floor()) {
      case 0:
        r = c;
        g = x;
        b = 0.0;
      case 1:
        r = x;
        g = c;
        b = 0.0;
      case 2:
        r = 0.0;
        g = c;
        b = x;
      case 3:
        r = 0.0;
        g = x;
        b = c;
      case 4:
        r = x;
        g = 0.0;
        b = c;
      default:
        r = c;
        g = 0.0;
        b = x;
    }
    final ri = ((r + m) * 255.0).round().clamp(0, 255);
    final gi = ((g + m) * 255.0).round().clamp(0, 255);
    final bi = ((b + m) * 255.0).round().clamp(0, 255);
    return 0xFF000000 | (ri << 16) | (gi << 8) | bi;
  }
}
