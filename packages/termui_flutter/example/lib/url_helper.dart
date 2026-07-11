import 'dart:async';
import 'url_helper_stub.dart'
    if (dart.library.js_interop) 'url_helper_web.dart'
    as impl;

/// Dynamically updates the browser URL parameters when running on Web.
void updateUrlParams({String? demo, String? page}) {
  impl.updateUrlParams(demo: demo, page: page);
}

/// Listens for browser back/forward page navigation popState changes.
StreamSubscription? listenToUrlChanges(
  void Function(Map<String, String> query) onQueryChanged,
) {
  return impl.listenToUrlChanges(onQueryChanged);
}

/// Retrieves the parsed query parameters from the current URL safely on all platforms.
Map<String, String> getUrlParams() {
  return impl.getUrlParams();
}
