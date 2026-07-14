import 'dart:typed_data';

/// A memory-efficient boolean array backed by a 32-bit packed contiguous buffer.
class BoolArray {
  /// The underlying buffer
  final Uint32List _data;

  /// The logical length of the array
  final int length;

  /// Creates a new [BoolArray] of the given [length]
  BoolArray(this.length) : _data = Uint32List((length + 31) >> 5);

  /// Gets the boolean value at the given [index]
  bool operator [](int index) {
    if (index < 0 || index >= length) return false;
    final word = index >> 5;
    final bit = index & 31;
    return (_data[word] & (1 << bit)) != 0;
  }

  /// Sets the boolean [value] at the given [index]
  void operator []=(int index, bool value) {
    if (index < 0 || index >= length) return;
    final word = index >> 5;
    final bit = index & 31;
    if (value) {
      _data[word] |= (1 << bit);
    } else {
      _data[word] &= ~(1 << bit);
    }
  }
}
