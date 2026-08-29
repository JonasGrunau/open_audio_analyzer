// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/widgets.dart';

/// The press-group a module's body may join — one `TapRegion.groupId` for the
/// module's slot on the canvas and for whatever inside the module wants to know
/// about a press *away* from it.
///
/// "Away" is the whole question. A press on empty canvas, on the menu bar, on
/// the tab strip or on another module is away from a module; a press on the
/// module's own title bar, its grip or its plot is not, and neither is a press
/// on an item of its own menu. Flutter's `TapRegion` decides that by hit
/// testing rather than by geometry, and lets regions that share a [id] count
/// as one — so the canvas wraps each slot in a region carrying the module's
/// id, and a body that has a cursor to dismiss wraps *its* region in the same
/// id, read from here. A press anywhere on the module is then inside for both,
/// and a press anywhere else is outside for both, with no rectangle arithmetic
/// on either side and nothing to keep in step when the slot's touch targets
/// move. The remote display, which has no canvas and no slot, provides none of
/// these; a body there reads null, stands in a group of its own, and treats
/// every press off its plot as away — which on a screen with nothing to select
/// is what a press off the plot is.
///
/// The one thing a `TapRegion` cannot know is whether a press belongs to a menu
/// or a panel standing above the route — see [isPressAway].
class ModuleTapGroup extends InheritedWidget {
  const ModuleTapGroup({required this.id, required super.child, super.key});

  /// The module's id, as the canvas knows it.
  final Object id;

  /// The enclosing module's group, or null outside a canvas slot.
  static Object? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ModuleTapGroup>()?.id;

  @override
  bool updateShouldNotify(ModuleTapGroup old) => old.id != id;
}

/// Whether a press outside a region on this route is a press *away* from what
/// the region holds — false while a menu or a panel stands above the route.
///
/// Every module menu and every panel is a route pushed above the canvas, and
/// `TapRegionSurface` sits above the `Navigator`, so a press on a menu item is
/// as much "outside" the module's region as a press on the tab strip is. It is
/// not away from the module: it is the module being configured. A module that
/// dropped its selection or its cursor because its own menu was used would be
/// one that cannot be adjusted without being deselected, and the same press on
/// the barrier — the click that closes the menu — would deselect what the user
/// was looking at. So a region asks this before acting on `onTapOutside`, and
/// while another route is current the press is that route's business.
///
/// `ModalRoute.of` rather than `Navigator.canPop`, because the remote display
/// screen is itself a pushed route: on a tablet `canPop` is true all day, and
/// a check on it would make a cursor there impossible to dismiss.
bool isPressAway(BuildContext context) =>
    ModalRoute.of(context)?.isCurrent ?? true;
