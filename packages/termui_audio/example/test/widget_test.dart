import 'package:flutter_test/flutter_test.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui_audio_example/main.dart';

void main() {
  testWidgets('AudioPlayerApp renders Terminal smoke test', (
    WidgetTester tester,
  ) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MainApp());

    // Verify that our app renders the Terminal widget.
    expect(find.byType(Terminal), findsOneWidget);
  });
}
