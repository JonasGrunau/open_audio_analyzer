// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/widgets.dart';

import 'focusable.dart';
import 'slider.dart';
import 'theme.dart';
import 'tokens.dart';

/// A boolean on a meter: a box, and the word it switches.
///
/// The second control that lives on the measurement surface rather than in a
/// panel — it sits in the oscilloscope's control strip beside [OaaSlider] — and
/// deliberately **not** [OaaToggle], for two reasons that are both about the
/// surface rather than about taste. A panel's switch is 18 px tall where a
/// slider's whole row is [OaaSlider.height], so a strip built from the two
/// would have rows of different heights; and it draws its on state in
/// [OaaColors.accent], the hue the canvas reserves for *in spec*, which nothing
/// on a module may borrow. See the note on that role.
///
/// So this one is told apart by fill and weight instead: an empty hairline box
/// that fills with the same ink its caption is drawn in. Nothing here reaches
/// [OaaColors.textPrimary] except hover and focus, the way the slider's thumb
/// does — on a module the readings are the brightest thing on screen and a
/// control that outshone them would read as one.
class OaaCheck extends StatelessWidget {
  const OaaCheck({
    required this.label,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
    super.key,
  });

  /// The word beside the box. Upper case, like every other label on a module.
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// What this switches, where [label] does not say it on its own. Merged into
  /// the announcement with the caption rather than replacing it.
  final String? semanticLabel;

  /// The box. Small enough to sit in a slider's row with a hairline of ground
  /// above and below it, which is what keeps the strip's rows one height.
  static const double _box = Space.sm + Space.xxs;

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    return OaaFocusable(
      onActivate: () => onChanged(!value),
      toggled: value,
      semanticLabel: semanticLabel,
      builder: (context, hovered, focused) {
        final ink = focused || hovered
            ? colors.textPrimary
            : value
            ? colors.textMuted
            : colors.textFaint;
        return SizedBox(
          height: OaaSlider.height,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: _box,
                height: _box,
                decoration: BoxDecoration(
                  borderRadius: OaaRadius.allXs,
                  border: Border.all(color: ink, width: OaaStroke.hairline),
                ),
                // The tick is a square — at ten pixels a checkmark is four
                // grey pixels and a guess — inset by a hairline of ground
                // rather than filled to the border, so a checked box reads as
                // filled and not as a box whose border got thicker.
                child: value
                    ? Padding(
                        padding: const EdgeInsets.all(Space.xxs),
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: ink),
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: Space.xs),
              // Clipped rather than allowed to overflow. The caller gives this
              // control a cell whose width was measured against the label face
              // the application bundles, and a fallback font — or a test
              // binding, whose placeholder glyph is a square em and half again
              // as wide — must cost the end of a word rather than a layout
              // assertion that takes the whole strip with it.
              Flexible(
                child: Text(
                  label,
                  style: OaaType.label.copyWith(color: ink),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
