import 'dart:convert';

/// Returns the platform `zlib` decoder on `dart:io`, or `null` on Web targets.
Converter<List<int>, List<int>>? get platformZlibDecoder => null;
