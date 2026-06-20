import 'dart:convert';
import 'package:file/local.dart';
import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui_recorder/termui_recorder.dart';

void main() {
  test('v3 Asciicast GZipped Export', () {
    final fs = LocalFileSystem();
    final tempDir = fs.systemTempDirectory.createTempSync(
      'termui_recorder_test_v3',
    );
    final castFile = fs.file('${tempDir.path}/test.cast.gz');

    // 1. Record frames
    final writer = FileAsciicastWriter(castFile);
    final recorder = AsciicastRecorder(writer, width: 10, height: 5);

    final buffer1 = Buffer(10, 5);
    buffer1.writeString(0, 0, 'Hello', Style.empty);
    recorder.recordFrame(buffer1);

    final buffer2 = Buffer(10, 5);
    buffer2.writeString(0, 0, 'World', Style.empty);
    recorder.recordFrame(buffer2);

    recorder.close();

    // 2. Verify compressed file exists
    expect(castFile.existsSync(), isTrue);
    final bytes = castFile.readAsBytesSync();

    // 3. Decompress manually and verify v3 NDJSON lines
    final decompressed = GZipDecoder().decodeBytes(bytes);
    final text = utf8.decode(decompressed);

    final lines = text.trim().split('\n');
    expect(lines.length, greaterThanOrEqualTo(3)); // header + 2 frames

    final header = jsonDecode(lines[0]);
    expect(header['version'], 3);
    expect(header['term']['cols'], 10);
    expect(header['term']['rows'], 5);

    final frame1 = jsonDecode(lines[1]);
    expect(frame1[0], greaterThanOrEqualTo(0.0));
    expect(frame1[1], 'o');
    expect(frame1[2], contains('Hello'));

    final frame2 = jsonDecode(lines[2]);
    expect(frame2[0], greaterThanOrEqualTo(0.0));
    expect(frame2[1], 'o');
    expect(frame2[2], contains('Wor'));
    expect(frame2[2], contains('d'));

    // 4. Verify playback parsing doesn't crash
    final player = AsciicastPlayer(text);
    expect(player, isNotNull);

    tempDir.deleteSync(recursive: true);
  });
}
