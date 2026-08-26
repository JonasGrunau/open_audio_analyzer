// SPDX-License-Identifier: GPL-3.0-or-later

/// The File menu, drawn twice and decided once.
///
/// macOS gets a real menu in the system menu bar, because that is where a Mac
/// user looks and because Open Audio Analyzer has no title bar to hint
/// otherwise. Windows and Linux get [FileMenuButton] at the leading edge of the
/// menu bar, where a menu bar's first menu is. Both are built from
/// [FileCommand] and both run [runFileCommand], so there is one answer to what
/// Save means.
///
/// ---------------------------------------------------------------------------
/// Why the macOS menu is Swift and not `PlatformMenuBar`
///
/// `PlatformMenuBar` is the obvious tool and it cannot do this job. Two
/// reasons, either of which is enough:
///
/// **It cannot draw a checkmark.** The `flutter/menu` channel carries `label`,
/// `enabled`, `children`, `isDivider` and the shortcut keys, and no checked
/// state at all — Flutter's own sample toggles a menu item by rewriting its
/// *label*. Two of this menu's six rows are the state of the open preset, and a
/// hand-drawn tick in a label sits in the wrong column of a Mac menu.
///
/// **It owns the whole menu bar.** `setMenus` replaces every top-level menu,
/// application menu included, so adopting it would delete the stock Edit menu
/// that `MainMenu.xib` provides — and Flutter offers no platform-provided Cut,
/// Copy or Paste to rebuild it with.
///
/// So `macos/Runner/OaaFileMenu.swift` inserts an `NSMenu` after the
/// application menu, and everything else in the bar is left alone.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oaa_ui/oaa_ui.dart';

import '../canvas/menus.dart';
import 'bar_controls.dart';
import 'preset_file.dart';
import 'shortcuts.dart';

/// Whether this platform draws the menu inside the window.
///
/// True everywhere but macOS, where the File menu belongs in the system menu
/// bar — **and true on a debug macOS build as well**, because that button is
/// the row two thirds of the platforms ship and a Mac is the machine most of
/// this application is written on. It was never once on screen there, and both
/// defects it has had were ones a glance would have caught: a menu whose
/// chords did not line up, and before that a button in the wrong row. A debug
/// Mac therefore carries its File menu twice, in the system bar and in the
/// window. That is a thing to look at a button with and never a thing to ship,
/// which is what `kDebugMode` says.
///
/// **Except under `flutter test`, and that exception is the whole reason this
/// is a provider.** The suite runs on a macOS host in a debug build, so reading
/// `kDebugMode` alone would put the Windows arrangement — 58 px more in the
/// leading group — into every test in it and leave the row a Mac actually
/// ships covered by nothing. Under test this answers what the platform does,
/// and a test that wants the other arrangement overrides it, which
/// `test/scaling_test.dart` does for a band of its width sweep.
final fileMenuInWindowProvider = Provider<bool>(
  (ref) => fileMenuInWindow(
    macOS: Platform.isMacOS,
    debug: kDebugMode,
    underTest: _underTest,
  ),
);

/// The decision above, as arithmetic on the three facts it is made of.
///
/// **A function because the interesting case is the one the suite cannot
/// look at.** `flutter test` is the third argument, so a test that reads the
/// provider on a Mac can only ever be told what a Mac ships — the branch that
/// draws the button for somebody running the application is unreachable from
/// inside a test run, and would go untested in a file whose whole subject is a
/// button that went untested. Here the truth table is a table.
@visibleForTesting
bool fileMenuInWindow({
  required bool macOS,
  required bool debug,
  required bool underTest,
}) => !macOS || (debug && !underTest);

/// Whether the widget suite is what is running. `flutter test` says so in the
/// environment, and it is the only thing that does.
final bool _underTest = Platform.environment.containsKey('FLUTTER_TEST');

// ---------------------------------------------------------------------------
// In the window

/// `FILE`, and the menu under it.
///
/// A [BarButton] and not a [BarChip]. The bar's two chips are the menus that
/// hold a *value* — what is being metered, and what it is being metered against
/// — and they wear that shape because they report a state. This one holds
/// nothing and is a list of things to do.
class FileMenuButton extends ConsumerWidget {
  const FileMenuButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watched here rather than read inside the callback: the two carry rows
    // are ticked from the open preset, which changes while the window is open,
    // and the menu has to be built from current values.
    final checks = {
      for (final command in FileCommand.values)
        command: fileCommandChecked(command, ref),
    };

    return BarButton(
      label: 'FILE',
      onPressed: () => _open(context, ref, checks),
    );
  }

  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    Map<FileCommand, bool?> checks,
  ) async {
    final colors = OaaTheme.of(context);
    final apple = useAppleKeyNames;

    // Anchored under the button rather than at the pointer. A menu opened from
    // a control belongs to the control; one that appears where the mouse
    // happened to be reads as a context menu for whatever is behind it.
    final box = context.findRenderObject()! as RenderBox;
    final anchor = box.localToGlobal(Offset(0, box.size.height));

    final command = await showMenu<FileCommand>(
      context: context,
      color: colors.panelRaised,
      position: menuPositionAt(context, anchor),
      // **Material caps a popup menu at 280 px and these rows are wider.**
      // "Preset should carry the delivery target" plus its chord column is
      // about 360, so at the default the rows overflow — invisibly on macOS,
      // where this menu is never built at all. The maximum is a bound rather
      // than a width: the label below gives ground before the row does.
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 460),
      items: [
        for (final command in FileCommand.values) ...[
          if (fileCommandDividers.contains(command)) const PopupMenuDivider(),
          PopupMenuItem<FileCommand>(
            value: command,
            height: OaaMenuRow.height,
            // The row owns its padding, because the fill that marks a ticked
            // row has to span it. See [OaaMenuRow].
            padding: EdgeInsets.zero,
            child: OaaMenuRow(
              colors: colors,
              selected: checks[command],
              // **Every row of this menu keeps the check's column, including
              // the four that can never be ticked.** Two of the six are the
              // state of the open preset and four are things to do, so without
              // this the labels sit in two columns 16 px apart with a divider
              // between them — and the same menu, drawn by macOS from the same
              // table, puts all six in one column with the ticks in the margin.
              reservesCheck: true,
              child: Row(
                children: [
                  // **`Expanded`, which is what puts the chords in a column.**
                  // The row was `MainAxisSize.min` with the label `Flexible`,
                  // and that packs label and chord together at the leading
                  // edge: the chord box then floats at whatever x the label
                  // happens to end at, so `Ctrl+O` sat 90 px left of `Ctrl+I`
                  // in a menu whose whole point is that the chords are
                  // readable down the column. The fixed width below aligns a
                  // chord inside its own box and can do nothing about where
                  // that box is.
                  //
                  // It costs the menu nothing to measure: `RenderFlex` reports
                  // its maximum intrinsic width as the label plus the
                  // inflexible children either side of it, which is the same
                  // number `MainAxisSize.min` gave, and that number is what a
                  // popup menu sizes itself from.
                  Expanded(
                    child: Text(
                      command.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      // **Full ink whether the box is ticked or not.** The
                      // two rows that carry a tick here are checkboxes and not
                      // a choice between each other: either can be on with the
                      // other off, and nothing about an unticked one is
                      // unavailable. Muting the unticked row is what a menu of
                      // options does, where the muted rows are the values the
                      // menu does not currently hold — this menu holds no such
                      // value, so the same ink read as two commands that could
                      // not be pressed.
                      style: OaaType.body.copyWith(color: colors.textPrimary),
                    ),
                  ),
                  // The smallest gap a label is allowed to come to its chord
                  // at, which is what the row gives up first when the bound
                  // above is reached — the label ellipsises rather than the
                  // chord moving.
                  const SizedBox(width: Space.lg),
                  SizedBox(
                    width: _chordColumn,
                    child: Text(
                      fileCommandChord(command)?.label(apple: apple) ?? '',
                      textAlign: TextAlign.end,
                      style: OaaType.caption.copyWith(color: colors.textFaint),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );

    if (command == null || !context.mounted) return;
    await runFileCommand(command, context, ref);
  }

  /// Wide enough for `Ctrl+Shift+S`, which is the longest chord this menu has.
  static const double _chordColumn = 84;
}

// ---------------------------------------------------------------------------
// In the menu bar

/// The macOS File menu.
///
/// The Dart half of `macos/Runner/OaaFileMenu.swift`. Everything here is a
/// no-op off macOS; Windows and Linux keep their own frames and their own menus
/// and there is nothing to install.
abstract final class MacFileMenu {
  /// The same name as the channel in `OaaFileMenu.swift`. A typo here is
  /// silent.
  static const MethodChannel _channel = MethodChannel('oaa/file_menu');

  static bool get _applies => !kIsWeb && Platform.isMacOS;

  /// Builds the menu and starts listening for what it is asked to do.
  ///
  /// Called once, from the widget that owns the application's context — the
  /// command needs a `Navigator` to open a panel over, and a menu item does not
  /// come with one.
  static void install({
    required List<Map<String, Object?>> items,
    required void Function(String id) onCommand,
  }) {
    if (!_applies) return;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'command' && call.arguments is String) {
        onCommand(call.arguments as String);
      }
      return null;
    });

    _invoke('install', {'items': items});
  }

  /// Pushes the labels, the ticks and the enabled state again.
  static void update(List<Map<String, Object?>> items) =>
      _invoke('update', {'items': items});

  static void _invoke(String method, Object? arguments) {
    if (!_applies) return;
    // Swallowed for the same reason `WindowChrome` swallows it: the widget
    // suite runs with no window and no plugin registered, and a missing
    // implementation there is the expected condition rather than a failure.
    _channel.invokeMethod<void>(method, arguments).catchError((Object _) {});
  }
}

/// Keeps the macOS menu bar in step with the application.
///
/// A widget, because what the menu shows is application state and this is the
/// mechanism Flutter has for reacting to that. Pushing a channel call from
/// `build` is the shape `WindowChrome.applyPalette` already uses in
/// `OaaApp.build`, and for the same reason: the alternative is one listener per
/// provider, each of which would have to know when the others had fired.
///
/// It has to be mounted **below the `Navigator`**, because the command it ends
/// up running opens a dialog, and a menu item does not come with a route to
/// open one over.
///
/// Off macOS this is a plain pass-through: [MacFileMenu] does nothing there, and
/// the dedupe below means it does not even build a payload twice.
class MacFileMenuHost extends ConsumerStatefulWidget {
  const MacFileMenuHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<MacFileMenuHost> createState() => _MacFileMenuHostState();
}

class _MacFileMenuHostState extends ConsumerState<MacFileMenuHost> {
  /// What was last sent, so that a rebuild which changed nothing sends nothing.
  String? _sent;

  @override
  Widget build(BuildContext context) {
    // Watched here, in `build`, because that is the only place a `WidgetRef`
    // may watch: the two carry rows are ticked from the open preset, so this
    // rebuilds whenever what the preset carries changes.
    final items = fileMenuPayload(ref);

    return ValueListenableBuilder<int>(
      valueListenable: ref.watch(routeDepthProvider).depth,
      builder: (context, depth, child) {
        _push(items, enabled: depth <= 1);
        return child!;
      },
      child: widget.child,
    );
  }

  void _push(List<Map<String, Object?>> items, {required bool enabled}) {
    final payload = [
      for (final item in items) {...item, 'enabled': enabled},
    ];

    // `==` on a list of maps is identity, so the comparison is on the encoding.
    // Six short rows; it costs less than the channel hop it saves.
    final key = jsonEncode(payload);
    if (key == _sent) return;
    final first = _sent == null;
    _sent = key;

    if (first) {
      MacFileMenu.install(
        items: payload,
        onCommand: (id) {
          final command = FileCommand.byId(id);
          if (command == null || !mounted) return;
          runFileCommand(command, context, ref);
        },
      );
    } else {
      MacFileMenu.update(payload);
    }
  }
}

/// The menu as the channel carries it.
///
/// One entry per row, in order, each with the divider that goes above it. The
/// chord is sent as the character and its modifiers rather than as a printed
/// label, because AppKit draws the glyphs itself — and it is read off
/// [fileCommandChord], so the menu bar and `docs/site/keyboard.md` cannot
/// disagree about what ⌘S does.
List<Map<String, Object?>> fileMenuPayload(WidgetRef ref) => [
  for (final command in FileCommand.values)
    {
      'id': command.id,
      'label': command.label,
      'divider': fileCommandDividers.contains(command),
      'checked': fileCommandChecked(command, ref),
      ...?_chordArguments(fileCommandChord(command)),
    },
];

Map<String, Object?>? _chordArguments(Chord? chord) {
  // Only a chord AppKit can serve. `primary` is Cmd on this platform, which is
  // what a key equivalent in a Mac menu means; a bare or Ctrl-only chord stays
  // with the Dart bindings and is simply not printed here.
  if (chord == null || !chord.primary) return null;
  final label = chord.trigger.keyLabel;
  if (label.length != 1) return null;

  return {
    'key': label.toLowerCase(),
    'shift': chord.shift,
    'alt': chord.alt,
    'control': chord.control,
  };
}

// ---------------------------------------------------------------------------
// Whether the menu may act

/// How many routes deep the application is.
///
/// The macOS menu is served by AppKit, which offers a key equivalent to the
/// main menu *before* the event reaches the Flutter view — so unlike the Dart
/// bindings, ⌘O in the menu bar fires while a panel is open, where the bindings
/// cannot because a panel route sits above their `FocusScope`. Greying the menu
/// while a route is up is what makes the two platforms agree, and it is what a
/// Mac does with a sheet in front of a window.
final routeDepthProvider = Provider<RouteDepth>((ref) => RouteDepth());

/// Cached as a list, not built per rebuild: `Navigator` re-registers its
/// observers when the list it is handed is a different object.
final navigatorObserversProvider = Provider<List<NavigatorObserver>>(
  (ref) => [ref.watch(routeDepthProvider)],
);

class RouteDepth extends NavigatorObserver {
  final ValueNotifier<int> depth = ValueNotifier<int>(0);

  /// The application itself is one route. Anything above it is a panel, a
  /// confirmation, or a popup menu.
  bool get isBusy => depth.value > 1;

  @override
  void didPush(Route<Object?> route, Route<Object?>? previousRoute) =>
      depth.value++;

  @override
  void didPop(Route<Object?> route, Route<Object?>? previousRoute) =>
      depth.value--;

  @override
  void didRemove(Route<Object?> route, Route<Object?>? previousRoute) =>
      depth.value--;

  @override
  void didReplace({Route<Object?>? newRoute, Route<Object?>? oldRoute}) {}
}
