import 'package:termui/termui.dart' as termui;
import 'package:termui_recorder/termui_recorder.dart';
import 'package:termui/perf/tracer.dart';
import 'package:termui/perf/fs_locator.dart';
import '../repository/repository.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui/utils/gzip_json.dart';

class RecordingService {
  final SavedCastsRepository _repo;
  AsciicastRecorder? _asciicastRecorder;
  StringSinkAsciicastWriter? _asciicastWriter;
  StringBuffer? _asciicastBuffer;

  RecordingService(this._repo);

  AsciicastRecorder? get asciicastRecorder => _asciicastRecorder;

  Future<void> startAsciicast(termui.Terminal backend) async {
    _asciicastBuffer = StringBuffer();
    _asciicastWriter = StringSinkAsciicastWriter(_asciicastBuffer!);

    final size = await backend.size;
    _asciicastRecorder = AsciicastRecorder(
      _asciicastWriter!,
      width: size.x,
      height: size.y,
    );
  }

  Future<void> stopAndSaveAsciicast() async {
    try {
      _asciicastWriter?.close();
      if (_asciicastBuffer != null) {
        final rawString = _asciicastBuffer!.toString();
        final compressed = await compressString(rawString);
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final filename = 'cast_$timestamp.cast.gz';

        await saveFile(filename, compressed);
        await _repo.saveBytes(filename, compressed);
      }
    } finally {
      _asciicastRecorder = null;
      _asciicastBuffer = null;
      _asciicastWriter = null;
    }
  }

  Future<void> startTrace() async {
    await Tracer.start('trace_session.json', fs: getDefaultFileSystem());
  }

  Future<void> stopAndSaveTrace() async {
    await Tracer.stop();
    final fs = getDefaultFileSystem();
    final file = fs.file('trace_session.json');
    final exists = await file.exists();
    if (exists) {
      final bytes = await file.readAsBytes();
      final compressed = await compressBytes(bytes);

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filename = 'trace_$timestamp.json.gz';

      await saveFile(filename, compressed);
      await _repo.saveBytes(filename, compressed);
    }
  }
}
