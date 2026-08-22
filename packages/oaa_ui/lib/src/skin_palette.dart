// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_core/oaa_core.dart';
import 'package:flutter/widgets.dart';

import 'tokens.dart';

/// The one place a [Skin] becomes a [OaaColors].
///
/// It is a free function in its own file rather than a constructor on
/// [OaaColors] so that `tokens.dart` — which every module painter imports —
/// keeps importing nothing but `dart:ui`. The domain model knows what a skin
/// *is*; this knows what a skin *looks like*; and the fourteen painters need
/// neither.
///
/// **Call this once per skin, not once per build.** `OaaColors` has value
/// equality precisely so that an accidental rebuild is cheap, but a palette
/// rebuilt in `build()` still allocates thirteen `Color`s a frame for nothing.
/// The application holds one instance per skin in a provider.
OaaColors oaaColorsFromSkin(Skin skin, {Skin? base}) {
  Color read(SkinColor role) => Color(skin.resolve(role, base: base));

  return OaaColors(
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
  OaaColors colors, {
  required String id,
  required String name,
  String note = '',
}) => Skin(
  id: id,
  name: name,
  isLight: colors.isLight,
  note: note,
  colors: {
    SkinColor.background: skinArgb(colors.background),
    SkinColor.panel: skinArgb(colors.panel),
    SkinColor.panelRaised: skinArgb(colors.panelRaised),
    SkinColor.hairline: skinArgb(colors.hairline),
    SkinColor.hairlineStrong: skinArgb(colors.hairlineStrong),
    SkinColor.textPrimary: skinArgb(colors.textPrimary),
    SkinColor.textMuted: skinArgb(colors.textMuted),
    SkinColor.textFaint: skinArgb(colors.textFaint),
    SkinColor.accent: skinArgb(colors.accent),
    SkinColor.warn: skinArgb(colors.warn),
    SkinColor.over: skinArgb(colors.over),
    SkinColor.meterTrack: skinArgb(colors.meterTrack),
    SkinColor.meterFill: skinArgb(colors.meterFill),
  },
);

/// A `Color` back to the `0xAARRGGBB` the skin format stores.
///
/// `Color.value` is deprecated in favour of the floating-point channels, which
/// do not round-trip through an 8-bit hex string. Every colour Open Audio
/// Analyzer deals in came from one, so quantising back is exact rather than
/// lossy.
///
/// Public because the colour picker needs the same conversion — it edits a
/// `Color` and writes a skin — and two implementations of it are two ways to
/// round a channel.
int skinArgb(Color color) =>
    (_channel(color.a) << 24) |
    (_channel(color.r) << 16) |
    (_channel(color.g) << 8) |
    _channel(color.b);

int _channel(double value) => (value * 255.0).round().clamp(0, 255);
