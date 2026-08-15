// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Marks sorted by the colour they are drawn in, one buffer per colour.
///
/// Two modules draw a display made of tens of thousands of small marks in a
/// few dozen colours — the spectrogram's run-length columns and the stereo
/// cloud's accumulated cells. The obvious shape, one `drawRect` or `drawCircle`
/// per mark, builds a display list of thirty thousand ops, and *building* it is
/// work the UI thread does inside `paint`: 5.6 ms for a wide spectrogram,
/// against 0.15 ms for the same picture as one `drawRawPoints` per colour, plus
/// 0.18 ms to fill these buffers. Measured at 1200 columns of 25 runs.
///
/// Those are recording figures and only recording figures. What happens next —
/// rasterising thirty thousand marks — is the raster thread's, costs about the
/// same either way, and is much cheaper on a GPU than in the headless
/// measurement above. The frame budget this buys back is on the side that has
/// to lay the marks out.
///
/// Buffers grow to the largest frame the display has needed and are then
/// reused, so a module that has been running for a second allocates nothing on
/// the frame path.
///
/// The marks are refilled when the *data* changes, not when the module
/// repaints — see the modules that use it. A repaint on a theme change redraws
/// the same buffers.
class PointBuckets {
  PointBuckets(int buckets)
    : _data = List<Float32List>.filled(buckets, _none, growable: false),
      _used = Int32List(buckets);

  static final Float32List _none = Float32List(0);

  final List<Float32List> _data;
  final Int32List _used;

  /// How many colours this was built for. A painter's palette must be at least
  /// this long.
  int get bucketCount => _used.length;

  /// Whether anything has been added since the last [clear].
  bool get isEmpty {
    for (var bucket = 0; bucket < _used.length; bucket++) {
      if (_used[bucket] != 0) return false;
    }
    return true;
  }

  /// Drops the marks and keeps the buffers.
  void clear() {
    for (var bucket = 0; bucket < _used.length; bucket++) {
      _used[bucket] = 0;
    }
  }

  /// A dot at ([x], [y]), for [ui.PointMode.points].
  void point(int bucket, double x, double y) {
    final at = _reserve(bucket, 2);
    final data = _data[bucket];
    data[at] = x;
    data[at + 1] = y;
  }

  /// A vertical run at [x] from [top] to [bottom], for [ui.PointMode.lines].
  /// Its width is the paint's `strokeWidth`.
  void run(int bucket, double x, double top, double bottom) {
    final at = _reserve(bucket, 4);
    final data = _data[bucket];
    data[at] = x;
    data[at + 1] = top;
    data[at + 2] = x;
    data[at + 3] = bottom;
  }

  int _reserve(int bucket, int floats) {
    final at = _used[bucket];
    final data = _data[bucket];
    if (at + floats > data.length) {
      final grown = Float32List(math.max(128, (at + floats) * 2));
      grown.setRange(0, at, data);
      _data[bucket] = grown;
    }
    _used[bucket] = at + floats;
    return at;
  }

  /// One call per non-empty bucket, in bucket order — so a later bucket draws
  /// over an earlier one. [paints] is indexed by bucket.
  void draw(Canvas canvas, ui.PointMode mode, List<Paint> paints) {
    for (var bucket = 0; bucket < _used.length; bucket++) {
      final used = _used[bucket];
      if (used == 0) continue;
      canvas.drawRawPoints(
        mode,
        // A view onto the buffer, not a copy of it.
        Float32List.sublistView(_data[bucket], 0, used),
        paints[bucket],
      );
    }
  }
}
