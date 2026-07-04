import 'package:termui/termui.dart';
import 'package:test/test.dart';
import 'package:pty2/pty2.dart';
import 'dart:async';
import 'dart:io';

class MockPty implements PseudoTerminal {
  final _outController = StreamController<String>.broadcast();
  List<String> written = [];
  
  @override
  void ackProcessed() {}

  @override
  Future<int> get exitCode => Future.value(0);

  @override
  void init() {}

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    return true;
  }

  @override
  Stream<String> get out => _outController.stream;

  @override
  void resize(int width, int height) {}

  @override
  void write(String input) {
    written.add(input);
  }
  
  void simulateOutput(String output) {
    _outController.add(output);
  }
}

void main() {
  setUp(() {
    FocusManager.instance.setPrimaryFocus(null);
  });

  test('PlatformView renders PTY output and routes keys', () async {
    final mockPty = MockPty();
    
    // We expect PlatformView widget to exist, which wraps the PTY
    final platformView = PlatformView(
      pty: mockPty,
    );
    
    // Build tree
    final root = RootElement(platformView);
    root.mount(null);
    
    final buffer = Buffer.blank(10, 5);
    
    // Layout and paint
    root.layout(BoxConstraints.tightFor(width: 10, height: 5));
    root.paint(buffer);
    
    // Initially blank
    expect(buffer.toString(), equals(
      '          \n'
      '          \n'
      '          \n'
      '          \n'
      '          '
    ));

    // Simulate ansi output
    mockPty.simulateOutput('\x1b[1;1HHello');
    
    // allow async streams to process
    await Future.delayed(Duration.zero);
    
    root.rebuild();
    root.layout(BoxConstraints.tightFor(width: 10, height: 5));
    root.paint(buffer);
    
    // Assert it prints Hello
    expect(buffer.toString(), startsWith('Hello'));
  });
}
