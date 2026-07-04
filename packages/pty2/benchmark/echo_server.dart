import 'dart:io';

void main() async {
  await stdin.pipe(stdout);
}
