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

PopupMenuItem<T> oaaMenuItem<T>(
  BuildContext context,
  T value,
  String label, {
  Color? color,
}) {
  final colors = OaaTheme.of(context);
  return PopupMenuItem<T>(
    value: value,
    height: Space.xl,
    child: Text(
      label,
      style: OaaType.body.copyWith(color: color ?? colors.textPrimary),
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
