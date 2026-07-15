export 'src/gzip_json/gzip_compress_stub.dart'
    if (dart.library.js_interop) 'src/gzip_json/gzip_compress_web.dart'
    if (dart.library.io) 'src/gzip_json/gzip_compress_io.dart';
