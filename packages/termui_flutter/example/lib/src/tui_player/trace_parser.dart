export 'trace_parser_stub.dart'
    if (dart.library.js_interop) 'trace_parser_web.dart'
    if (dart.library.io) 'trace_parser_io.dart';
