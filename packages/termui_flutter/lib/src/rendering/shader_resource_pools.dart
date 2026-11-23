import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

/// Rounds [byteSize] up to the nearest multiple of [alignment] (clamping
/// non-positive alignments to `1`).
int alignUniformByteSize(int byteSize, int alignment) {
  if (byteSize <= 0) return 0;
  final step = alignment <= 1 ? 1 : alignment;
  final remainder = byteSize % step;
  return remainder == 0 ? byteSize : byteSize + (step - remainder);
}

/// Immutable integer pixel dimensions key for GPU surface and scratch pools.
final class GpuTextureSizeKey {
  /// Texture width in physical pixels.
  final int width;

  /// Texture height in physical pixels.
  final int height;

  /// Creates a texture dimension key.
  const GpuTextureSizeKey(this.width, this.height);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GpuTextureSizeKey &&
          other.width == width &&
          other.height == height;

  @override
  int get hashCode => Object.hash(width, height);
}

/// Bounded LRU pool keyed by [GpuTextureSizeKey] used for `GpuImageSurface`
/// instances and multi-pass scratch texture pairs.
final class GpuSizePool<T extends Object> {
  /// Maximum number of distinct dimension entries retained simultaneously.
  final int maxEntries;

  /// Optional callback invoked when an entry is evicted, removed, or cleared.
  final void Function(T evicted)? onEvict;

  final LinkedHashMap<GpuTextureSizeKey, T> _entries =
      LinkedHashMap<GpuTextureSizeKey, T>();

  /// Creates a bounded GPU resource pool.
  GpuSizePool({this.maxEntries = 4, this.onEvict});

  /// Number of entries currently retained in this pool.
  int get length => _entries.length;

  /// Returns an existing resource for `(width, height)`, or invokes [create]
  /// and inserts it while evicting the least-recently-used entry if full.
  T obtain(int width, int height, T Function(int width, int height) create) {
    final key = GpuTextureSizeKey(width, height);
    final existing = _entries.remove(key);
    if (existing != null) {
      _entries[key] = existing;
      return existing;
    }
    while (_entries.length >= maxEntries && _entries.isNotEmpty) {
      final evicted = _entries.remove(_entries.keys.first);
      if (evicted != null) onEvict?.call(evicted);
    }
    final created = create(width, height);
    _entries[key] = created;
    return created;
  }

  /// Removes the entry for `(width, height)` if present.
  void remove(int width, int height, {bool invokeOnEvict = true}) {
    final removed = _entries.remove(GpuTextureSizeKey(width, height));
    if (removed != null && invokeOnEvict) onEvict?.call(removed);
  }

  /// Clears all retained resources.
  void clear({bool invokeOnEvict = true}) {
    if (invokeOnEvict && onEvict != null) {
      for (final value in _entries.values) {
        onEvict!(value);
      }
    }
    _entries.clear();
  }
}

/// Bounded LRU resource pool keyed by arbitrary [TKey] (used to isolate
/// per-slot region output textures within the same frame).
final class GpuKeyedPool<TKey extends Object, TValue extends Object> {
  /// Maximum number of entries retained simultaneously.
  final int maxEntries;

  /// Optional callback invoked when an entry is evicted, removed, or cleared.
  final void Function(TValue evicted)? onEvict;

  final LinkedHashMap<TKey, TValue> _entries = LinkedHashMap<TKey, TValue>();

  /// Creates a bounded keyed GPU pool.
  GpuKeyedPool({this.maxEntries = 16, this.onEvict});

  /// Number of entries currently retained in this pool.
  int get length => _entries.length;

  /// Returns an existing value for [key] or creates and caches one via [create].
  TValue obtain(TKey key, TValue Function() create) {
    final existing = _entries.remove(key);
    if (existing != null) {
      _entries[key] = existing;
      return existing;
    }
    while (_entries.length >= maxEntries && _entries.isNotEmpty) {
      final evicted = _entries.remove(_entries.keys.first);
      if (evicted != null) onEvict?.call(evicted);
    }
    final created = create();
    _entries[key] = created;
    return created;
  }

  /// Removes [key] if present.
  void remove(TKey key, {bool invokeOnEvict = true}) {
    final removed = _entries.remove(key);
    if (removed != null && invokeOnEvict) onEvict?.call(removed);
  }

  /// Clears all retained entries.
  void clear({bool invokeOnEvict = true}) {
    if (invokeOnEvict && onEvict != null) {
      for (final value in _entries.values) {
        onEvict!(value);
      }
    }
    _entries.clear();
  }
}

/// Multi-frame aligned bump allocator sub-allocating host-visible GPU buffers
/// without overwriting in-flight GPU memory mid-frame.
///
/// Cycles through [framesInFlight] frame buckets (rotated once per display
/// frame via [advanceFrame]) so multiple regions and split panes rendered in
/// the same frame always receive non-overlapping aligned byte slices.
final class GpuFrameBumpAllocator<TBuffer extends Object> {
  /// Number of in-flight frame buckets rotated before reusing buffer memory.
  final int framesInFlight;

  /// Default block capacity in bytes allocated per bucket growth step.
  final int blockSizeBytes;

  final List<List<({TBuffer buffer, int capacity})>> _frameBuckets;
  final List<List<TBuffer>> _oversizedBuckets;
  int _frameCursor = 0;
  int _blockCursor = 0;
  int _offsetCursor = 0;

  /// Creates a multi-frame bump allocator.
  GpuFrameBumpAllocator({
    this.framesInFlight = 4,
    this.blockSizeBytes = 256 * 1024,
  }) : _frameBuckets = List<List<({TBuffer buffer, int capacity})>>.generate(
         framesInFlight,
         (_) => <({TBuffer buffer, int capacity})>[],
       ),
       _oversizedBuckets = List<List<TBuffer>>.generate(
         framesInFlight,
         (_) => <TBuffer>[],
       );

  /// Current active frame bucket index (`0 .. framesInFlight - 1`).
  int get frameCursor => _frameCursor;

  /// Total number of retained buffer blocks across all frame buckets (including
  /// transient oversized allocations still in flight).
  int get totalBlockCount {
    var count = 0;
    for (var i = 0; i < framesInFlight; i++) {
      count += _frameBuckets[i].length + _oversizedBuckets[i].length;
    }
    return count;
  }

  /// Advances to the next frame bucket, resetting block and byte cursors and
  /// dropping any transient oversized blocks from the reused bucket.
  void advanceFrame() {
    _frameCursor = (_frameCursor + 1) % framesInFlight;
    _oversizedBuckets[_frameCursor].clear();
    _blockCursor = 0;
    _offsetCursor = 0;
  }

  /// Allocates an aligned slice of [byteLength] bytes aligned to [alignment].
  ({TBuffer buffer, int offsetInBytes, int lengthInBytes}) allocate({
    required int byteLength,
    required int alignment,
    required TBuffer Function(int capacityBytes) createBlock,
  }) {
    final alignedStep = alignment <= 1 ? 1 : alignment;
    if (byteLength > blockSizeBytes) {
      final oversized = createBlock(byteLength);
      _oversizedBuckets[_frameCursor].add(oversized);
      return (buffer: oversized, offsetInBytes: 0, lengthInBytes: byteLength);
    }

    final bucket = _frameBuckets[_frameCursor];
    if (bucket.isEmpty) {
      bucket.add((
        buffer: createBlock(blockSizeBytes),
        capacity: blockSizeBytes,
      ));
    }

    var alignedOffset = alignUniformByteSize(_offsetCursor, alignedStep);
    if (alignedOffset + byteLength > bucket[_blockCursor].capacity) {
      _blockCursor++;
      _offsetCursor = 0;
      alignedOffset = 0;
      while (_blockCursor < bucket.length &&
          bucket[_blockCursor].capacity < byteLength) {
        _blockCursor++;
      }
      if (_blockCursor >= bucket.length) {
        bucket.add((
          buffer: createBlock(blockSizeBytes),
          capacity: blockSizeBytes,
        ));
        _blockCursor = bucket.length - 1;
      }
    }

    final target = bucket[_blockCursor];
    _offsetCursor = alignedOffset + byteLength;
    return (
      buffer: target.buffer,
      offsetInBytes: alignedOffset,
      lengthInBytes: byteLength,
    );
  }

  /// Releases all backing buffers across all frame buckets.
  void clear() {
    for (var i = 0; i < framesInFlight; i++) {
      _frameBuckets[i].clear();
      _oversizedBuckets[i].clear();
    }
    _frameCursor = 0;
    _blockCursor = 0;
    _offsetCursor = 0;
  }
}

/// Active ping-pong texture pair for a single `prevFrameKey`.
final class GpuPingPongSlot<T extends Object> {
  /// Pixel width of both backing textures.
  final int width;

  /// Pixel height of both backing textures.
  final int height;

  /// First backing texture in the alternating pair.
  final T first;

  /// Second backing texture in the alternating pair.
  final T second;

  int _readIndex = 0;
  bool _hasHistory = false;

  /// Creates a ping-pong pair wrapping two identically sized textures.
  GpuPingPongSlot({
    required this.width,
    required this.height,
    required this.first,
    required this.second,
  });

  /// Whether at least one frame has been rendered into this ping-pong pair.
  bool get hasHistory => _hasHistory;

  /// Previously rendered texture for `iPrevFrame`, or `null` before the first
  /// frame has been written (avoiding reads from uninitialized VRAM).
  T? get readTexture {
    if (!_hasHistory) return null;
    return _readIndex == 0 ? first : second;
  }

  /// Destination texture for the current frame's write.
  T get writeTexture => _readIndex == 0 ? second : first;

  /// Marks [writeTexture] as valid and swaps it into [readTexture] for the
  /// next frame.
  void commitWriteAndSwap() {
    _hasHistory = true;
    _readIndex = 1 - _readIndex;
  }
}

/// Bounded registry managing per-`prevFrameKey` ping-pong texture pairs across
/// resizes and dynamic region lifetimes.
final class GpuPingPongRegistry<T extends Object> {
  /// Maximum number of persistent `prevFrameKey` pairs kept alive.
  final int maxEntries;

  /// Optional callback invoked for both textures of an evicted, resized,
  /// removed, or cleared ping-pong pair.
  final void Function(T evicted)? onEvict;

  final LinkedHashMap<String, GpuPingPongSlot<T>> _slots =
      LinkedHashMap<String, GpuPingPongSlot<T>>();
  final Map<String, String> _ownerTags = <String, String>{};

  /// Creates a ping-pong texture registry.
  GpuPingPongRegistry({this.maxEntries = 16, this.onEvict});

  /// Number of active ping-pong pairs.
  int get length => _slots.length;

  /// Acquires the ping-pong pair for [key] at `(width, height)`, reallocating
  /// via [allocateTexture] if absent or if the dimensions changed.
  GpuPingPongSlot<T> acquire(
    String key,
    int width,
    int height,
    T Function(int width, int height) allocateTexture, {
    String? ownerTag,
  }) {
    final existing = _slots.remove(key);
    if (existing != null &&
        existing.width == width &&
        existing.height == height) {
      _slots[key] = existing;
      if (ownerTag != null) _ownerTags[key] = ownerTag;
      return existing;
    }
    if (existing != null) _evictSlot(existing);
    _ownerTags.remove(key);
    _evictOldestIfFull();

    final created = GpuPingPongSlot<T>(
      width: width,
      height: height,
      first: allocateTexture(width, height),
      second: allocateTexture(width, height),
    );
    _slots[key] = created;
    if (ownerTag != null) _ownerTags[key] = ownerTag;
    return created;
  }

  /// Fallible variant of [acquire] returning `null` if [allocateTexture] fails
  /// (deleting the first allocation if the second allocation fails).
  GpuPingPongSlot<T>? tryAcquire(
    String key,
    int width,
    int height,
    T? Function(int width, int height) allocateTexture, {
    String? ownerTag,
  }) {
    final existing = _slots.remove(key);
    if (existing != null &&
        existing.width == width &&
        existing.height == height) {
      _slots[key] = existing;
      if (ownerTag != null) _ownerTags[key] = ownerTag;
      return existing;
    }
    if (existing != null) _evictSlot(existing);
    _ownerTags.remove(key);
    _evictOldestIfFull();

    final first = allocateTexture(width, height);
    if (first == null) return null;
    final second = allocateTexture(width, height);
    if (second == null) {
      onEvict?.call(first);
      return null;
    }
    final created = GpuPingPongSlot<T>(
      width: width,
      height: height,
      first: first,
      second: second,
    );
    _slots[key] = created;
    if (ownerTag != null) _ownerTags[key] = ownerTag;
    return created;
  }

  /// Removes a specific `prevFrameKey` entry if present.
  void remove(String key, {bool invokeOnEvict = true}) {
    final removed = _slots.remove(key);
    _ownerTags.remove(key);
    if (removed != null && invokeOnEvict) _evictSlot(removed);
  }

  /// Removes all entries associated with [ownerTag] (such as a disposed shader
  /// handle ID across all panes and regions) and returns the number removed.
  int removeByOwnerTag(String ownerTag, {bool invokeOnEvict = true}) {
    final keys = <String>[
      for (final entry in _ownerTags.entries)
        if (entry.value == ownerTag) entry.key,
    ];
    for (final key in keys) {
      final removed = _slots.remove(key);
      _ownerTags.remove(key);
      if (removed != null && invokeOnEvict) _evictSlot(removed);
    }
    return keys.length;
  }

  /// Removes all entries whose `prevFrameKey` starts with [prefix] (such as
  /// `'<paneKey>:'`) and returns the number removed.
  int removeByPrefix(String prefix, {bool invokeOnEvict = true}) {
    if (prefix.isEmpty) return 0;
    final keys = <String>[
      for (final key in _slots.keys)
        if (key.startsWith(prefix)) key,
    ];
    for (final key in keys) {
      final removed = _slots.remove(key);
      _ownerTags.remove(key);
      if (removed != null && invokeOnEvict) _evictSlot(removed);
    }
    return keys.length;
  }

  /// Clears all ping-pong texture pairs.
  void clear({bool invokeOnEvict = true}) {
    if (invokeOnEvict && onEvict != null) {
      for (final slot in _slots.values) {
        _evictSlot(slot);
      }
    }
    _slots.clear();
    _ownerTags.clear();
  }

  void _evictOldestIfFull() {
    while (_slots.length >= maxEntries && _slots.isNotEmpty) {
      final oldest = _slots.keys.first;
      final removed = _slots.remove(oldest);
      _ownerTags.remove(oldest);
      if (removed != null) _evictSlot(removed);
    }
  }

  void _evictSlot(GpuPingPongSlot<T> slot) {
    final callback = onEvict;
    if (callback == null) return;
    callback(slot.first);
    callback(slot.second);
  }
}

/// Cached triple of WebGL2 region FBO targets (`mask`, `maskFlipped`, `out`)
/// and mask-freshness metadata for a single `(paneKey, regionId)` entry.
final class WebGlRegionTargetEntry<TTarget extends Object> {
  /// Unflipped region glyph mask FBO target.
  final TTarget mask;

  /// Y-flipped region glyph mask FBO target matching `ShadertoyGlslShim`.
  final TTarget maskFlipped;

  /// Region shader output FBO target.
  final TTarget out;

  /// Physical width of all three targets.
  final int width;

  /// Physical height of all three targets.
  final int height;

  Float32List? _maskData;
  int _maskGeneration = -1;
  int _startInstance = -1;
  int _instanceCount = -1;
  Object? _atlasToken;
  bool _hasRenderedMask = false;

  /// Creates a region target triple.
  WebGlRegionTargetEntry({
    required this.mask,
    required this.maskFlipped,
    required this.out,
    required this.width,
    required this.height,
  });

  /// Returns `true` when the cached `maskFlipped` contents already match the
  /// supplied mask buffer, generation, slice bounds, and atlas texture token.
  bool matchesMask({
    required Float32List maskData,
    required int maskGeneration,
    required int startInstance,
    required int instanceCount,
    required Object? atlasToken,
  }) =>
      _hasRenderedMask &&
      identical(_maskData, maskData) &&
      _maskGeneration == maskGeneration &&
      _startInstance == startInstance &&
      _instanceCount == instanceCount &&
      identical(_atlasToken, atlasToken);

  /// Records the metadata of the freshly rasterized mask contents.
  void markMaskRendered({
    required Float32List maskData,
    required int maskGeneration,
    required int startInstance,
    required int instanceCount,
    required Object? atlasToken,
  }) {
    _maskData = maskData;
    _maskGeneration = maskGeneration;
    _startInstance = startInstance;
    _instanceCount = instanceCount;
    _atlasToken = atlasToken;
    _hasRenderedMask = true;
  }
}

/// Bounded per-`(paneKey, regionId)` LRU pool managing WebGL2 region FBO
/// triples and `uGlyphMask` freshness caching across multi-size regions.
final class WebGlRegionTargetPool<TTarget extends Object> {
  /// Maximum number of `(paneKey, regionId)` entries retained simultaneously.
  final int maxEntries;

  /// Callback invoked to delete each GPU FBO/texture target on eviction/clear.
  final void Function(TTarget target)? onDelete;

  final LinkedHashMap<(String, String), WebGlRegionTargetEntry<TTarget>>
  _entries = LinkedHashMap<(String, String), WebGlRegionTargetEntry<TTarget>>();

  /// Creates a bounded WebGL region target pool.
  WebGlRegionTargetPool({this.maxEntries = 32, this.onDelete});

  /// Number of region target triples currently retained.
  int get length => _entries.length;

  /// Acquires the target triple for `(paneKey, regionId)` at `(width, height)`.
  ///
  /// When dimensions match and the cached mask metadata matches, returns
  /// `maskCacheHit: true` so the caller can skip re-rasterizing `uGlyphMask`
  /// and its Y-flip blit. Returns `null` if [createTarget] fails.
  ({WebGlRegionTargetEntry<TTarget> entry, bool maskCacheHit})? acquire({
    required String paneKey,
    required String regionId,
    required int width,
    required int height,
    required Float32List maskData,
    required int maskGeneration,
    required int startInstance,
    required int instanceCount,
    required Object? atlasToken,
    required TTarget? Function(int width, int height) createTarget,
  }) {
    final key = (paneKey, regionId);
    final existing = _entries.remove(key);
    if (existing != null &&
        existing.width == width &&
        existing.height == height) {
      _entries[key] = existing;
      final hit = existing.matchesMask(
        maskData: maskData,
        maskGeneration: maskGeneration,
        startInstance: startInstance,
        instanceCount: instanceCount,
        atlasToken: atlasToken,
      );
      if (!hit) {
        existing.markMaskRendered(
          maskData: maskData,
          maskGeneration: maskGeneration,
          startInstance: startInstance,
          instanceCount: instanceCount,
          atlasToken: atlasToken,
        );
      }
      return (entry: existing, maskCacheHit: hit);
    }
    if (existing != null) _deleteEntry(existing);
    _evictOldestIfFull();

    final created = _allocateEntry(width, height, createTarget);
    if (created == null) return null;
    created.markMaskRendered(
      maskData: maskData,
      maskGeneration: maskGeneration,
      startInstance: startInstance,
      instanceCount: instanceCount,
      atlasToken: atlasToken,
    );
    _entries[key] = created;
    return (entry: created, maskCacheHit: false);
  }

  /// Removes all entries belonging to [paneKey] and returns the count removed.
  int removePane(String paneKey, {bool invokeOnDelete = true}) {
    final keys = <(String, String)>[
      for (final key in _entries.keys)
        if (key.$1 == paneKey) key,
    ];
    for (final key in keys) {
      final removed = _entries.remove(key);
      if (removed != null && invokeOnDelete) _deleteEntry(removed);
    }
    return keys.length;
  }

  /// Clears all entries from the pool.
  void clear({bool invokeOnDelete = true}) {
    if (invokeOnDelete && onDelete != null) {
      for (final entry in _entries.values) {
        _deleteEntry(entry);
      }
    }
    _entries.clear();
  }

  WebGlRegionTargetEntry<TTarget>? _allocateEntry(
    int width,
    int height,
    TTarget? Function(int width, int height) createTarget,
  ) {
    final mask = createTarget(width, height);
    if (mask == null) return null;
    final maskFlipped = createTarget(width, height);
    if (maskFlipped == null) {
      onDelete?.call(mask);
      return null;
    }
    final out = createTarget(width, height);
    if (out == null) {
      onDelete?.call(mask);
      onDelete?.call(maskFlipped);
      return null;
    }
    return WebGlRegionTargetEntry<TTarget>(
      mask: mask,
      maskFlipped: maskFlipped,
      out: out,
      width: width,
      height: height,
    );
  }

  void _evictOldestIfFull() {
    while (_entries.length >= maxEntries && _entries.isNotEmpty) {
      final evicted = _entries.remove(_entries.keys.first);
      if (evicted != null) _deleteEntry(evicted);
    }
  }

  void _deleteEntry(WebGlRegionTargetEntry<TTarget> entry) {
    final callback = onDelete;
    if (callback == null) return;
    callback(entry.mask);
    callback(entry.maskFlipped);
    callback(entry.out);
  }
}

final class _GpuPaneSurfaceEntry<TSurface extends Object> {
  final TSurface surface;
  int width;
  int height;

  _GpuPaneSurfaceEntry(this.surface, this.width, this.height);
}

/// Bounded per-pane LRU surface pool that resizes existing surfaces in place
/// via [onResize] rather than allocating a new surface on every resize step.
final class GpuPaneSurfacePool<TSurface extends Object> {
  /// Maximum number of distinct panes retained simultaneously.
  final int maxEntries;

  /// Optional callback invoked when a retained pane surface's dimensions change.
  final void Function(TSurface surface, int width, int height)? onResize;

  /// Optional callback invoked when a surface is evicted, removed, or cleared.
  final void Function(TSurface evicted)? onEvict;

  final LinkedHashMap<Object, _GpuPaneSurfaceEntry<TSurface>> _entries =
      LinkedHashMap<Object, _GpuPaneSurfaceEntry<TSurface>>();

  /// Creates a bounded per-pane GPU surface pool.
  GpuPaneSurfacePool({this.maxEntries = 8, this.onResize, this.onEvict});

  /// Number of pane surfaces currently retained in this pool.
  int get surfaceCount => _entries.length;

  /// Iterable view of all currently retained surfaces.
  Iterable<TSurface> get surfaces =>
      _entries.values.map((entry) => entry.surface);

  /// Returns the surface for [paneKey] at `(width, height)`, invoking
  /// [onResize] when the pane's dimensions changed, or creating a new surface
  /// via [create] (evicting the least-recently-used pane when exceeding
  /// [maxEntries]).
  TSurface obtain(
    Object paneKey,
    int width,
    int height,
    TSurface Function(int width, int height) create, {
    void Function(TSurface surface, int width, int height)? onResize,
  }) {
    final existing = _entries.remove(paneKey);
    if (existing != null) {
      if (existing.width != width || existing.height != height) {
        final resize = onResize ?? this.onResize;
        resize?.call(existing.surface, width, height);
        existing.width = width;
        existing.height = height;
      }
      _entries[paneKey] = existing;
      return existing.surface;
    }
    while (_entries.length >= maxEntries && _entries.isNotEmpty) {
      final evicted = _entries.remove(_entries.keys.first);
      if (evicted != null) onEvict?.call(evicted.surface);
    }
    final created = create(width, height);
    _entries[paneKey] = _GpuPaneSurfaceEntry<TSurface>(created, width, height);
    return created;
  }

  /// Removes the surface for [paneKey] if present.
  void remove(Object paneKey, {bool invokeOnEvict = true}) {
    final removed = _entries.remove(paneKey);
    if (removed != null && invokeOnEvict) onEvict?.call(removed.surface);
  }

  /// Clears all retained surfaces.
  void clear({bool invokeOnEvict = true}) {
    if (invokeOnEvict && onEvict != null) {
      for (final entry in _entries.values) {
        onEvict!(entry.surface);
      }
    }
    _entries.clear();
  }
}

final class _GpuPaneTextureRingEntry<TTexture extends Object> {
  final int width;
  final int height;
  final List<TTexture> textures;
  int _cursor = 0;

  _GpuPaneTextureRingEntry({
    required this.width,
    required this.height,
    required this.textures,
  });

  TTexture next() {
    final texture = textures[_cursor];
    _cursor = (_cursor + 1) % textures.length;
    return texture;
  }
}

/// Bounded per-pane LRU pool allocating a fixed-size round-robin texture ring
/// per pane, recreated only when `(width, height)` changes.
final class GpuPaneTextureRingPool<TTexture extends Object> {
  /// Maximum number of distinct panes retained simultaneously.
  final int maxEntries;

  /// Fixed number of textures allocated in each pane's round-robin ring.
  final int ringLength;

  /// Optional callback invoked for each texture evicted, resized, removed, or
  /// cleared.
  final void Function(TTexture evicted)? onEvict;

  final LinkedHashMap<Object, _GpuPaneTextureRingEntry<TTexture>> _entries =
      LinkedHashMap<Object, _GpuPaneTextureRingEntry<TTexture>>();

  /// Creates a bounded per-pane texture ring pool.
  GpuPaneTextureRingPool({
    this.maxEntries = 8,
    this.ringLength = 3,
    this.onEvict,
  }) {
    if (ringLength <= 0) {
      throw RangeError.value(ringLength, 'ringLength', 'Must be positive.');
    }
  }

  /// Number of active panes retained in this pool.
  int get paneCount => _entries.length;

  /// Total number of backing textures currently allocated across all panes.
  int get totalTextureCount {
    var total = 0;
    for (final entry in _entries.values) {
      total += entry.textures.length;
    }
    return total;
  }

  /// Acquires the next round-robin texture for [paneKey] at `(width, height)`,
  /// reallocating the ring only when absent or when `(width, height)` changes.
  TTexture acquireNext(
    Object paneKey,
    int width,
    int height,
    TTexture Function(int width, int height) create,
  ) {
    final existing = _entries.remove(paneKey);
    if (existing != null &&
        existing.width == width &&
        existing.height == height) {
      _entries[paneKey] = existing;
      return existing.next();
    }
    if (existing != null) _evictEntry(existing);
    while (_entries.length >= maxEntries && _entries.isNotEmpty) {
      final evicted = _entries.remove(_entries.keys.first);
      if (evicted != null) _evictEntry(evicted);
    }
    final textures = List<TTexture>.generate(
      ringLength,
      (_) => create(width, height),
      growable: false,
    );
    final entry = _GpuPaneTextureRingEntry<TTexture>(
      width: width,
      height: height,
      textures: textures,
    );
    _entries[paneKey] = entry;
    return entry.next();
  }

  /// Removes [paneKey] and its ring textures if present.
  void remove(Object paneKey, {bool invokeOnEvict = true}) {
    final removed = _entries.remove(paneKey);
    if (removed != null && invokeOnEvict) _evictEntry(removed);
  }

  /// Clears all retained pane texture rings.
  void clear({bool invokeOnEvict = true}) {
    if (invokeOnEvict && onEvict != null) {
      for (final entry in _entries.values) {
        _evictEntry(entry);
      }
    }
    _entries.clear();
  }

  void _evictEntry(_GpuPaneTextureRingEntry<TTexture> entry) {
    final callback = onEvict;
    if (callback == null) return;
    for (final texture in entry.textures) {
      callback(texture);
    }
  }
}

final class _GpuPaneTextureEntry<TTexture extends Object> {
  final TTexture texture;
  final int width;
  final int height;

  const _GpuPaneTextureEntry(this.texture, this.width, this.height);
}

/// Bounded per-pane LRU pool retaining a single texture per pane, recreating
/// it only when `(width, height)` changes.
final class GpuPaneTexturePool<TTexture extends Object> {
  /// Maximum number of distinct pane textures retained simultaneously.
  final int maxEntries;

  /// Optional callback invoked when a texture is evicted, resized, removed, or
  /// cleared.
  final void Function(TTexture evicted)? onEvict;

  final LinkedHashMap<Object, _GpuPaneTextureEntry<TTexture>> _entries =
      LinkedHashMap<Object, _GpuPaneTextureEntry<TTexture>>();

  /// Creates a bounded per-pane single-texture pool.
  GpuPaneTexturePool({this.maxEntries = 8, this.onEvict});

  /// Number of textures currently retained in this pool.
  int get textureCount => _entries.length;

  /// Returns the cached texture for [paneKey] at `(width, height)`, recreating
  /// via [create] if absent or resized and evicting the LRU entry when full.
  TTexture obtain(
    Object paneKey,
    int width,
    int height,
    TTexture Function(int width, int height) create,
  ) {
    final existing = _entries.remove(paneKey);
    if (existing != null &&
        existing.width == width &&
        existing.height == height) {
      _entries[paneKey] = existing;
      return existing.texture;
    }
    if (existing != null) onEvict?.call(existing.texture);
    while (_entries.length >= maxEntries && _entries.isNotEmpty) {
      final evicted = _entries.remove(_entries.keys.first);
      if (evicted != null) onEvict?.call(evicted.texture);
    }
    final created = create(width, height);
    _entries[paneKey] = _GpuPaneTextureEntry<TTexture>(created, width, height);
    return created;
  }

  /// Removes the texture for [paneKey] if present.
  void remove(Object paneKey, {bool invokeOnEvict = true}) {
    final removed = _entries.remove(paneKey);
    if (removed != null && invokeOnEvict) onEvict?.call(removed.texture);
  }

  /// Clears all retained textures.
  void clear({bool invokeOnEvict = true}) {
    if (invokeOnEvict && onEvict != null) {
      for (final entry in _entries.values) {
        onEvict!(entry.texture);
      }
    }
    _entries.clear();
  }
}

/// Per-pane in-flight GPU frame backpressure gate with stale-frame expiry.
final class GpuInFlightFrameGate {
  static final Stopwatch _monotonicClock = Stopwatch()..start();

  static int _defaultNowUs() => _monotonicClock.elapsedMicroseconds;

  /// Maximum concurrent in-flight GPU frames allowed per pane (`0` = uncapped).
  final int maxFramesInFlight;

  /// Duration after which an uncompleted submission is treated as stale and
  /// expired so a dropped callback can never wedge a pane permanently.
  final Duration staleTimeout;

  final int Function() _nowUs;
  final Map<Object, LinkedHashMap<int, int>> _inFlightByPane =
      <Object, LinkedHashMap<int, int>>{};

  int _nextToken = 0;
  int _totalInFlight = 0;
  int _totalSkips = 0;
  int _lastCompletionUs = 0;

  /// Creates a per-pane in-flight GPU frame gate.
  GpuInFlightFrameGate({
    this.maxFramesInFlight = 2,
    this.staleTimeout = const Duration(seconds: 1),
    int Function()? nowUs,
  }) : _nowUs = nowUs ?? _defaultNowUs;

  /// Total currently active (non-stale) in-flight frames across all panes.
  int get totalInFlight {
    _pruneAllStale(_nowUs());
    return _totalInFlight;
  }

  /// Cumulative frames skipped due to per-pane in-flight backpressure.
  int get totalSkips => _totalSkips;

  /// Most recent recorded GPU completion latency in microseconds.
  int get lastCompletionUs => _lastCompletionUs;

  /// Number of currently active (non-stale) in-flight frames for [paneKey].
  int inFlightFor(Object paneKey) {
    _prunePaneStale(paneKey, _nowUs());
    return _inFlightByPane[paneKey]?.length ?? 0;
  }

  /// Attempts to acquire an in-flight GPU slot for [paneKey], returning a
  /// positive submission token on success or `null` when capped.
  ///
  /// When [bypassForPriming] is `true`, the per-pane cap is bypassed so an
  /// unprimed pane can always render its initial frame. Returns `null` and
  /// increments [totalSkips] when [paneKey] has reached [maxFramesInFlight].
  int? tryAcquire(Object paneKey, {required bool bypassForPriming}) {
    final now = _nowUs();
    _prunePaneStale(paneKey, now);
    final slots = _inFlightByPane[paneKey];
    final paneCount = slots?.length ?? 0;
    if (!bypassForPriming &&
        maxFramesInFlight > 0 &&
        paneCount >= maxFramesInFlight) {
      _totalSkips++;
      return null;
    }
    final token = ++_nextToken;
    final target =
        slots ?? (_inFlightByPane[paneKey] = LinkedHashMap<int, int>());
    target[token] = now;
    _totalInFlight++;
    return token;
  }

  /// Records completion of submission [token] for [paneKey] with measured GPU
  /// latency [durationUs] in microseconds.
  ///
  /// Unknown or already-expired tokens are ignored so late callbacks never
  /// release a newer active frame's slot.
  void recordCompletion(Object paneKey, int token, int durationUs) {
    if (!release(paneKey, token)) return;
    _lastCompletionUs = durationUs < 0 ? 0 : durationUs;
  }

  /// Releases submission [token] for [paneKey] without updating
  /// [lastCompletionUs] (e.g. when a submission aborts before dispatch).
  ///
  /// Returns `true` if [token] was active and removed, or `false` if it was
  /// already completed or expired.
  bool release(Object paneKey, int token) {
    final slots = _inFlightByPane[paneKey];
    if (slots == null) return false;
    final removed = slots.remove(token);
    if (removed == null) return false;
    if (_totalInFlight > 0) _totalInFlight--;
    if (slots.isEmpty) _inFlightByPane.remove(paneKey);
    return true;
  }

  /// Removes any tracked in-flight entries for an evicted or disposed [paneKey].
  void removePane(Object paneKey) {
    final removed = _inFlightByPane.remove(paneKey);
    if (removed == null) return;
    _totalInFlight = math.max(0, _totalInFlight - removed.length);
  }

  /// Clears all per-pane in-flight maps and diagnostic counters.
  void reset() {
    _inFlightByPane.clear();
    _totalInFlight = 0;
    _totalSkips = 0;
    _lastCompletionUs = 0;
  }

  void _prunePaneStale(Object paneKey, int now) {
    final slots = _inFlightByPane[paneKey];
    if (slots == null) return;
    _pruneSlotMap(slots, now);
    if (slots.isEmpty) _inFlightByPane.remove(paneKey);
  }

  void _pruneAllStale(int now) {
    if (_inFlightByPane.isEmpty) return;
    _inFlightByPane.removeWhere((_, slots) {
      _pruneSlotMap(slots, now);
      return slots.isEmpty;
    });
  }

  void _pruneSlotMap(LinkedHashMap<int, int> slots, int now) {
    final timeoutUs = staleTimeout.inMicroseconds;
    while (slots.isNotEmpty) {
      final oldestKey = slots.keys.first;
      if ((now - slots[oldestKey]!) < timeoutUs) break;
      slots.remove(oldestKey);
      if (_totalInFlight > 0) _totalInFlight--;
    }
  }
}
