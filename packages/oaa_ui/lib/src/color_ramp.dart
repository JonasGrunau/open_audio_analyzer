// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui';

import 'package:oaa_core/oaa_core.dart';

import 'tokens.dart';

/// What [ColorRamp] paints.
///
/// The setting lives in `oaa_core` because it is written into presets; the
/// colours live here because they are colours.
///
/// **The two modules hand this file different quantities, and that is the
/// design rather than an inconsistency.** Colour carries whatever a module's
/// axes do not:
///
///   * The spectrogram already has frequency up one axis and time along the
///     other, so the only quantity left is the **level**, and that is what its
///     colour says. A hue per row would be a colour that repeated the y axis
///     and left the level nothing better than brightness to be read from — a
///     rainbow that looks like information and is not.
///   * The oscilloscope has amplitude and time, and no axis anywhere for
///     frequency, so colour is the only channel that can carry **which bands**
///     a slice of audio is made of. That is why DJ software colours a waveform
///     this way and why a spectrogram is never coloured that way.
///
/// So red means "loud" in one and "bass" in the other. It is worth being blunt
/// about that in the one file that owns both. What makes it hold up is that
/// each module's colour is answering the question its own axes leave open, and
/// on real material the two agree far more often than they disagree: bass is
/// the loudest part of nearly every mix, so the bottom of a spectrogram is red
/// for the same material that draws a red waveform.
///
/// Sampled into a lookup table or into a set of `Paint`s when the skin or the
/// setting changes — never per frame. Every call allocates a [Color].
extension ColorRampColors on ColorRamp {
  /// A cell of a field, at [level] of the module's range.
  ///
  /// Level 0 is the ground — *nothing at all* at [ColorRamp.skin], the ramp's
  /// own near-black at [ColorRamp.rgb] — because a cell no signal reached must
  /// not be a colour that means something.
  ///
  /// **The skin ramp's floor is transparent rather than [OaaColors.panel], and
  /// the two are not the same statement.** Composited over a flat panel they
  /// are the same pixel — the accent at alpha *t* over `panel` is exactly
  /// `lerp(panel, accent, t)` — but a module's panel is not flat: it carries
  /// the light `ModuleFrame` lays across its top-left corner. Painted as an
  /// opaque copy of the unlit panel, a spectrogram's floor cut a rectangle out
  /// of that light and the field read as a lid over the module rather than as
  /// part of it, which is not what any other module does with its plot. Every
  /// cell the signal actually reached is still opaque ink.
  Color colorAt(double level, OaaColors colors) {
    final at = level.clamp(0.0, 1.0);
    return switch (this) {
      // Ground to accent to warn: two hues, so the field has two things to
      // read. The step at 0.55 is where the accent hue is reached in full, and
      // above it the colour turns towards `warn`, so the loudest cells of a
      // frame are a different colour from the merely present ones rather than
      // a brighter shade of the same one.
      //
      // This was briefly monochrome — ground through the accent to a lighter
      // accent — on the argument that `warn` should mean "approaching a limit"
      // and nothing else. It read as a wall: on real material most bands of a
      // mix sit in the top half of the range, and a one-hue ramp gave that
      // half nothing to separate it by, so the whole field was the accent at
      // roughly one brightness. On this display the warning hue means what it
      // means on a meter's bar — the top of the scale — and a reader wants it.
      ColorRamp.skin =>
        at < 0.55
            ? colors.accent.withValues(alpha: at / 0.55)
            : Color.lerp(colors.accent, colors.warn, (at - 0.55) / 0.45)!,
      ColorRamp.rgb => _level(at),
    };
  }

  /// The colour of a slice of audio whose low, mid and high bands are at these
  /// weights, 0 to 1 each with at least one of them at 1.
  ///
  /// **The three bands *are* the three channels.** Red is the bass, green the
  /// mids, blue the highs, so a kick is red, a snare amber, a hat blue — and
  /// something with all three in it is white. It is the colouring every DJ
  /// waveform has used for twenty years, and the reason it works is that the mix
  /// is a *mix*: a kick with a hat over it is not one of them or the other, it is
  /// pink, and that is legible at a glance in a way a single hue per column is
  /// not.
  ///
  /// The weights are relative — the loudest of the three is always 1 — because
  /// the height of a waveform already says how loud it is and a colour that said
  /// so again would leave every quiet passage black. What this says is the
  /// *balance*.
  ///
  /// At [ColorRamp.skin] there is no mix in it: the answer is `accent`, which is
  /// what the module drew before this setting existed.
  Color mixAt(double low, double mid, double high, OaaColors colors) {
    if (this == ColorRamp.skin) return colors.accent;
    int channel(double weight) =>
        (_mixFloor + (255 - _mixFloor) * weight.clamp(0.0, 1.0)).round();
    return Color.fromARGB(255, channel(low), channel(mid), channel(high));
  }

  /// The ground a field of this ramp sits on, which is also its level 0.
  ///
  /// A module drawing a field paints its background in this rather than in
  /// `panel`, or the cells no signal reached and the sliver beside them are two
  /// different colours meaning the same nothing.
  ///
  /// Transparent at [ColorRamp.skin]: the panel *is* the ground there, light
  /// and all, so the field paints nothing and both the unreached cells and the
  /// sliver beside them show it. [ColorRamp.rgb] declares a ground of its own
  /// and paints it — see [kRampGround].
  Color groundOf(OaaColors colors) => switch (this) {
    ColorRamp.skin => const Color(0x00000000),
    ColorRamp.rgb => kRampGround,
  };
}

/// What [ColorRamp.rgb] draws nothing in.
///
/// Near-black rather than the skin's panel, and that is the one deliberate
/// discourtesy to the daylight skin in this file: a spectrogram is a dark
/// instrument everywhere it has ever been drawn, the ramp below is pitched
/// against black, and a rainbow over a white ground is a rainbow whose blues
/// have to be muddied to survive. Choosing `Full RGB` is choosing that ground
/// with it.
const Color kRampGround = Color(0xFF07080C);

/// What a channel carrying none of its band is still drawn with, in [mixAt].
///
/// Zero would make a pure band the fully saturated primary, which on a waveform
/// reads as a rendering fault rather than as a colour — and it would make the
/// difference between "almost no highs" and "no highs at all" a step from nearly
/// black to black. A sixth of the way up keeps a single-band slice a colour
/// somebody would choose.
const int _mixFloor = 42;

/// Where the low band ends and where the mid band does, as positions on the
/// analyser's axis.
///
/// Thirds, which is not a rounding: the axis is log-spaced from 20 Hz to
/// 20 kHz, so a third of it is a factor of ten. The bands are therefore
/// 20–200 Hz, 200 Hz–2 kHz and 2–20 kHz, which are the splits a three-band
/// waveform has always used.
const double kLowBandTop = 1 / 3;
const double kMidBandTop = 2 / 3;

/// Level to colour: the spectrogram ramp, dark through the spectrum to white.
///
/// The map Audition, iZotope and every scientific spectrogram before them used,
/// and it is the reason the rainbow is worth having here at all: the eye
/// separates far more steps of *hue* than of brightness, so a level drawn as a
/// hue is a level that can be read. What it costs is a false sense of precision
/// — the eye also finds edges between hues that are not edges in the data — and
/// for the eight percent of men who cannot separate red from green it costs the
/// top of the range. That is why the skin's one-hue ramp is still the default.
///
/// The first tenth climbs out of [kRampGround], so silence is the ground rather
/// than the darkest blue in the ramp; the top is white, which is what makes a
/// peak stand off a red field.
const List<double> _levelStops = [
  0.00,
  0.10,
  0.28,
  0.42,
  0.55,
  0.68,
  0.80,
  0.90,
  1.00,
];

const List<Color> _levelColors = [
  kRampGround, // nothing
  Color(0xFF16267F), // indigo
  Color(0xFF1F6FE0), // blue
  Color(0xFF17B8B8), // cyan
  Color(0xFF34C24B), // green
  Color(0xFFD6CE22), // yellow
  Color(0xFFE8811F), // orange
  Color(0xFFDC2626), // red
  Color(0xFFFFFFFF), // white
];

Color _level(double level) {
  for (var i = 1; i < _levelStops.length; i++) {
    if (level <= _levelStops[i]) {
      final span = _levelStops[i] - _levelStops[i - 1];
      final into = (level - _levelStops[i - 1]) / span;
      return Color.lerp(_levelColors[i - 1], _levelColors[i], into)!;
    }
  }
  return _levelColors.last;
}
