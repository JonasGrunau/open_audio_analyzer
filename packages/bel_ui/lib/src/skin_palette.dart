// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:bel_core/bel_core.dart';
import 'package:flutter/widgets.dart';

import 'tokens.dart';

/// The one place a [Skin] becomes a [BelColors].
///
/// It is a free function in its own file rather than a constructor on
/// [BelColors] so that `tokens.dart` — which every module painter imports —
/// keeps importing nothing but `dart:ui`. The domain model knows what a skin
/// *is*; this knows what a skin *looks like*; and the thirteen painters need
/// neither.
///
/// **Call this once per skin, not once per build.** `BelColors` has value
/// equality precisely so that an accidental rebuild is cheap, but a palette
/// rebuilt in `build()` still allocates thirteen `Color`s a frame for nothing.
/// The application holds one instance per skin in a provider.
BelColors belColorsFromSkin(Skin skin, {Skin? base}) {
  Color read(SkinColor role) => Color(skin.resolve(role, base: base));

  return BelColors(
    background: read(SkinColor.background),
    panel: read(SkinColor.panel),
    panelRaised: read(SkinColor.panelRaised),
    hairline: read(SkinColor.hairline),
    hairlineStrong: read(SkinColor.hairlineStrong),
    textPrimary: read(SkinColor.textPrimary),
    textMuted: read(SkinColor.textMuted),
    textFaint: read(SkinColor.textFaint),
    accent: read(SkinColor.accent),
    warn: read(SkinColor.warn),
    over: read(SkinColor.over),
    meterTrack: read(SkinColor.meterTrack),
    meterFill: read(SkinColor.meterFill),
    isLight: skin.isLight,
  );
}

/// The reverse: a palette as a skin document.
///
/// This is what "start a skin from the one I am looking at" writes out. Without
/// it, authoring a skin means copying thirteen hex values out of the source of a
/// package the user does not have checked out, which is the difference between a
/// format that is open and a format that is merely documented.
Skin skinFromColors(
  BelColors colors, {
  required String id,
  required String name,
  String note = '',
}) => Skin(
  id: id,
  name: name,
  isLight: colors.isLight,
  note: note,
  colors: {
    SkinColor.background: _argb(colors.background),
    SkinColor.panel: _argb(colors.panel),
    SkinColor.panelRaised: _argb(colors.panelRaised),
    SkinColor.hairline: _argb(colors.hairline),
    SkinColor.hairlineStrong: _argb(colors.hairlineStrong),
    SkinColor.textPrimary: _argb(colors.textPrimary),
    SkinColor.textMuted: _argb(colors.textMuted),
    SkinColor.textFaint: _argb(colors.textFaint),
    SkinColor.accent: _argb(colors.accent),
    SkinColor.warn: _argb(colors.warn),
    SkinColor.over: _argb(colors.over),
    SkinColor.meterTrack: _argb(colors.meterTrack),
    SkinColor.meterFill: _argb(colors.meterFill),
  },
);

/// `Color.value` is deprecated in favour of the floating-point channels, which
/// do not round-trip through an 8-bit hex string. Every colour Bel deals in came
/// from one, so quantising back is exact rather than lossy.
int _argb(Color color) =>
    (_channel(color.a) << 24) |
    (_channel(color.r) << 16) |
    (_channel(color.g) << 8) |
    _channel(color.b);

int _channel(double value) => (value * 255.0).round().clamp(0, 255);
