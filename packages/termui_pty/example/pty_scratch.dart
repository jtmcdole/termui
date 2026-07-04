import 'package:pty2/pty2.dart';

void main() async {
  final pty = PseudoTerminal.start(
    'bash',
    ['-c', 'top'],
    environment: {'TERM': 'xterm-256color'},
  );
  print('started bash top');
  pty.out.listen((data) {
    print(
      'OUTPUT: ${data.length} chars. first few: ${data.substring(0, data.length > 20 ? 20 : data.length)}',
    );
  });

  await Future.delayed(Duration(seconds: 2));
  pty.kill();
}
