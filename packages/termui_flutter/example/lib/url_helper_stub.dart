/// Fallback stub implementation of URL helpers for non-web environments.
library;

import 'dart:async';

/// Updates browser query parameters. No-op on VM/Desktop.
void updateUrlParams({String? demo, String? page}) {}

/// Registers a listener for browser popState URL history changes. No-op on VM/Desktop.
StreamSubscription? listenToUrlChanges(
  void Function(Map<String, String> query) onQueryChanged,
) => null;

/// Returns the current URL parameters. Returns empty on VM/Desktop.
Map<String, String> getUrlParams() => const {};
