// SPDX-License-Identifier: GPL-3.0-or-later
//
// The property that makes the goniometer's trail cheap without making it a
// different picture.
//
// The trail draws its dimmest frames at a fraction of their samples — an
// eighth by the oldest — and the whole legitimacy of that rests on *which*
// fraction. A detail level has to be a subsample spread evenly across the
// analysis block, because a goniometer traces the signal's path in time: an
// even subsample in time is an even subsample along the path, and draws the
// same figure more sparsely. Keeping the first eighth of the samples instead
// would draw one eighth *of the path*, so a fading trail would visibly shrink
// towards wherever the block happened to start.
//
// The trace is a polyline, which adds the second property: every level must be
// in **time order**, because `PointMode.polygon` joins consecutive buffer
// entries, and joining samples that are far apart in time draws a web across
// the figure rather than the signal's path. And what a short block leaves
// unfilled must be NaN — a culled segment — not stale audio joined to this
// moment's.
//
// All three failures are pictures, not exceptions. They would look like a
// phase scope with an unusually tight trail, or an unusually busy one, which
// are plausible things for a phase scope to look like, so they are pinned here
// rather than left to the eye.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oaa/src/modules/phase_scope.dart';
import 'package:oaa_core/oaa_core.dart';

void main() {
  const points = MeterShape.scopePoints;

  /// A block whose sample index is readable back off either coordinate:
  /// L = index, R = −index.
  Float32List ramp(int frames) {
    final scope = Float32List(frames * 2);
    for (var i = 0; i < frames; i++) {
      scope[i * 2] = i.toDouble();
      scope[i * 2 + 1] = -i.toDouble();
    }
    return scope;
  }

  group('a trail slot', () {
    test('holds every detail level in time order, strided evenly', () {
      final slot = Float32List(PhaseScopeModule.slotFloats);
      PhaseScopeModule.writeSlot(slot, ramp(points), points);

      for (var level = 0; level < 4; level++) {
        final offset = PhaseScopeModule.levelOffset(level);
        final count = points >> level;
        final stride = 1 << level;
        for (var i = 0; i < count; i++) {
          expect(
            slot[offset + i * 2],
            (i * stride).toDouble(),
            reason:
                'level $level position $i should hold sample ${i * stride}: '
                'every ${stride}th sample of the block, in time order, so a '
                'polyline of the level draws the same figure more sparsely',
          );
          expect(slot[offset + i * 2 + 1], -(i * stride).toDouble());
        }
      }
    });

    test('even the sparsest level spans the whole block', () {
      final slot = Float32List(PhaseScopeModule.slotFloats);
      PhaseScopeModule.writeSlot(slot, ramp(points), points);

      final offset = PhaseScopeModule.levelOffset(3);
      final count = points >> 3;
      expect(slot[offset], 0);
      expect(
        slot[offset + (count - 1) * 2],
        greaterThan((points - points ~/ 8).toDouble()),
        reason:
            'the eighth the oldest frames are drawn at still has to reach '
            'both ends of the block; that reach is what keeps the trail the '
            'same shape',
      );
    });

    test('keeps the newest samples of an oversized snapshot', () {
      // A snapshot off a wire may carry several blocks in one frame; the
      // figure is drawn from the newest block's worth.
      final frames = points * 3;
      final slot = Float32List(PhaseScopeModule.slotFloats);
      PhaseScopeModule.writeSlot(slot, ramp(frames), frames);

      expect(
        slot[0],
        (frames - points).toDouble(),
        reason: 'the oldest kept sample is the first of the newest block',
      );
      expect(slot[(points - 1) * 2], (frames - 1).toDouble());
    });

    test('fills what a short block leaves with NaN, at every level', () {
      const take = 100;
      final slot = Float32List(PhaseScopeModule.slotFloats);
      PhaseScopeModule.writeSlot(slot, ramp(take), take);

      for (var level = 0; level < 4; level++) {
        final offset = PhaseScopeModule.levelOffset(level);
        final count = points >> level;
        final stride = 1 << level;
        for (var i = 0; i < count; i++) {
          final sample = i * stride;
          if (sample < take) {
            expect(slot[offset + i * 2], sample.toDouble());
          } else {
            expect(
              slot[offset + i * 2].isNaN,
              isTrue,
              reason:
                  'level $level position $i is beyond the short block and '
                  'must be NaN — a culled segment — not stale audio joined '
                  'to this moment\'s',
            );
          }
        }
      }
    });

    test('a null block blanks the slot entirely', () {
      final slot = Float32List(PhaseScopeModule.slotFloats)..fillRange(0, 4, 7);
      PhaseScopeModule.writeSlot(slot, null, 0);

      for (var i = 0; i < slot.length; i++) {
        expect(slot[i].isNaN, isTrue);
      }
    });
  });
}
