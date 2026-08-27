// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_core/oaa_core.dart';
import 'package:test/test.dart';

void main() {
  group('contrastRatio', () {
    test('black on white is the maximum', () {
      expect(contrastRatio(0xFF000000, 0xFFFFFFFF), closeTo(21.0, 0.001));
    });

    test('a colour against itself is 1', () {
      expect(contrastRatio(0xFF35E0C4, 0xFF35E0C4), closeTo(1.0, 1e-9));
    });

    test('the order of the arguments does not matter', () {
      expect(
        contrastRatio(0xFFE6E8EB, 0xFF121417),
        closeTo(contrastRatio(0xFF121417, 0xFFE6E8EB), 1e-12),
      );
    });

    // Hand-computed from the WCAG definition: textPrimary on panel in the
    // default skin. If the knee or the exponent ever drifts, this is what says
    // so — every other assertion here would still pass with a wrong curve.
    test('matches the specification on a known pair', () {
      expect(contrastRatio(0xFFE6E8EB, 0xFF121417), closeTo(15.03, 0.01));
    });

    test('alpha is composited onto the ground rather than ignored', () {
      // Half-transparent white over black is mid grey, which is nowhere near
      // white's own 21:1 against black.
      final flattened = contrastRatio(0x80FFFFFF, 0xFF000000, over: 0xFF000000);
      expect(flattened, lessThan(6.0));
      expect(flattened, greaterThan(1.0));

      // The same colour over a white ground is nearly white, and so nearly
      // invisible against it.
      expect(
        contrastRatio(0x80FFFFFF, 0xFFFFFFFF, over: 0xFFFFFFFF),
        closeTo(1.0, 0.01),
      );
    });
  });

  group('the shipped skins satisfy their own floors', () {
    for (final skin in BuiltInSkins.all) {
      test(skin.name, () {
        for (final report in checkSkinContrast(skin)) {
          expect(
            report.passes,
            isTrue,
            reason:
                '${skin.id}: ${report.rule.role.key} against '
                '${report.rule.against.key} is '
                '${report.ratio.toStringAsFixed(2)}:1, below the '
                '${report.rule.floor}:1 floor. Either the colour moved or the '
                'floor is wrong; both are decisions, neither is a rounding '
                'error.',
          );
        }
      });
    }

    // The floors are meant to be reachable but not free. If every rule in both
    // skins cleared its floor by a mile, the set would be asserting nothing.
    test('at least one rule is within 10% of its floor', () {
      final margins = [
        for (final skin in BuiltInSkins.all)
          for (final report in checkSkinContrast(skin))
            report.ratio / report.rule.floor,
      ];
      expect(margins.reduce((a, b) => a < b ? a : b), lessThan(1.10));
    });
  });

  group('checkSkinContrast', () {
    test('covers every rule, once', () {
      final reports = checkSkinContrast(BuiltInSkins.precisionInstrument);
      expect(reports, hasLength(kSkinContrastRules.length));
      expect(
        reports.map((r) => r.rule),
        containsAllInOrder(kSkinContrastRules),
      );
    });

    test('names the rule a broken skin breaks', () {
      // A track the same colour as the panel behind it: the 1.10:1 defect that
      // shipped, reproduced exactly.
      final broken = BuiltInSkins.precisionInstrument.withColor(
        SkinColor.meterTrack,
        BuiltInSkins.precisionInstrument.colors[SkinColor.panel]!,
      );

      final failed = [
        for (final report in checkSkinContrast(broken))
          if (!report.passes) report.rule,
      ];

      expect(
        failed.map((rule) => (rule.role, rule.against)),
        // The track vanishes into the panel, and the gap to the fill widens
        // rather than closes — so exactly one rule breaks.
        equals([(SkinColor.meterTrack, SkinColor.panel)]),
      );
    });

    test('a text colour set to its own surface breaks every text rule', () {
      final panel = BuiltInSkins.daylight.colors[SkinColor.panel]!;
      var broken = BuiltInSkins.daylight;
      for (final role in [
        SkinColor.textPrimary,
        SkinColor.textMuted,
        SkinColor.textFaint,
      ]) {
        broken = broken.withColor(role, panel);
      }

      final failedRoles = {
        for (final report in checkSkinContrast(broken))
          if (!report.passes) report.rule.role,
      };
      expect(
        failedRoles,
        containsAll([
          SkinColor.textPrimary,
          SkinColor.textMuted,
          SkinColor.textFaint,
        ]),
      );
    });

    test('a sparse skin is judged on the colours it inherits', () {
      // Names one role and nothing else. Resolution has to happen before the
      // arithmetic, or twelve rules read the default skin's colours against a
      // background this document never set.
      const sparse = Skin(
        id: 'sparse',
        name: 'Sparse',
        colors: {SkinColor.accent: 0xFF121417},
      );

      final failed = [
        for (final report in checkSkinContrast(sparse))
          if (!report.passes) report.rule.role,
      ];
      // The accent is now the panel colour; nothing else moved.
      expect(failed, equals([SkinColor.accent]));
    });
  });
}
