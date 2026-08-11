/// Parses a hex background color string into a 32-bit ARGB integer.
///
/// Supports:
/// - 8-character ARGB (e.g. "FF000000", "FF00001F")
/// - 6-character RGB (e.g. "000000"), defaulting alpha to 255 (0xFF)
/// - Optional "#", "0x", or "0X" prefixes (e.g. "#FF000000", "0xFF000000")
/// - Case-insensitivity (e.g. "ff000000", "0Xff00001f")
///
/// Returns `null` if [input] is null or empty after trimming.
/// Throws [FormatException] if [input] is not a valid hex color string.
int? parseBackgroundColor(String? input) {
  if (input == null) return null;
  String clean = input.trim();
  if (clean.isEmpty) return null;

  clean = switch (clean) {
    String s when s.startsWith('#') => s.substring(1),
    String s when s.toLowerCase().startsWith('0x') => s.substring(2),
    String s => s,
  };

  if (clean.length == 6) {
    clean = 'FF$clean';
  }

  if (clean.length != 8) {
    throw FormatException(
      'Invalid background color "$input". Expected 6 or 8 hex digits.',
    );
  }

  final val = int.tryParse(clean, radix: 16);
  if (val == null) {
    throw FormatException('Invalid hex color format "$input".');
  }

  return val;
}
