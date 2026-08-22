// SPDX-License-Identifier: MIT

/// Whether a skin's colours can actually be read.
///
/// `oaa_ui`'s `tokens.dart` documents a contrast floor for most of the thirteen
/// roles, and it does so because two of them have already shipped below one.
/// `hairlineStrong` — the border whose entire job is to be seen — sat at 1.47:1
/// against `panel`, so every caller that needed visible selection quietly
/// reached past it for `accent` and the signal hue stopped meaning one thing.
/// `meterTrack` sat at 1.10:1, which left a bar showing its own fill and
/// nothing else, and three Super Meter arcs whose extent you could only infer
/// from the one that happened to be lit.
///
/// Both were found by looking. Neither is findable by looking at a *skin file*,
/// which is a column of hex, so this is the arithmetic that says it out loud.
///
/// **The floors live here rather than beside the picker** for two reasons. The
/// first is that `dart test packages/oaa_core` can then assert that both
/// shipped skins satisfy their own documented floors, which is the only thing
/// keeping these numbers honest against the prose in `tokens.dart` — a floor
/// nothing checks is a comment. The second is that this is a statement about
/// what a *role* means, and roles are the domain model's business; what the
/// colour looks like on a screen is `oaa_ui`'s.
///
/// Pure arithmetic on 8-bit channels. No `dart:ui`, no `Color`, nothing that
/// would make `oaa_core` learn about Flutter.
library;

import 'dart:math' as math;

import 'skin.dart';

/// The WCAG 2.x contrast ratio between two opaque colours, 1.0 to 21.0.
///
/// `(L₁ + 0.05) / (L₂ + 0.05)`, lighter over darker, where `L` is relative
/// luminance. The order of the arguments does not matter.
///
/// **Alpha is composited, not ignored.** The skin format accepts `#AARRGGBB`
/// and a translucent role is a role read against whatever is behind it; a ratio
/// computed from the unmixed channels would describe a colour nobody sees. Both
/// arguments are flattened onto [over] first, which is the surface at the
/// bottom of the stack — the skin's own `background` in [checkSkinContrast].
double contrastRatio(int argbA, int argbB, {int over = 0xFF000000}) {
  final a = _relativeLuminance(_flatten(argbA, over));
  final b = _relativeLuminance(_flatten(argbB, over));
  final lighter = a > b ? a : b;
  final darker = a > b ? b : a;
  return (lighter + 0.05) / (darker + 0.05);
}

/// One legibility requirement, as data.
///
/// [floor] is a minimum and never a maximum, which is what lets the whole set
/// be checked with one comparison. The pair that genuinely has a ceiling —
/// `meterTrack` must stay *below* `meterFill`, because a track raised until it
/// competes is a second bar — is expressed as a floor on the ratio *between*
/// them instead, which says the same thing from the other end.
class SkinContrastRule {
  const SkinContrastRule({
    required this.role,
    required this.against,
    required this.floor,
    required this.why,
  });

  /// The colour being judged.
  final SkinColor role;

  /// The surface it has to be read against.
  final SkinColor against;

  /// The ratio it must reach. Chosen below what both built-in skins achieve,
  /// so that the test asserting they pass is an assertion and not a tautology.
  final double floor;

  /// One sentence, in the words a skin's author needs. Shown in the editor.
  final String why;
}

/// What [checkSkinContrast] found for one rule.
typedef SkinContrastReport = ({
  SkinContrastRule rule,
  double ratio,
  bool passes,
});

/// Every legibility requirement the thirteen roles carry.
///
/// The measured values for the two shipped skins, at the time these floors were
/// set — Precision Instrument first, Daylight second:
///
/// | Rule | PI | Daylight |
/// |---|---:|---:|
/// | `textPrimary` on `panel` | 15.03 | 17.37 |
/// | `textMuted` on `panel` | 5.79 | 7.20 |
/// | `textFaint` on `panel` | 2.81 | 3.08 |
/// | `accent` on `panel` | 11.08 | 4.71 |
/// | `warn` on `panel` | 9.67 | 4.57 |
/// | `over` on `panel` | 5.64 | 5.43 |
/// | `hairlineStrong` on `panel` | 3.06 | 3.30 |
/// | `hairline` on `panel` | 1.17 | 1.27 |
/// | `meterFill` on `panel` | 4.20 | 3.67 |
/// | `meterTrack` on `panel` | 1.58 | 1.61 |
/// | `meterFill` over `meterTrack` | 2.66 | 2.28 |
/// | `panel` on `background` | 1.06 | 1.11 |
/// | `panelRaised` on `panel` | 1.06 | 1.04 |
///
/// Daylight's `accent` at 4.71 and `warn` at 4.57 are the tightest of them, and
/// that is the whole story of why the light skin's signal hues are darker
/// rather than the same colours on a paler ground: `#35E0C4` on white is a
/// little over 1.5:1 and unreadable at readout sizes.
const List<SkinContrastRule> kSkinContrastRules = [
  // --- Text -----------------------------------------------------------------
  SkinContrastRule(
    role: SkinColor.textPrimary,
    against: SkinColor.panel,
    floor: 7.0,
    why: 'Readings are the thing the eye lands on first.',
  ),
  SkinContrastRule(
    role: SkinColor.textMuted,
    against: SkinColor.panel,
    floor: 4.5,
    why:
        'Labels, units, and the em dash that means a quantity was not '
        'measured. That last one is a statement about the data, not a '
        'decoration, so it is held to the same floor as body text.',
  ),
  // 2.5 rather than 3.0, deliberately. `tokens.dart` records 2.81:1 as too low
  // *for the em dash* — and the fix was moving the dash to `textMuted`, not
  // raising this role. A graticule tick is meant to recede.
  SkinContrastRule(
    role: SkinColor.textFaint,
    against: SkinColor.panel,
    floor: 2.5,
    why: 'Scale ticks and disabled state. Meant to recede, not to vanish.',
  ),

  // --- Signal ---------------------------------------------------------------
  SkinContrastRule(
    role: SkinColor.accent,
    against: SkinColor.panel,
    floor: 4.5,
    why: 'In spec. A verdict printed at readout size has to be readable.',
  ),
  SkinContrastRule(
    role: SkinColor.warn,
    against: SkinColor.panel,
    floor: 4.5,
    why: 'Approaching a limit.',
  ),
  SkinContrastRule(
    role: SkinColor.over,
    against: SkinColor.panel,
    floor: 4.5,
    why: 'Over a limit. The one reading nobody may miss.',
  ),

  // --- Borders --------------------------------------------------------------
  SkinContrastRule(
    role: SkinColor.hairlineStrong,
    against: SkinColor.panel,
    floor: 3.0,
    why:
        'Selection, hover and the active module. A border whose whole job is '
        'to be seen; at 1.47:1 every caller that needed one reached for the '
        'accent instead.',
  ),
  SkinContrastRule(
    role: SkinColor.hairline,
    against: SkinColor.panel,
    floor: 1.10,
    why:
        'The only border colour. Subtle, but a division that is not there '
        'at all is a panel with no edges.',
  ),

  // --- Meters ---------------------------------------------------------------
  SkinContrastRule(
    role: SkinColor.meterFill,
    against: SkinColor.panel,
    floor: 3.0,
    why:
        'The filled part of a bar, where it carries no pass or fail meaning '
        'of its own.',
  ),
  SkinContrastRule(
    role: SkinColor.meterTrack,
    against: SkinColor.panel,
    floor: 1.4,
    why:
        'How much room is left is half of what a meter says. At 1.10:1 the '
        'track was indistinguishable from the surface behind it.',
  ),
  // The ceiling on `meterTrack`, written as a floor on the gap. Raising the
  // track until it competes with the fill is what drops this ratio, and a track
  // that competes is a second bar — worse than an invisible one.
  SkinContrastRule(
    role: SkinColor.meterFill,
    against: SkinColor.meterTrack,
    floor: 2.0,
    why:
        'The reading has to stay the figure and the track has to stay the '
        'ground. A track raised until it competes with the fill is a second '
        'bar.',
  ),

  // --- Surfaces -------------------------------------------------------------
  // Depth in this design is background steps and hairlines, never shadows, so
  // the steps have to exist. They are small on purpose: these floors say "a
  // step", not "a contrast".
  SkinContrastRule(
    role: SkinColor.panel,
    against: SkinColor.background,
    floor: 1.03,
    why:
        'A module has to be a surface sitting on the canvas rather than a '
        'hole in it.',
  ),
  SkinContrastRule(
    role: SkinColor.panelRaised,
    against: SkinColor.panel,
    floor: 1.03,
    why: 'Menus and selected rows sit one step above the panel under them.',
  ),
];

/// Every rule in [kSkinContrastRules], measured against [skin].
///
/// The skin is resolved against [base] first, so a sparse document is judged on
/// the colours it will actually be drawn with rather than on the handful it
/// happens to name.
///
/// Nothing here refuses anything. `Skin.fromJson` already tolerates a typo'd key
/// rather than declining to load, and an editor stricter than the parser is an
/// editor that will not let somebody save the palette they are looking at.
List<SkinContrastReport> checkSkinContrast(Skin skin, {Skin? base}) {
  final resolved = skin.resolved(base: base);
  final ground = resolved.resolve(SkinColor.background);

  final reports = <SkinContrastReport>[];
  for (final rule in kSkinContrastRules) {
    final ratio = contrastRatio(
      resolved.resolve(rule.role),
      resolved.resolve(rule.against),
      over: ground,
    );
    reports.add((rule: rule, ratio: ratio, passes: ratio >= rule.floor));
  }
  return reports;
}

/// Composites `argb` onto the opaque colour `over`.
///
/// Straight alpha, per channel. `over` is assumed opaque — it is a background,
/// and a background with alpha has nothing behind it to mix with.
int _flatten(int argb, int over) {
  final alpha = (argb >> 24) & 0xFF;
  if (alpha == 0xFF) return argb;

  final t = alpha / 255.0;
  int mix(int shift) {
    final top = (argb >> shift) & 0xFF;
    final bottom = (over >> shift) & 0xFF;
    return (top * t + bottom * (1 - t)).round().clamp(0, 255);
  }

  return 0xFF000000 | (mix(16) << 16) | (mix(8) << 8) | mix(0);
}

/// WCAG relative luminance. The 0.03928 knee and the 2.4 exponent are the
/// specification's, not an approximation of it.
double _relativeLuminance(int argb) {
  double channel(int shift) {
    final value = ((argb >> shift) & 0xFF) / 255.0;
    return value <= 0.03928
        ? value / 12.92
        : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0);
}
