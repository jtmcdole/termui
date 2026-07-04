import 'dart:async';
import 'dart:convert';
import 'package:test/test.dart';

void main() {
  test(
    'Utf8Decoder buffers incomplete multi-byte sequences across chunks',
    () async {
      // The "Direct Hit" emoji (🎯) is represented in UTF-8 by 4 bytes:
      // 0xF0 0x9F 0x8E 0xAF
      final emojiBytes = utf8.encode('🎯');
      expect(emojiBytes.length, 4);

      // Split the bytes into two separate chunks
      final chunk1 = emojiBytes.sublist(0, 2); // 0xF0 0x9F
      final chunk2 = emojiBytes.sublist(2, 4); // 0x8E 0xAF

      final controller = StreamController<List<int>>();
      final utf8Codec = Utf8Codec(allowMalformed: true);

      // Collect the decoded strings
      final output = <String>[];
      final sub = controller.stream.transform(utf8Codec.decoder).listen((str) {
        output.add(str);
      });

      // Send the first half of the emoji
      controller.add(chunk1);
      // Allow event loop to process
      await Future.delayed(Duration.zero);

      // The decoder should NOT emit anything yet, because it's waiting for the rest of the sequence
      expect(
        output,
        isEmpty,
        reason:
            'Should buffer the incomplete bytes without emitting a malformed character',
      );

      // Send the second half of the emoji
      controller.add(chunk2);
      // Close the stream
      await controller.close();

      // Now the decoder should have completed the sequence and emitted the emoji
      expect(output.length, 1);
      expect(
        output.first,
        '🎯',
        reason:
            'Should perfectly reconstruct the emoji across chunk boundaries',
      );

      await sub.cancel();
    },
  );

  test(
    'Utf8Decoder replaces truly malformed bytes if stream closes prematurely',
    () async {
      final emojiBytes = utf8.encode('🎯');
      final chunk1 = emojiBytes.sublist(0, 2);

      final controller = StreamController<List<int>>();
      final utf8Codec = Utf8Codec(allowMalformed: true);

      final output = <String>[];
      final sub = controller.stream.transform(utf8Codec.decoder).listen((str) {
        output.add(str);
      });

      // Send the first half of the emoji
      controller.add(chunk1);

      // Close the stream BEFORE sending the second half!
      await controller.close();

      // Because the stream closed, it realizes the sequence will never finish.
      // Since allowMalformed is true, it replaces the two dangling bytes with the replacement character (\uFFFD).
      expect(output.length, 1);
      expect(
        output.first,
        '\uFFFD',
        reason:
            'Should emit replacement character for trailing garbage on close',
      );

      await sub.cancel();
    },
  );
}
