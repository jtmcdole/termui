import 'dart:collection';

/// A generic fixed-capacity circular ring buffer that maintains the latest [capacity] elements.
///
/// It extends [ListBase] allowing for fast iteration and standard List manipulations.
class RingBuffer<T> extends ListBase<T> {
  int _capacity;
  List<T?> _buffer;
  int _head = 0;
  int _tail = 0;
  bool _isFull = false;

  /// Creates a [RingBuffer] with the specified [capacity].
  RingBuffer(int capacity)
    : _capacity = capacity,
      _buffer = List<T?>.filled(capacity, null) {
    if (capacity <= 0) {
      throw ArgumentError('Capacity must be greater than 0');
    }
  }

  /// Adds an element to the buffer. Overwrites the oldest element if full.
  @override
  void add(T element) {
    _buffer[_tail] = element;
    _tail = (_tail + 1) % _capacity;
    if (_isFull) {
      _head = (_head + 1) % _capacity;
    } else if (_tail == _head) {
      _isFull = true;
    }
  }

  /// Removes and returns the oldest element from the buffer.
  T removeFirst() {
    if (isEmpty) {
      throw StateError('Cannot remove from an empty RingBuffer');
    }
    final value = _buffer[_head] as T;
    _buffer[_head] = null;
    _head = (_head + 1) % _capacity;
    _isFull = false;
    return value;
  }

  @override
  int get length => _isFull
      ? _capacity
      : (_tail >= _head ? _tail - _head : _capacity - _head + _tail);

  @override
  set length(int newLength) {
    if (newLength < 0) {
      throw ArgumentError('Length cannot be negative: $newLength');
    }
    final currentLength = length;
    if (newLength == currentLength) {
      return;
    }

    if (newLength == 0) {
      _buffer.fillRange(0, _capacity, null);
      _head = 0;
      _tail = 0;
      _isFull = false;
      return;
    }

    // Extract current logical elements up to min of currentLength and newLength
    final int elementsToCopy = currentLength < newLength
        ? currentLength
        : newLength;
    final newBuffer = List<T?>.filled(newLength, null);
    for (int i = 0; i < elementsToCopy; i++) {
      newBuffer[i] = elementAt(i);
    }

    _capacity = newLength;
    _buffer = newBuffer;
    _head = 0;
    _tail = 0;
    _isFull = true;
  }

  @override
  T operator [](int index) {
    if (index < 0 || index >= length) {
      throw RangeError.index(index, this);
    }
    return _buffer[(_head + index) % _capacity] as T;
  }

  @override
  void operator []=(int index, T value) {
    if (index < 0 || index >= length) {
      throw RangeError.index(index, this);
    }
    _buffer[(_head + index) % _capacity] = value;
  }

  /// Returns the internal buffer index for a given logical [index].
  /// This can be used to efficiently map external arrays if needed.
  int physicalIndex(int index) {
    if (index < 0 || index >= length) {
      throw RangeError.index(index, this);
    }
    return (_head + index) % _capacity;
  }
}
