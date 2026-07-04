import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';

void main() {
  final vt = VirtualTerminal(width: 80, height: 24);
  vt.write([27, 91, 50, 74]); // csi 2 J
  vt.write('Hello World'.codeUnits);
  
  final buffer = vt.buffer;
  print('VT Buffer dimensions: ${buffer.width}x${buffer.height}');
  
  final target = Buffer(80, 24);
  final layered = LayeredBuffer(buffer: buffer, x: 0, y: 0, zIndex: 0);
  final compositor = Compositor();
  compositor.composite(target: target, layers: [layered]);
  
  for (var y = 0; y < 5; y++) {
    var line = '';
    for (var x = 0; x < 20; x++) {
      line += target.getCharacter(x, y);
    }
    print('Row $y: "$line"');
  }
}
