import 'dart:async';
import 'package:web/web.dart' as web;

/// Updates query parameters in the browser address bar without triggering a reload.
void updateUrlParams({String? demo, String? page}) {
  final uri = Uri.base;
  final newParams = Map<String, String>.from(uri.queryParameters);
  if (demo != null) {
    newParams['demo'] = demo;
  } else {
    newParams.remove('demo');
  }
  if (page != null) {
    newParams['page'] = page;
  } else {
    newParams.remove('page');
  }
  final newUri = uri.replace(queryParameters: newParams);
  web.window.history.replaceState(null, '', '$newUri');
}

/// Sets up a listener for browser popState/history changes (e.g. Back/Forward clicks).
StreamSubscription? listenToUrlChanges(
  void Function(Map<String, String> query) onQueryChanged,
) {
  return web.window.onPopState.listen((_) {
    onQueryChanged(getUrlParams());
  });
}

/// Returns the current URL parameters parsed from browser location.
Map<String, String> getUrlParams() {
  return Uri.base.queryParameters;
}
