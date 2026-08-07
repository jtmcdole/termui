import 'package:image/image.dart';

void main() {
  final img = Image(width: 10, height: 10);
  final p = img.getPixel(0, 0);
  print(img.getPixel(1, 1, p) == p);
}
