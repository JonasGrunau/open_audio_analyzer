// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'tokens.dart';

/// How a reading relates to its target. Drives one colour and nothing else.
enum ReadingState {
  /// No target applies, or none is set.
  neutral,

  /// Within tolerance.
  inSpec,

  /// Close to a limit.
  warn,

  /// Past a limit.
  over,

  /// The engine does not measure this. Renders as an em dash.
  unavailable,
}

/// Paints a value, its unit and its label.
///
/// This is a painter rather than a widget tree for one reason, and it is the
/// reason the whole app is fast: a `Text` widget re-lays-out and rebuilds when
/// its string changes, and a loudness readout's string changes many times a
/// second. Forty Number Boxes doing that is forty widget rebuilds per frame
/// before a single pixel has been drawn.
///
/// Instead this caches the laid-out [ui.Paragraph] and only rebuilds it when
/// the *formatted string* actually differs. Values change continuously; the
/// string rounded to one decimal changes perhaps ten times a second, and the
/// other fifty frames reuse a paragraph that is already laid out.
class ReadoutPainter {
  ReadoutPainter({
    required this.valueStyle,
    required this.unitStyle,
    required this.labelStyle,
  });

  final TextStyle valueStyle;
  final TextStyle unitStyle;
  final TextStyle labelStyle;

  ui.Paragraph? _valueParagraph;
  String? _valueText;
  Color? _valueColor;
  double? _valueFontSize;

  ui.Paragraph? _unitParagraph;
  String? _unitText;
  Color? _unitColor;

  ui.Paragraph? _labelParagraph;
  String? _labelText;
  Color? _labelColor;

  static ui.Paragraph _layout(String text, TextStyle style, double maxWidth) {
    final builder = ui.ParagraphBuilder(
      style.getParagraphStyle(textAlign: TextAlign.left, maxLines: 1),
    )..pushStyle(style.getTextStyle());
    builder.addText(text);
    return builder.build()..layout(ui.ParagraphConstraints(width: maxWidth));
  }

  /// The laid-out value, rebuilt only when the string, colour or size changed.
  ui.Paragraph value(String text, Color color, double fontSize, double width) {
    if (_valueParagraph == null ||
        _valueText != text ||
        _valueColor != color ||
        _valueFontSize != fontSize) {
      _valueText = text;
      _valueColor = color;
      _valueFontSize = fontSize;
      _valueParagraph = _layout(
        text,
        OaaType.reading(fontSize).copyWith(color: color),
        width,
      );
    }
    return _valueParagraph!;
  }

  // Keyed by colour as well as text. They cached by text alone for a long
  // time, which held until a skin change: the value's cache already carried
  // its colour — a verdict can recolour a number whose string is unchanged —
  // but a label or unit kept the old palette's ink until its text happened to
  // change, which for a static label is never.
  ui.Paragraph unit(String text, Color color, double width) {
    if (_unitParagraph == null || _unitText != text || _unitColor != color) {
      _unitText = text;
      _unitColor = color;
      _unitParagraph = _layout(text, unitStyle.copyWith(color: color), width);
    }
    return _unitParagraph!;
  }

  ui.Paragraph label(String text, Color color, double width) {
    if (_labelParagraph == null || _labelText != text || _labelColor != color) {
      _labelText = text;
      _labelColor = color;
      _labelParagraph = _layout(text, labelStyle.copyWith(color: color), width);
    }
    return _labelParagraph!;
  }

  /// Paragraphs hold native resources. Modules must call this when disposed.
  void dispose() {
    _valueParagraph = null;
    _unitParagraph = null;
    _labelParagraph = null;
  }
}

/// Maps a [ReadingState] onto the palette.
///
/// Centralised so that "over" is the same red in all fourteen modules. It sounds
/// trivial; it is the difference between a colour that means something and a
/// colour that is just decoration.
///
/// **A reading is drawn in [OaaColors.accent], and it is the only thing on the
/// measurement surface that is.** Numbers used to be [OaaColors.textPrimary]
/// — the same ink as a menu label and a panel's body text — which drew the one
/// thing a meter exists to show in the colour of the chrome around it. The signal hue now says "this is a measurement", and the palette spends
/// its remaining colours on what is *wrong* with one: amber approaching a
/// limit, red past it, a muted dash for a quantity nobody measured.
///
/// The cost is that [ReadingState.neutral] and [ReadingState.inSpec] are the
/// same colour, so a quiet integrated loudness no longer looks different from
/// an on-target one — the Validator, the Alert Meter and the delivery report
/// are where that verdict is stated in words.
///
/// [ReadingState.unavailable] is [OaaColors.textMuted] rather than
/// `textFaint`, and the difference is 2.81:1 against the panel versus 5.79:1.
/// The em dash is not chrome — it is the engine saying *this quantity was not
/// measured*, which is the visible end of the rule that Open Audio Analyzer
/// never renders an unmeasured quantity as a plausible number. Printing that
/// statement below the legibility floor, next to real readings at 15:1, undoes
/// the honesty it exists to deliver: a dash nobody can see reads as a blank,
/// and a blank reads as a meter that has not started yet.
Color colorForState(ReadingState state, OaaColors colors) => switch (state) {
  ReadingState.neutral || ReadingState.inSpec => colors.accent,
  ReadingState.warn => colors.warn,
  ReadingState.over => colors.over,
  ReadingState.unavailable => colors.textMuted,
};

/// What every quantity nobody measured is printed as.
///
/// `Metric.format` produces this for NaN, and so does each module that formats
/// a reading itself. It is named here because [inkForReading] has to recognise
/// it, and because a second literal em dash somewhere else is a dash that will
/// eventually be a different character.
const String unmeasured = '—';

/// The ink for a reading no verdict applies to.
///
/// [colorForState] with the only two states such a reading can be in: a number
/// is [OaaColors.accent], and NaN — which prints as [unmeasured] — is the
/// muted ink.
///
/// It exists because those modules settle the colour *before* they have the
/// number. The LUFS meter's momentary and short-term columns, the Super
/// Meter's short-term pair and the Digital Meter's peaks are all readings
/// passing through, judged by nothing, so each took the accent once per
/// palette and never looked at the value again —
/// and an unmeasured one's em dash then went out in the signal hue. That is
/// the one colour on the measurement surface that means *this is a
/// measurement*, spent on the statement that there is none, while the Number
/// Box and the Validator wrote the same statement in grey a module away. A
/// dash is not a reading with no verdict; it is the absence of a reading, and
/// it is grey everywhere or it is decoration.
Color inkForReading(double value, OaaColors colors) => colorForState(
  value.isNaN ? ReadingState.unavailable : ReadingState.neutral,
  colors,
);
