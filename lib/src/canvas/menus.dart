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
/// the two greys out every action menu in the application — and, since the
/// check column [OaaMenuRow] reserves is reserved for `false` as well as for
/// `true`, indents every one of them past a mark none of their rows can ever
/// carry.
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
      selected: selected,
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

/// A menu that **stays open** while several values are switched on and off.
///
/// Every other menu in the application holds one value: you pick a metric, a
/// ramp, a time base, and picking it is also how you say you are finished. A
/// set is not that. Choosing which four of five delivery criteria a Validator
/// judges through a menu that closes on every tap is four round trips through
/// a right click and a submenu, and the fourth one is where somebody discovers
/// they wanted the second back.
///
/// Flutter's `PopupMenuItem` pops the route on tap and offers no way to refuse,
/// so the whole list is **one disabled item** whose child is the rows. Disabled
/// costs nothing here — the item's own ink response is what would close the
/// menu — and the rows inside it are live: a disabled `InkWell` is opaque to
/// hit testing but hit-tests its children first, so each row's own tap lands.
/// Keyboard traversal is what it costs, which is why the row that opened this
/// menu names the count — `Checks: 2 of 3` is readable without opening it at
/// all.
///
/// [onToggle] is called with the value and the state it has just been given,
/// and is expected to write it through immediately rather than at the end. That
/// is the second half of staying open: the module under the menu is repainted
/// as each row is ticked, so the table being assembled is the one being looked
/// at. It is why this returns nothing — there is no result to wait for, only a
/// menu that has been dismissed.
Future<void> showOaaToggleMenu<T>(
  BuildContext context,
  Offset globalPosition, {
  required List<T> values,
  required String Function(T value) label,
  required Set<T> chosen,
  required void Function(T value, bool on) onToggle,
  bool Function(T value)? isEnabled,
}) {
  final colors = OaaTheme.of(context);
  return showMenu<void>(
    context: context,
    color: colors.panelRaised,
    position: menuPositionAt(context, globalPosition),
    items: [
      PopupMenuItem<void>(
        enabled: false,
        padding: EdgeInsets.zero,
        // The item is the whole list, so Material's one-row minimum would only
        // pad a menu that is already as tall as its rows make it.
        height: 0,
        child: StatefulBuilder(
          builder: (context, setState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final value in values)
                _ToggleRow(
                  colors: colors,
                  label: label(value),
                  on: chosen.contains(value),
                  // A value this menu's owner cannot act on is greyed and left
                  // in place rather than dropped, for the reason `oaaMenuItem`
                  // gives — and it keeps its check, because "chosen, and this
                  // target says nothing to judge it against" is two facts.
                  enabled: isEnabled?.call(value) ?? true,
                  onTap: () {
                    final on = !chosen.contains(value);
                    setState(() {
                      if (on) {
                        chosen.add(value);
                      } else {
                        chosen.remove(value);
                      }
                    });
                    onToggle(value, on);
                  },
                ),
            ],
          ),
        ),
      ),
    ],
  );
}

/// One row of [showOaaToggleMenu], which is [OaaMenuRow] with a tap of its own.
class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.colors,
    required this.label,
    required this.on,
    required this.enabled,
    required this.onTap,
  });

  final OaaColors colors;
  final String label;
  final bool on;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: enabled ? onTap : null,
    child: OaaMenuRow(
      colors: colors,
      selected: on,
      child: Text(
        label,
        style: OaaType.body.copyWith(
          color: enabled
              ? (on ? colors.textPrimary : colors.textMuted)
              : colors.textFaint,
        ),
      ),
    ),
  );
}
