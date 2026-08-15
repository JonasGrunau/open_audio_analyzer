// SPDX-License-Identifier: GPL-3.0-or-later

// The two shapes the status bar is built from.
//
// They live here rather than in `bel_app.dart` because the bar is not assembled
// in one file: `RemoteDisplayControl` owns a socket and an mDNS responder and
// therefore has to stay in `lib/src/remote/`, but the thing it puts in the row
// is a button like any other. It was a stock `TextButton` for a whole phase —
// borderless, ink-rippled and Material-sized in a row of four bordered
// `BarButton`s — which is what a private widget in `bel_app.dart` costs.
//
// They are *not* `BelButton` and they never will be. `bel_ui`'s buttons are
// sized for a panel, where a control has a whole row to itself; these are sized
// for a 40 px bar that also has to hold the source, the clock, the calibration
// and the frame rate.

import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/material.dart';

/// A bordered readout in the bar. Not interactive on its own — the two callers
/// put one inside a `PopupMenuButton`.
class BarChip extends StatelessWidget {
  const BarChip({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.xs,
      ),
      decoration: BoxDecoration(
        borderRadius: BelRadius.allXs,
        border: Border.all(color: colors.hairline, width: BelStroke.hairline),
      ),
      // Calibration names run long ("Streaming (−14 LUFS)"), and this chip sits
      // in a Row that has no slack. Ellipsis rather than overflow.
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: BelType.caption.copyWith(color: colors.textMuted),
      ),
    );
  }
}

/// A button in the status bar.
class BarButton extends StatelessWidget {
  const BarButton({
    required this.label,
    required this.onPressed,
    this.tooltip,
    this.semanticLabel,
    this.lit = false,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;

  /// Shown on hover. Carries the scope of anything whose one-word label cannot
  /// — see `RESET`.
  final String? tooltip;

  /// Only for a button whose label is a glyph. Where the label is a word, the
  /// word is the announcement and this stays null rather than repeating it.
  final String? semanticLabel;

  /// Whether this button is reporting a state that is currently *on*.
  ///
  /// Brightness rather than hue, and deliberately so: `accent` in this bar
  /// means "in spec", because it is the colour a loudness reading turns when it
  /// meets its target. A second meaning for it a few pixels away turns every
  /// lit thing in the row into a possible verdict on the numbers beside it. The
  /// bar already says "on" this way — see the source picker's dot.
  final bool lit;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    final button = BelFocusable(
      onActivate: onPressed,
      semanticLabel: semanticLabel,
      builder: (context, hovered, focused) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.smd,
          vertical: Space.xs,
        ),
        decoration: BoxDecoration(
          borderRadius: BelRadius.allXs,
          color: hovered ? colors.panelRaised : null,
          border: Border.all(
            color: focused ? colors.textPrimary : colors.hairlineStrong,
            width: BelStroke.hairline,
          ),
        ),
        child: Text(
          label,
          style: BelType.label.copyWith(
            color: lit ? colors.textPrimary : colors.textMuted,
          ),
        ),
      ),
    );

    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
