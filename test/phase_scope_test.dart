// SPDX-License-Identifier: GPL-3.0-or-later
//
// The property that makes the goniometer's trail cheap without making it a
// different picture.
//
// The trail draws its dimmest frames at a fraction of their points — an eighth
// by the oldest — and the whole legitimacy of that rests on *which* fraction.
// A prefix of a slot has to be a subsample spread evenly across the analysis
// block, because a goniometer traces the signal's path in time: an even
// subsample in time is an even subsample along the path, and draws the same
// figure more sparsely. The obvious implementation — keep the first eighth of
// the samples — would instead draw one eighth *of the path*, so a fading trail
// would visibly shrink towards wherever the block happened to start.
//
// That failure is a picture, not an exception. It would look like a phase
// scope with an unusually tight trail, which is a plausible thing for a phase
// scope to look like, so it is pinned here rather than left to the eye.

import 'package:flutter_test/flutter_test.dart';
import 'package:oaa/src/modules/phase_scope.dart';
import 'package:oaa_core/oaa_core.dart';

void main() {
  group('the trail\'s stratified order', () {
    const points = MeterShape.scopePoints;

    test('is a permutation, so no sample is dropped or drawn twice', () {
      final order = PhaseScopeModule.stratifiedOrder(points);

      expect(order, hasLength(points));
      expect(order.toSet(), hasLength(points));
      expect(order.every((v) => v >= 0 && v < points), isTrue);
    });

    test('spreads every power-of-two prefix evenly across the block', () {
      final order = PhaseScopeModule.stratifiedOrder(points);

      // Position p receives sample `where[p]`. The drawn prefix is positions
      // 0..n, so that is the set whose spacing has to be even.
      final where = List<int>.filled(points, -1);
      for (var sample = 0; sample < points; sample++) {
        where[order[sample]] = sample;
      }

      // The four detail levels the module actually draws at.
      for (final take in [points, points ~/ 2, points ~/ 4, points ~/ 8]) {
        final drawn = where.take(take).toList()..sort();
        final stride = points ~/ take;

        expect(
          drawn,
          List<int>.generate(take, (i) => i * stride),
          reason:
              'a prefix of $take should be every ${stride}th sample of the '
              'block, so the figure is drawn sparsely rather than partially',
        );
      }
    });

    test('covers the whole block even at the sparsest level', () {
      final order = PhaseScopeModule.stratifiedOrder(points);
      final where = List<int>.filled(points, -1);
      for (var sample = 0; sample < points; sample++) {
        where[order[sample]] = sample;
      }

      // The eighth the oldest frames are drawn at still has to reach both ends
      // of the block; that reach is what keeps the trail the same shape.
      final sparsest = where.take(points ~/ 8).toList()..sort();
      expect(sparsest.first, 0);
      expect(sparsest.last, greaterThan(points - points ~/ 8));
    });

    test(
      'falls back to the identity on a block that is not a power of two',
      () {
        // No engine block is, but a producer is not obliged to be an engine and
        // the bit-reversal is only defined on a power of two.
        expect(
          PhaseScopeModule.stratifiedOrder(100),
          List<int>.generate(100, (i) => i),
        );
      },
    );
  });
}
