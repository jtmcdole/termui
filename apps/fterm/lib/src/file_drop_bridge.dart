import 'package:termui_cast_client_core/termui_cast_client_core.dart';

import 'file_drop_bridge_stub.dart'
    if (dart.library.js_interop) 'file_drop_bridge_web.dart'
    if (dart.library.io) 'file_drop_bridge_io.dart'
    as impl;

/// Signature for creating a platform [FileDropBridge].
typedef FileDropBridgeFactory = FileDropBridge Function({
  required void Function(bool isDraggingOver) onDragHoverChanged,
  required void Function(List<DroppedFileSource> files) onFilesDropped,
});

/// Signature for launching a validated external `http`, `https`, or `mailto` [Uri].
typedef UrlOpener = void Function(Uri url);

/// Opens [url] (`http`, `https`, or `mailto`) via the platform launcher
/// (`_blank` with `noopener,noreferrer` on Web; host OS launcher on desktop
/// `dart:io`; blocks `javascript:`, `data:`, `blob:`, and `file:`).
void openExternalUrl(Uri url) => impl.openPlatformExternalUrl(url);

/// Removes any `#...` URL fragment (such as `#token=...`) from the browser
/// address bar and session history on Web (no-op on non-web platforms).
void scrubUrlFragment() => impl.scrubPlatformUrlFragment();

/// Consumes any `#token=` value stashed once by `hash_scrub.js` before WASM
/// startup on Web, returning `''` on non-web platforms or subsequent calls.
String consumeInitialHashToken() => impl.consumePlatformInitialHashToken();

/// Resolves the effective launch base [Uri] for deriving relative same-origin
/// endpoints (`document.baseURI` on Web when valid HTTP(S) matching [fallback]'s
/// origin, preserving any non-empty [fallback] fragment, or [fallback] on
/// non-web platforms).
Uri resolveLaunchBaseUri(Uri fallback) =>
    impl.resolvePlatformLaunchBaseUri(fallback);

/// Resolves [rawBaseUri] (such as `document.baseURI` on Web) against [fallback],
/// rejecting non-HTTP(S) URIs and any URI whose origin differs from an HTTP(S)
/// [fallback], while preserving any non-empty fragment from [fallback].
Uri resolveSameOriginBaseUri(String rawBaseUri, Uri fallback) {
  final raw = rawBaseUri.trim();
  if (raw.isEmpty) return fallback;
  final parsed = Uri.tryParse(raw);
  if (!_isHttpOriginUri(parsed)) return fallback;
  if (_isHttpOriginUri(fallback) && !_hasSameOrigin(parsed!, fallback)) {
    return fallback;
  }
  return fallback.fragment.isNotEmpty
      ? parsed!.replace(fragment: fallback.fragment)
      : parsed!;
}

bool _isHttpOriginUri(Uri? uri) =>
    uri != null &&
    (uri.scheme == 'http' || uri.scheme == 'https') &&
    uri.host.isNotEmpty;

bool _hasSameOrigin(Uri a, Uri b) =>
    a.scheme == b.scheme &&
    a.host.toLowerCase() == b.host.toLowerCase() &&
    a.port == b.port;

/// Disposable bridge listening for browser or desktop file drag-and-drop events.
abstract interface class FileDropBridge {
  /// Detaches any active DOM or platform drag-and-drop listeners.
  void dispose();
}

/// Attaches the platform [FileDropBridge] (HTML5 `DataTransfer` + `Blob.slice`
/// on Web, no-op stub on non-web test hosts).
FileDropBridge attachFileDropBridge({
  required void Function(bool isDraggingOver) onDragHoverChanged,
  required void Function(List<DroppedFileSource> files) onFilesDropped,
}) => impl.createPlatformFileDropBridge(
  onDragHoverChanged: onDragHoverChanged,
  onFilesDropped: onFilesDropped,
);
