import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/layout.dart';

class TestWidget extends Widget {
  final String char;
  const TestWidget(this.char);

  @override
  void render(Buffer buffer, Rect area) {
    print('TestWidget rendering "$char" into area: $area');
    buffer.writeString(0, 0, char, Style.empty);
  }
}

void main() {
  final buffer = Buffer.blank(10, 1);
  final row = Row([
    const SizedBox(width: 2, child: TestWidget('A')),
    const Expanded(child: TestWidget('B')),
    const Flexible(flex: 2, child: TestWidget('C')),
  ]);

  print('Calling row.render...');
  row.render(buffer, const Rect(0, 0, 10, 1));

  print('Buffer content:');
  for (var i = 0; i < 10; i++) {
    print('Cell $i: "${buffer.getCell(i, 0)!.char}"');
  }
}
