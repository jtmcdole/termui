import 'dart:math';

import 'package:meta/meta.dart';
import 'package:termui/termui.dart';

import '../cast_workspace_view_model.dart';

/// Shared base class for [ListenableSceneRenderer]s driven by [CastWorkspaceViewModel].
abstract base class ViewModelSceneRenderer implements ListenableSceneRenderer {
  /// Backing multi-session workspace view model.
  final CastWorkspaceViewModel viewModel;

  late final void Function() _removeVisualListener;
  Buffer? _currentBuffer;
  int _width;
  int _height;
  bool _isDirty = true;
  bool _disposed = false;

  @override
  void Function()? onNeedVisualUpdate;

  /// Subscribes to [viewModel] visual updates with initial `([initialWidth], [initialHeight])`.
  ViewModelSceneRenderer({
    required this.viewModel,
    required int initialWidth,
    required int initialHeight,
  }) : _width = max(1, initialWidth),
       _height = max(1, initialHeight) {
    _removeVisualListener = viewModel.addVisualListener(_markDirty);
  }

  void _markDirty() {
    if (_disposed) return;
    _isDirty = true;
    onNeedVisualUpdate?.call();
  }

  /// Current viewport width in columns.
  @protected
  int get width => _width;

  /// Current viewport height in rows.
  @protected
  int get height => _height;

  /// Whether [dispose] has been called.
  @protected
  bool get isDisposed => _disposed;

  @override
  bool get isDirty => _isDirty;

  @override
  Buffer? get currentBuffer => _currentBuffer;

  @override
  bool get showsCursor => false;

  @override
  Point<int>? get requestedCursorPosition => null;

  @override
  bool handlePasteEvent(PasteEvent event) => false;

  /// Stores [buffer] as [currentBuffer] and clears [isDirty].
  @protected
  void commitBuffer(Buffer buffer) {
    _isDirty = false;
    _currentBuffer = buffer;
  }

  /// Updates [width] and [height], returning `true` when either dimension changed.
  @protected
  bool updateDimensions(int nextWidth, int nextHeight) {
    final safeW = max(1, nextWidth);
    final safeH = max(1, nextHeight);
    final changed = safeW != _width || safeH != _height;
    _width = safeW;
    _height = safeH;
    return changed;
  }

  @override
  @mustCallSuper
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _removeVisualListener();
    onNeedVisualUpdate = null;
    _currentBuffer = null;
  }
}
