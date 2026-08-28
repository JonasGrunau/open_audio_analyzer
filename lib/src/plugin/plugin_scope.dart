// SPDX-License-Identifier: GPL-3.0-or-later
//
// The plugin link, for the two controls that offer it as a source.
//
// It is owned by `_WorkspaceState` — it holds a listening socket and outlives
// every rebuild — and read by the status bar's source picker and by the
// settings panel. Neither may construct one: a second `PluginLink` would try to
// bind a port that is already bound and would say "another copy of Open Audio
// Analyzer is already running" about this one.

import 'package:flutter/widgets.dart';

import 'plugin_link.dart';

/// Puts a [PluginLink] in scope for the widgets below it.
class PluginLinkScope extends InheritedWidget {
  const PluginLinkScope({required this.link, required super.child, super.key});

  final PluginLink link;

  /// The link in scope, for a widget below one.
  ///
  /// **Read it at the call site, not inside a panel.** A route is built by the
  /// `Navigator`, which sits above `MaterialApp.home`, so an inherited widget
  /// installed under `home` is invisible to every panel — the same boundary
  /// that kept panels from following a skin change for eight phases, and the
  /// reason `RemoteDisplayScope` is resolved this way too. `showSettingsPanel`
  /// reads this before it pushes and hands the result to the panel.
  static PluginLink of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<PluginLinkScope>();
    assert(scope != null, 'No PluginLinkScope in scope.');
    return scope!.link;
  }

  /// Never: the link is created once and lives as long as the workspace does.
  ///
  /// **Membership changes are not carried by this widget.** A plugin arriving
  /// or leaving notifies the link itself, which is a `ChangeNotifier`; anything
  /// that has to redraw for one listens to it directly. Rebuilding every
  /// dependent of a scope installed above the whole application, a few times an
  /// hour, to move a row in a menu that is usually closed, is the wrong shape.
  @override
  bool updateShouldNotify(PluginLinkScope old) => !identical(link, old.link);
}
