import 'package:characters/characters.dart';

/// Formats [title] to fit inside a bordered frame of [width] cells.
///
/// Returns an empty string when [title] is empty or [width] is too narrow to
/// display a truncated title.
String formatWindowTitle(String title, int width) {
  if (title.isEmpty) return '';
  final titleChars = title.characters;
  if (titleChars.length <= width - 4) return ' $title ';
  final cutLen = width - 7;
  if (cutLen <= 0) return '';
  return ' ${titleChars.take(cutLen).string}... ';
}
