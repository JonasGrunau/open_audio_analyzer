// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Lays out one paragraph, once.
///
/// For the parts of a meter that never change: tick labels, channel names, axis
/// units. Build them in the [State], keep them, and paint them every frame for
/// the cost of a `drawParagraph`.
///
/// The alternative — a `Text` widget, or laying out inside `paint` — is the
/// single most expensive mistake available in this codebase. A spectrum
/// analyser has nine octave labels; laying those out at 60 fps is 540 text
/// layouts a second to draw nine strings that have not changed since startup.
///
/// **[align] is meaningless without a [maxWidth], and worse than meaningless
/// if it is `center` or `right`.** Alignment is relative to the line box, and
/// an unconstrained line box is [_unconstrained] wide — so a centred glyph is
/// drawn half a megapixel to the right of wherever the paragraph is painted,
/// which is to say nowhere. It fails silently in both directions: nothing is
/// drawn, and `longestLine` still reports the width of the ink, so every
/// measurement taken around it looks correct. The `M` and `S` under the LUFS
/// meter's bars were invisible this way. Pass the box you want the text
/// aligned in, or leave the default and place the paragraph yourself.
ui.Paragraph layoutParagraph(
  String text,
  TextStyle style, {
  TextAlign align = TextAlign.left,
  double maxWidth = double.infinity,
}) {
  final builder =
      ui.ParagraphBuilder(
          style.getParagraphStyle(textAlign: align, maxLines: 1),
        )
        ..pushStyle(style.getTextStyle())
        ..addText(text);
  return builder.build()..layout(
    ui.ParagraphConstraints(
      width: maxWidth.isFinite ? maxWidth : _unconstrained,
    ),
  );
}

/// Wide enough that a single line never wraps, finite because
/// `ParagraphConstraints` rejects infinity.
const double _unconstrained = 1048576;

/// One paragraph for one string that keeps changing.
///
/// Re-lays-out only when the *formatted* string differs. That distinction is
/// the whole point: a loudness reading changes continuously and its rendering —
/// rounded to a tenth — changes perhaps ten times a second, so at 60 fps five
/// frames in six reuse a paragraph that is already laid out.
///
/// One per changing readout. A meter with four of them holds four of these,
/// which is cheaper and considerably clearer than a keyed cache that would
/// have to build a lookup key per frame — string concatenation on the paint
/// path being exactly the allocation this design exists to avoid.
class ValueParagraph {
  ui.Paragraph? _paragraph;
  String? _text;
  TextStyle? _style;
  TextAlign? _align;
  double? _width;

  /// The laid-out paragraph, rebuilt only if something about it changed.
  ui.Paragraph of(
    String text,
    TextStyle style, {
    TextAlign align = TextAlign.left,
    double maxWidth = double.infinity,
  }) {
    if (_paragraph == null ||
        _text != text ||
        _style != style ||
        _align != align ||
        _width != maxWidth) {
      _text = text;
      _style = style;
      _align = align;
      _width = maxWidth;
      _paragraph = layoutParagraph(
        text,
        style,
        align: align,
        maxWidth: maxWidth,
      );
    }
    return _paragraph!;
  }

  /// Drops the cached paragraph. Modules call this from `dispose`.
  void dispose() {
    _paragraph = null;
    _text = null;
  }
}
