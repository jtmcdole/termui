import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termui_audio/termui_audio.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui_audio_example/main.dart';

import 'audio_player_viewmodel_test.dart' show MockAudioEngine;

void main() {
  testWidgets('AudioPlayerApp renders Terminal smoke test', (
    WidgetTester tester,
  ) async {
    TermuiAudio.instance = MockAudioEngine();

    // Build our app and trigger a frame.
    await tester.pumpWidget(const MainApp());

    // Verify that our app renders the Terminal widget.
    expect(find.byType(Terminal), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
