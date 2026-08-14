// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:bel_core/bel_core.dart';
import 'package:bel_engine/bel_engine.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../clock/meter_clock.dart';
import '../data/providers.dart';
import 'menus.dart';
import 'module_host.dart';
import 'workspace.dart';

/// The arrangeable canvas: twenty-four columns by sixteen rows of meters.
///
/// ---------------------------------------------------------------------------
/// Dragging must not rebuild anything
///
/// A canvas can hold a dozen live meters. If a drag rebuilt the widget tree as
/// the pointer moved, every one of those subtrees would be rebuilt at pointer
/// rate — inflating twelve modules, twelve painters and twelve cached
/// `ui.Paragraph` sets per pointer event — while the audio thread continues to
/// publish at 47 Hz and the display expects a frame every 16 ms. It would stall
/// exactly when the user is watching the screen most closely.
///
/// So a drag moves nothing. The module stays where it is, and a single
/// [ValueNotifier] drives one `CustomPainter` overlay that draws where the
/// module *would* land. Pointer movement therefore costs one comparison and, at
/// most, one repaint of one painter — no rebuild, no layout, no allocation. The
/// layout is edited exactly once, on release.
///
/// The notifier carries an immutable value with a real `==`, so the many
/// pointer events that do not change which cell is targeted do not repaint
/// either.
///
/// ---------------------------------------------------------------------------
/// Why the drag affordances sit *behind* the module
///
/// Each module is a small stack: a full-size selection catcher, a drag strip
/// over the title bar, the module itself, and a resize grip at the corner. The
/// first two are underneath, which is what gives the frame's own menu button
/// priority without any gesture-arena arbitration — a hit test that reaches the
/// menu button never gets as far as the strip.
///
/// That only works because meter painters do not absorb pointer events. See
/// [MeterPainter]: Flutter's default is that a `CustomPaint` swallows them,
/// which would make the entire body of every module dead to the mouse.
class GridCanvas extends ConsumerStatefulWidget {
  const GridCanvas({required this.engine, required this.clock, super.key});

  final BelEngine engine;
  final MeterClock clock;

  @override
  ConsumerState<GridCanvas> createState() => _GridCanvasState();
}

class _GridCanvasState extends ConsumerState<GridCanvas> {
  /// Where the module being dragged would land. Null when nothing is dragging.
  final ValueNotifier<_Preview?> _preview = ValueNotifier<_Preview?>(null);

  /// Refusals that would otherwise be invisible — "no room for that" — shown
  /// briefly at the foot of the canvas.
  final ValueNotifier<String?> _message = ValueNotifier<String?>(null);
  Timer? _messageTimer;

  _DragSession? _session;

  /// Side of the square resize grip at a module's bottom-right corner.
  static const double _gripSize = Space.md;

  @override
  void dispose() {
    _messageTimer?.cancel();
    _preview.dispose();
    _message.dispose();
    super.dispose();
  }

  WorkspaceController get _controller => ref.read(workspaceProvider.notifier);

  void _report(String message) {
    _message.value = message;
    _messageTimer?.cancel();
    _messageTimer = Timer(const Duration(seconds: 4), () {
      _message.value = null;
    });
  }

  // --- Dragging -----------------------------------------------------------

  void _beginDrag(ModuleSpec module, {required bool resize}) {
    _session = _DragSession(
      id: module.id,
      kind: module.kind,
      origin: module.rect,
      resize: resize,
      // Read once, when the pointer goes down, rather than continuously. A drag
      // whose meaning can change halfway through is a drag whose preview can
      // turn red because the module now collides with the copy of itself it is
      // still sitting on top of, which is not something anybody can be expected
      // to work out mid-gesture.
      duplicate: !resize && HardwareKeyboard.instance.isAltPressed,
    );
    _preview.value = _Preview(rect: module.rect, valid: true);
    _controller.select(module.id);
  }

  void _updateDrag(DragUpdateDetails details, GridGeometry geometry) {
    final session = _session;
    if (session == null) return;

    session.travelled += details.delta;
    final (columns, rows) = geometry.deltaInCells(session.travelled);
    final origin = session.origin;

    final GridRect target;
    if (session.resize) {
      // Clamped against the canvas edge rather than run through fitToGrid,
      // which would slide the module left to make an oversized width fit. A
      // resize must never move the corner the user is not holding.
      target = origin.copyWith(
        columns: (origin.columns + columns).clamp(
          session.kind.minColumns,
          kGridColumns - origin.column,
        ),
        rows: (origin.rows + rows).clamp(
          session.kind.minRows,
          kGridRows - origin.row,
        ),
      );
    } else {
      target = fitToGrid(
        origin.copyWith(
          column: origin.column + columns,
          row: origin.row + rows,
        ),
        session.kind,
      );
    }

    _preview.value = _Preview(
      rect: target,
      // A copy has to clear the module it was copied from; a move does not
      // have to clear the space it is vacating.
      valid: ref
          .read(workspaceProvider)
          .tab
          .accepts(target, ignoring: session.duplicate ? null : session.id),
    );
  }

  void _endDrag() {
    final session = _session;
    final preview = _preview.value;
    _session = null;
    _preview.value = null;

    // An invalid drop is simply not a drop. Nothing snaps to a nearby free
    // space, because "nearby" would sometimes mean the other side of the
    // canvas, and a module that lands somewhere the user was not pointing at
    // is worse than one that does not move.
    if (session == null || preview == null || !preview.valid) return;

    if (session.duplicate) {
      _controller.duplicateModule(session.id, at: preview.rect);
    } else {
      _controller.placeModule(session.id, preview.rect);
    }
  }

  // --- Menus --------------------------------------------------------------

  Future<void> _showAddMenu(Offset globalPosition, {GridRect? at}) async {
    final kind = await showModuleKindMenu(context, globalPosition);
    if (kind == null || !mounted) return;

    final placed = _controller.addModule(
      kind,
      at: at?.copyWith(columns: kind.defaultColumns, rows: kind.defaultRows),
    );
    if (!placed) {
      _report('No room on this tab for a ${kind.label}.');
    }
  }

  Future<void> _showModuleMenu(Offset globalPosition, ModuleSpec module) async {
    final colors = BelTheme.of(context);
    _controller.select(module.id);

    final action = await showMenu<_ModuleAction>(
      context: context,
      color: colors.panelRaised,
      position: menuPositionAt(context, globalPosition),
      items: [
        if (module.kind == ModuleKind.numberBox)
          belMenuItem(
            context,
            _ModuleAction.metric,
            'Metric — ${module.metric.label}',
            color: colors.textMuted,
          ),
        belMenuItem(context, _ModuleAction.duplicate, 'Duplicate'),
        belMenuItem(
          context,
          _ModuleAction.delete,
          'Delete',
          color: colors.over,
        ),
      ],
    );

    if (action == null || !mounted) return;

    switch (action) {
      case _ModuleAction.metric:
        await _showMetricMenu(globalPosition, module);
      case _ModuleAction.duplicate:
        if (!_controller.duplicateModule(module.id)) {
          _report('No room on this tab for another ${module.kind.label}.');
        }
      case _ModuleAction.delete:
        _controller.removeModule(module.id);
    }
  }

  Future<void> _showMetricMenu(Offset globalPosition, ModuleSpec module) async {
    final colors = BelTheme.of(context);
    final metric = await showMenu<Metric>(
      context: context,
      color: colors.panelRaised,
      position: menuPositionAt(context, globalPosition),
      items: [
        for (final metric in Metric.values)
          belMenuItem(
            context,
            metric,
            metric.label,
            color: metric == module.metric ? colors.accent : colors.textPrimary,
          ),
      ],
    );

    if (metric == null || !mounted) return;
    _controller.setModuleOption(module.id, 'metric', metric.id);
  }

  // --- Keyboard -----------------------------------------------------------

  Map<ShortcutActivator, VoidCallback> _bindings() {
    void withSelection(void Function(String id) action) {
      final id = ref.read(workspaceProvider).selectedModuleId;
      if (id != null) action(id);
    }

    return {
      const SingleActivator(LogicalKeyboardKey.delete): () =>
          withSelection(_controller.removeModule),
      const SingleActivator(LogicalKeyboardKey.backspace): () =>
          withSelection(_controller.removeModule),
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          _controller.select(null),

      // Both modifiers, unconditionally. Checking the platform to decide which
      // one to accept is a way to get it wrong on a Mac with an external PC
      // keyboard, and there is nothing else these chords could mean.
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
          _controller.undo,
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
          _controller.undo,
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
          _controller.redo,
      const SingleActivator(
        LogicalKeyboardKey.keyZ,
        control: true,
        shift: true,
      ): _controller.redo,
      const SingleActivator(LogicalKeyboardKey.keyD, meta: true): () =>
          withSelection(_controller.duplicateModule),
      const SingleActivator(LogicalKeyboardKey.keyD, control: true): () =>
          withSelection(_controller.duplicateModule),

      // Bare digits switch tabs, as they do in Decibel. There is no text entry
      // on the canvas to compete with them; the one field in the application —
      // renaming a tab — holds focus while it is open and consumes its own
      // keystrokes.
      for (var i = 0; i < 9; i++)
        SingleActivator(_digitKeys[i]): () => _controller.selectTab(i),
    };
  }

  // --- Build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    final workspace = ref.watch(workspaceProvider);
    final calibration = ref.watch(calibrationProvider);
    final tab = workspace.tab;

    return CallbackShortcuts(
      bindings: _bindings(),
      child: Focus(
        autofocus: true,
        child: Padding(
          padding: const EdgeInsets.all(Space.md),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final geometry = GridGeometry(size: constraints.biggest);

              return Stack(
                clipBehavior: Clip.none,
                children: [
                  // Bottom: empty canvas. Left click clears the selection,
                  // right click and double click add a module where the pointer
                  // is. A single left click deliberately does not open a menu —
                  // every stray click on the background would.
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _controller.select(null),
                      onDoubleTapDown: (details) => _showAddMenu(
                        details.globalPosition,
                        at: _rectAt(geometry, details.localPosition),
                      ),
                      onSecondaryTapUp: (details) => _showAddMenu(
                        details.globalPosition,
                        at: _rectAt(geometry, details.localPosition),
                      ),
                    ),
                  ),

                  if (tab.modules.isEmpty)
                    const Positioned.fill(
                      child: IgnorePointer(child: _Empty()),
                    ),

                  for (final module in tab.modules)
                    Positioned.fromRect(
                      rect: geometry.rectFor(module.rect),
                      // Keyed by module id so that moving one preserves its
                      // State — and with it the laid-out paragraphs its painter
                      // has cached. Without the key, Flutter matches children
                      // by position in the list and a move throws that cache
                      // away.
                      key: ValueKey<String>(module.id),
                      child: _ModuleSlot(
                        module: module,
                        engine: widget.engine,
                        clock: widget.clock,
                        calibration: calibration,
                        selected: module.id == workspace.selectedModuleId,
                        gripSize: _gripSize,
                        onSelect: () => _controller.select(module.id),
                        onMenu: (position) => _showModuleMenu(position, module),
                        onDragStart: (resize) =>
                            _beginDrag(module, resize: resize),
                        onDragUpdate: (details) =>
                            _updateDrag(details, geometry),
                        onDragEnd: _endDrag,
                      ),
                    ),

                  // Top: the drag preview. Repaints from its own notifier and
                  // is the only thing on screen that changes while a module is
                  // being moved.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _PreviewPainter(
                          preview: _preview,
                          geometry: geometry,
                          colors: colors,
                        ),
                      ),
                    ),
                  ),

                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: ValueListenableBuilder<String?>(
                        valueListenable: _message,
                        builder: (context, message, _) => message == null
                            ? const SizedBox.shrink()
                            : _Toast(message: message),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  GridRect _rectAt(GridGeometry geometry, Offset local) {
    final (column, row) = geometry.cellAt(local);
    return GridRect(column: column, row: row, columns: 1, rows: 1);
  }
}

const List<LogicalKeyboardKey> _digitKeys = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];

enum _ModuleAction { metric, duplicate, delete }

/// One module and the four transparent layers that make it manipulable.
class _ModuleSlot extends StatelessWidget {
  const _ModuleSlot({
    required this.module,
    required this.engine,
    required this.clock,
    required this.calibration,
    required this.selected,
    required this.gripSize,
    required this.onSelect,
    required this.onMenu,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final ModuleSpec module;
  final BelEngine engine;
  final MeterClock clock;
  final Calibration calibration;
  final bool selected;
  final double gripSize;
  final VoidCallback onSelect;
  final void Function(Offset globalPosition) onMenu;
  final void Function(bool resize) onDragStart;
  final void Function(DragUpdateDetails details) onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        // Beneath everything: select and context-menu anywhere on the module.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onSelect,
          onSecondaryTapUp: (details) => onMenu(details.globalPosition),
        ),

        // The title bar is the drag handle. Dragging by the body is tempting
        // and wrong: a histogram that can be scrubbed and a spectrum with a
        // cursor both need the body, and a canvas that claims it now is a
        // canvas that has to be unpicked in Phase 3.
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: ModuleFrame.titleBarHeight,
          child: MouseRegion(
            cursor: SystemMouseCursors.move,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // Without this the module trails the pointer by the pan slop —
              // 36 logical pixels — for the whole drag, because the default
              // behaviour reports the drag as beginning where the gesture was
              // *recognised* rather than where the finger went down. On a
              // snapping grid that is an entire column of permanent offset
              // between the pointer and the thing it is carrying.
              dragStartBehavior: DragStartBehavior.down,
              onTap: onSelect,
              onSecondaryTapUp: (details) => onMenu(details.globalPosition),
              onPanStart: (_) => onDragStart(false),
              onPanUpdate: onDragUpdate,
              onPanEnd: (_) => onDragEnd(),
              onPanCancel: onDragEnd,
            ),
          ),
        ),

        ModuleHost(
          spec: module,
          engine: engine,
          clock: clock,
          calibration: calibration,
          selected: selected,
          onMenu: () => onMenu(_centreOf(context)),
        ),

        Positioned(
          right: 0,
          bottom: 0,
          width: gripSize,
          height: gripSize,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeDownRight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              dragStartBehavior: DragStartBehavior.down,
              onPanStart: (_) => onDragStart(true),
              onPanUpdate: onDragUpdate,
              onPanEnd: (_) => onDragEnd(),
              onPanCancel: onDragEnd,
              child: CustomPaint(
                painter: _GripPainter(
                  selected ? colors.accent : colors.textFaint,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Where to anchor the menu opened from the frame's own button.
  Offset _centreOf(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return Offset.zero;
    return box.localToGlobal(Offset(box.size.width, 0));
  }
}

/// Two ticks in the corner. Enough to say "grab here" without drawing a widget
/// that competes with the meter for attention.
class _GripPainter extends MeterPainter {
  _GripPainter(this.color)
    : _stroke = Paint()
        ..color = color
        ..strokeWidth = BelStroke.hairline
        ..isAntiAlias = false;

  final Color color;
  final Paint _stroke;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 1; i <= 2; i++) {
      final inset = i * (size.width / 3);
      canvas.drawLine(
        Offset(size.width - inset, size.height),
        Offset(size.width, size.height - inset),
        _stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_GripPainter oldDelegate) => oldDelegate.color != color;
}

/// Where a dragged module would land.
@immutable
class _Preview {
  const _Preview({required this.rect, required this.valid});

  final GridRect rect;

  /// False when the target overlaps another module. Drawn in [BelColors.over]
  /// and refused on release.
  final bool valid;

  @override
  bool operator ==(Object other) =>
      other is _Preview && other.rect == rect && other.valid == valid;

  @override
  int get hashCode => Object.hash(rect, valid);
}

class _DragSession {
  _DragSession({
    required this.id,
    required this.kind,
    required this.origin,
    required this.resize,
    required this.duplicate,
  });

  final String id;
  final ModuleKind kind;

  /// Alt was held when the drag began: drop a copy and leave the original.
  final bool duplicate;

  /// Where the module was when the pointer went down. Every target is computed
  /// from this plus the total travel, never from the previous target —
  /// accumulating rounded steps would drift away from the pointer.
  final GridRect origin;
  final bool resize;

  Offset travelled = Offset.zero;
}

class _PreviewPainter extends MeterPainter {
  _PreviewPainter({
    required this.preview,
    required this.geometry,
    required this.colors,
  }) : super(repaint: preview) {
    _guide = Paint()
      ..color = colors.hairline
      ..strokeWidth = BelStroke.hairline
      ..isAntiAlias = false;
  }

  final ValueListenable<_Preview?> preview;
  final GridGeometry geometry;
  final BelColors colors;

  late final Paint _guide;

  @override
  void paint(Canvas canvas, Size size) {
    final target = preview.value;
    if (target == null) return;

    // The grid appears only while something is being dragged. Permanently
    // ruled lines behind twelve meters is graph paper, and it competes with
    // the measurements; during a drag it is the thing the eye needs.
    for (var column = 1; column < kGridColumns; column++) {
      final x = column * geometry.columnStride - geometry.gap / 2;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), _guide);
    }
    for (var row = 1; row < kGridRows; row++) {
      final y = row * geometry.rowStride - geometry.gap / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), _guide);
    }

    final colour = target.valid ? colors.accent : colors.over;
    final box = RRect.fromRectAndRadius(
      geometry.rectFor(target.rect),
      BelRadius.sm,
    );

    canvas.drawRRect(box, Paint()..color = colour.withValues(alpha: 0.10));
    canvas.drawRRect(
      box,
      Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeWidth = BelStroke.emphasis,
    );
  }

  @override
  bool shouldRepaint(_PreviewPainter oldDelegate) =>
      oldDelegate.geometry.size != geometry.size ||
      oldDelegate.colors != colors;
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'EMPTY TAB',
            style: BelType.label.copyWith(color: colors.textFaint),
          ),
          const SizedBox(height: Space.sm),
          Text(
            'Right-click anywhere to add a module.',
            style: BelType.caption.copyWith(color: colors.textFaint),
          ),
        ],
      ),
    );
  }
}

/// A refusal the user needs to see.
///
/// "Add a spectrum analyser" with no room left has to say something. Doing
/// nothing is indistinguishable from a click that missed, and the user's next
/// move is to click again.
class _Toast extends StatelessWidget {
  const _Toast({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        margin: const EdgeInsets.only(bottom: Space.md),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: Space.sm,
        ),
        decoration: BoxDecoration(
          color: colors.panelRaised,
          borderRadius: BelRadius.allSm,
          border: Border.all(color: colors.warn, width: BelStroke.hairline),
        ),
        child: Text(
          message,
          style: BelType.caption.copyWith(color: colors.textPrimary),
        ),
      ),
    );
  }
}
