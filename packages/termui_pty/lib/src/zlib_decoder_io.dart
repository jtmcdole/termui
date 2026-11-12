import 'dart:convert';
import 'dart:io' show zlib;

/// Returns the `dart:io` `zlib` decoder.
Converter<List<int>, List<int>>? get platformZlibDecoder => zlib.decoder;
