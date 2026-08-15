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

  ui.Paragraph? _labelParagraph;
  String? _labelText;

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
        BelType.reading(fontSize).copyWith(color: color),
        width,
      );
    }
    return _valueParagraph!;
  }

  ui.Paragraph unit(String text, Color color, double width) {
    if (_unitParagraph == null || _unitText != text) {
      _unitText = text;
      _unitParagraph = _layout(text, unitStyle.copyWith(color: color), width);
    }
    return _unitParagraph!;
  }

  ui.Paragraph label(String text, Color color, double width) {
    if (_labelParagraph == null || _labelText != text) {
      _labelText = text;
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
/// Centralised so that "over" is the same red in all thirteen modules. It sounds
/// trivial; it is the difference between a colour that means something and a
/// colour that is just decoration.
///
/// [ReadingState.unavailable] is [BelColors.textMuted] rather than
/// `textFaint`, and the difference is 2.81:1 against the panel versus 5.79:1.
/// The em dash is not chrome — it is the engine saying *this quantity was not
/// measured*, which is the visible end of the rule that Bel never renders an
/// unmeasured quantity as a plausible number. Printing that statement below
/// the legibility floor, next to real readings at 15:1, undoes the honesty it
/// exists to deliver: a dash nobody can see reads as a blank, and a blank
/// reads as a meter that has not started yet.
Color colorForState(ReadingState state, BelColors colors) => switch (state) {
  ReadingState.neutral => colors.textPrimary,
  ReadingState.inSpec => colors.accent,
  ReadingState.warn => colors.warn,
  ReadingState.over => colors.over,
  ReadingState.unavailable => colors.textMuted,
};
