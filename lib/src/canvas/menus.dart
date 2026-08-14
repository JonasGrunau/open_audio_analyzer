// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:bel_core/bel_core.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/material.dart';

/// The popup menus the canvas and the tab strip share.
///
/// Both places offer "add a module", and a second copy of that list is a second
/// place to forget a module kind. Bel draws almost nothing with Material, but
/// its menus are one of the few stock widgets worth keeping: they handle
/// screen-edge collision, keyboard traversal and dismissal correctly, and
/// reimplementing that to avoid one dependency would be a poor trade.

/// Anchors a menu at a pointer position.
RelativeRect menuPositionAt(BuildContext context, Offset globalPosition) {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  return RelativeRect.fromRect(
    Rect.fromPoints(globalPosition, globalPosition),
    Offset.zero & overlay.size,
  );
}

PopupMenuItem<T> belMenuItem<T>(
  BuildContext context,
  T value,
  String label, {
  Color? color,
}) {
  final colors = BelTheme.of(context);
  return PopupMenuItem<T>(
    value: value,
    height: Space.xl,
    child: Text(
      label,
      style: BelType.body.copyWith(color: color ?? colors.textPrimary),
    ),
  );
}

/// Offers all twelve module kinds.
///
/// The eleven that have no painter yet are listed and marked rather than hidden
/// or disabled. Hiding them would misrepresent what Bel is; disabling them
/// would stop somebody laying out a tab now and filling it in when the meters
/// land in Phase 3.
Future<ModuleKind?> showModuleKindMenu(
  BuildContext context,
  Offset globalPosition,
) {
  final colors = BelTheme.of(context);
  return showMenu<ModuleKind>(
    context: context,
    color: colors.panelRaised,
    position: menuPositionAt(context, globalPosition),
    items: [
      for (final kind in ModuleKind.values)
        belMenuItem(
          context,
          kind,
          kind == ModuleKind.numberBox
              ? kind.label
              : '${kind.label}  ·  not built',
          color: kind == ModuleKind.numberBox
              ? colors.textPrimary
              : colors.textFaint,
        ),
    ],
  );
}
