import 'dart:js_interop';
import 'dart:typed_data';

import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:web/web.dart' as web;

import 'file_drop_bridge.dart';

@JS()
extension type _WebkitDataTransferItem._(JSObject _) implements JSObject {
  external _WebkitFileSystemEntry? webkitGetAsEntry();
}

@JS()
extension type _WebkitFileSystemEntry._(JSObject _) implements JSObject {
  external bool get isDirectory;
  external String get name;
}

/// Creates a DOM `window` drag-and-drop bridge using `package:web`.
FileDropBridge createPlatformFileDropBridge({
  required void Function(bool isDraggingOver) onDragHoverChanged,
  required void Function(List<DroppedFileSource> files) onFilesDropped,
}) => _WebFileDropBridge(
  onDragHoverChanged: onDragHoverChanged,
  onFilesDropped: onFilesDropped,
);

final RegExp _controlChars = RegExp(r'[\x00-\x1F\x7F-\x9F]');

/// Opens [url] (`http`, `https`, or `mailto`) in a new browser tab with `noopener,noreferrer`.
void openPlatformExternalUrl(Uri url) {
  final serialized = '$url';
  if (serialized.isEmpty || _controlChars.hasMatch(serialized)) return;
  final allowed = switch (url.scheme.toLowerCase()) {
    'http' || 'https' => url.hasAuthority && url.host.isNotEmpty,
    'mailto' => !url.hasAuthority && url.path.isNotEmpty,
    _ => false,
  };
  if (!allowed) return;
  web.window.open(serialized, '_blank', 'noopener,noreferrer');
}

/// Removes any `#...` URL fragment (such as `#token=...`) from the browser
/// address bar and session history without triggering a navigation.
void scrubPlatformUrlFragment() {
  if (web.window.location.hash.isNotEmpty) {
    web.window.history.replaceState(
      null,
      '',
      '${web.window.location.pathname}${web.window.location.search}',
    );
  }
}

final class _WebFileDropBridge implements FileDropBridge {
  final void Function(bool isDraggingOver) _onDragHoverChanged;
  final void Function(List<DroppedFileSource> files) _onFilesDropped;

  late final JSExportedDartFunction _dragEnterHandler;
  late final JSExportedDartFunction _dragOverHandler;
  late final JSExportedDartFunction _dragLeaveHandler;
  late final JSExportedDartFunction _dropHandler;
  late final JSExportedDartFunction _contextMenuHandler;
  late final JSExportedDartFunction _keyDownHandler;

  int _dragDepth = 0;
  bool _hovering = false;
  bool _disposed = false;

  _WebFileDropBridge({
    required void Function(bool isDraggingOver) onDragHoverChanged,
    required void Function(List<DroppedFileSource> files) onFilesDropped,
  }) : _onDragHoverChanged = onDragHoverChanged,
       _onFilesDropped = onFilesDropped {
    _dragEnterHandler = _onDragEnter.toJS;
    _dragOverHandler = _onDragOver.toJS;
    _dragLeaveHandler = _onDragLeave.toJS;
    _dropHandler = _onDrop.toJS;
    _contextMenuHandler = _onContextMenu.toJS;
    _keyDownHandler = _onKeyDown.toJS;

    web.window.addEventListener('dragenter', _dragEnterHandler);
    web.window.addEventListener('dragover', _dragOverHandler);
    web.window.addEventListener('dragleave', _dragLeaveHandler);
    web.window.addEventListener('drop', _dropHandler);
    web.window.addEventListener('contextmenu', _contextMenuHandler);
    web.window.addEventListener('keydown', _keyDownHandler);
  }

  void _setHovering(bool value) {
    if (_disposed || _hovering == value) return;
    _hovering = value;
    _onDragHoverChanged(value);
  }

  static bool _hasFilePayload(web.DataTransfer? dt) {
    if (dt == null) return false;
    final types = dt.types;
    for (var i = 0; i < types.length; i++) {
      if (types[i].toDart == 'Files') return true;
    }
    return dt.files.length > 0;
  }

  void _onDragEnter(web.DragEvent event) {
    if (_disposed || !_hasFilePayload(event.dataTransfer)) return;
    event.preventDefault();
    _dragDepth++;
    _setHovering(true);
  }

  void _onDragOver(web.DragEvent event) {
    final dt = event.dataTransfer;
    if (_disposed || !_hasFilePayload(dt)) return;
    event.preventDefault();
    dt!.dropEffect = 'copy';
    if (_dragDepth <= 0) {
      _dragDepth = 1;
    }
    _setHovering(true);
  }

  void _onDragLeave(web.DragEvent event) {
    if (_disposed || !_hovering) return;
    event.preventDefault();
    _dragDepth = _dragDepth > 1 ? _dragDepth - 1 : 0;
    if (_dragDepth == 0) {
      _setHovering(false);
    }
  }

  void _onDrop(web.DragEvent event) {
    final dt = event.dataTransfer;
    if (_disposed || !_hasFilePayload(dt)) return;
    event.preventDefault();
    _dragDepth = 0;
    _setHovering(false);

    // Synchronously snapshot all File/Blob references and directory flags
    // before the browser clears the DataTransfer list after the drop turn.
    final sources = _snapshotDroppedFiles(dt!);
    if (sources.isNotEmpty) {
      _onFilesDropped(sources);
    }
  }

  static List<DroppedFileSource> _snapshotDroppedFiles(web.DataTransfer dt) {
    final fromItems = _snapshotFromItems(dt.items);
    if (fromItems.isNotEmpty) return fromItems;
    final files = dt.files;
    return [
      for (var i = 0; i < files.length; i++)
        if (files.item(i) case final file?) _WebBlobDroppedFileSource(file),
    ];
  }

  static List<DroppedFileSource> _snapshotFromItems(
    web.DataTransferItemList items,
  ) {
    final sources = <DroppedFileSource>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.kind != 'file') continue;
      final entry = (item as _WebkitDataTransferItem).webkitGetAsEntry();
      if (entry != null && entry.isDirectory) {
        sources.add(_WebDirectoryDroppedSource(name: entry.name));
      } else if (item.getAsFile() case final file?) {
        sources.add(_WebBlobDroppedFileSource(file));
      }
    }
    return sources;
  }

  void _onContextMenu(web.MouseEvent event) {
    if (!_disposed &&
        event.ctrlKey &&
        !event.shiftKey &&
        !event.altKey &&
        !event.metaKey) {
      event.preventDefault();
    }
  }

  void _onKeyDown(web.KeyboardEvent event) {
    if (!_disposed && _shouldSuppressBrowserCtrlKeyDefault(event)) {
      event.preventDefault();
    }
  }

  static bool _shouldSuppressBrowserCtrlKeyDefault(web.KeyboardEvent event) {
    if (event.isComposing || event.keyCode == 229) return false;
    if (!event.ctrlKey || event.shiftKey || event.altKey || event.metaKey) {
      return false;
    }
    final key = event.key;
    if (key.length != 1) return false;
    final unit = key.codeUnitAt(0);
    if (unit < 0x80) return _isTerminalControlKeyUnit(unit);
    return _isAsciiLetterCode(event.code);
  }

  static bool _isAsciiLetterCode(String code) {
    if (code.length != 4 || !code.startsWith('Key')) return false;
    final letter = code.codeUnitAt(3);
    return letter >= 0x41 && letter <= 0x5A;
  }

  static bool _isTerminalControlKeyUnit(int code) {
    if (code <= 0x1F) return true;
    if (code >= 0x41 && code <= 0x5A) return true;
    if (code >= 0x61 && code <= 0x7A) return true;
    return switch (code) {
      0x20 || 0x2F || 0x40 || 0x5B || 0x5C || 0x5D || 0x5E || 0x5F => true,
      _ => false,
    };
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    web.window.removeEventListener('dragenter', _dragEnterHandler);
    web.window.removeEventListener('dragover', _dragOverHandler);
    web.window.removeEventListener('dragleave', _dragLeaveHandler);
    web.window.removeEventListener('drop', _dropHandler);
    web.window.removeEventListener('contextmenu', _contextMenuHandler);
    web.window.removeEventListener('keydown', _keyDownHandler);
  }
}

final class _WebBlobDroppedFileSource implements DroppedFileSource {
  final web.File _file;

  const _WebBlobDroppedFileSource(this._file);

  @override
  String get name => _file.name;

  @override
  int get size => _file.size;

  @override
  bool get isDirectory => false;

  @override
  Future<Uint8List> readSlice(int start, int end) async {
    final safeStart = start.clamp(0, _file.size);
    final safeEnd = end.clamp(safeStart, _file.size);
    if (safeEnd <= safeStart) return Uint8List(0);
    final blob = _file.slice(safeStart, safeEnd);
    final arrayBuffer = await blob.arrayBuffer().toDart;
    return arrayBuffer.toDart.asUint8List();
  }
}

final class _WebDirectoryDroppedSource implements DroppedFileSource {
  @override
  final String name;

  const _WebDirectoryDroppedSource({required this.name});

  @override
  int get size => 0;

  @override
  bool get isDirectory => true;

  @override
  Future<Uint8List> readSlice(int start, int end) async => Uint8List(0);
}
