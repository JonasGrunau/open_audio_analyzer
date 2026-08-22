// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';

/// The popup menus the canvas and the tab strip share.
///
/// Both places offer "add a module", and a second copy of that list is a second
/// place to forget a module kind. Open Audio Analyzer draws almost nothing with
/// Material, but its menus are one of the few stock widgets worth keeping: they
/// handle screen-edge collision, keyboard traversal and dismissal correctly,
/// and reimplementing that to avoid one dependency would be a poor trade.

/// Anchors a menu at a pointer position.
RelativeRect menuPositionAt(BuildContext context, Offset globalPosition) {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  return RelativeRect.fromRect(
    Rect.fromPoints(globalPosition, globalPosition),
    Offset.zero & overlay.size,
  );
}

/// A row of one of those menus.
///
/// [selected] marks the value the menu currently holds, for the menus that hold
/// one — a module's metric, its scale, its trigger. It is a parameter rather
/// than a colour the caller mixes because there were twelve call sites writing
/// `x == current ? textPrimary : textMuted` by hand, which is twelve places for
/// the convention to drift and, when it turned out to be the wrong way round,
/// twelve places to change it. What it looks like is [OaaMenuRow]'s to decide.
///
/// **`null` is not `false`.** A menu of actions — add a module, rename a tab —
/// holds no value, and every row in it is something you can do: those pass
/// nothing and are set in [OaaColors.textPrimary]. `false` is the stronger
/// claim that this row is an option in a menu that *has* a current value and is
/// not it, which is the only thing that earns [OaaColors.textMuted]. Collapsing
/// the two greys out every action menu in the application.
///
/// [color] is what is left of the old parameter: a row whose ink means
/// something other than selection. Two do — the destructive Delete in the
/// module and tab menus.
///
/// [enabled] is `false` for a setting that is *in* this menu but does nothing
/// where the module currently stands — the oscilloscope's trigger under a
/// tempo-locked window is the one. It greys and stops answering rather than
/// being left out of the list: a row that disappears is a row the user goes
/// looking for, and the setting above it — the one that turned this one off —
/// is not what they suspect. The ink is [OaaColors.textFaint], which is the
/// role's second job; the Material default would be a colour from outside the
/// skin.
PopupMenuItem<T> oaaMenuItem<T>(
  BuildContext context,
  T value,
  String label, {
  Color? color,
  bool? selected,
  bool enabled = true,
}) {
  final colors = OaaTheme.of(context);
  return PopupMenuItem<T>(
    value: value,
    height: OaaMenuRow.height,
    enabled: enabled,
    // The row owns its padding, because the fill that marks the current value
    // has to span it. See [OaaMenuRow].
    padding: EdgeInsets.zero,
    child: OaaMenuRow(
      colors: colors,
      selected: selected ?? false,
      child: Text(
        label,
        style: OaaType.body.copyWith(
          color: enabled
              ? color ??
                    (selected == false ? colors.textMuted : colors.textPrimary)
              : colors.textFaint,
        ),
      ),
    ),
  );
}

/// Offers all fourteen module kinds.
///
/// In declaration order, which is roughly simplest first, and not alphabetical:
/// somebody who has used this menu twice reaches for a position rather than
/// reading it, and sorting by name would put the Alert Meter above the LUFS
/// Meter for no reason anybody could name.
Future<ModuleKind?> showModuleKindMenu(
  BuildContext context,
  Offset globalPosition,
) {
  final colors = OaaTheme.of(context);
  return showMenu<ModuleKind>(
    context: context,
    color: colors.panelRaised,
    position: menuPositionAt(context, globalPosition),
    items: [
      for (final kind in ModuleKind.values)
        oaaMenuItem(context, kind, kind.label),
    ],
  );
}
