// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../clock/meter_clock.dart';
import '../data/providers.dart';
import 'canvas_notice.dart';
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
/// rate — inflating fourteen modules, fourteen painters and fourteen cached
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
/// That constraint is also why a drag *dims* the rest of the canvas instead of
/// blurring it: the whole effect is three more draws in the one painter that
/// was already repainting, where a `BackdropFilter` would be a widget — a
/// rebuild on both edges of the gesture — and a full-screen Gaussian re-run
/// every frame over meters that are still publishing. See [_PreviewPainter].
///
/// ---------------------------------------------------------------------------
/// Why the drag affordances sit *behind* the module
///
/// Each module is a small stack of six: a full-size selection catcher, a
/// touch-only drag band, a drag strip over the title bar, the module itself, a
/// touch-only resize target and a resize grip at the corner. The first three
/// are underneath the module, which is what gives the frame's own menu button
/// priority without any gesture-arena arbitration — a hit test that reaches the
/// menu button never gets as far as the strip.
///
/// That only works because meter painters do not absorb pointer events. See
/// [MeterPainter]: Flutter's default is that a `CustomPaint` swallows them,
/// which would make the entire body of every module dead to the mouse.
///
/// The two touch layers are the same rule read the other way round. Each sits
/// directly *beneath* the affordance it enlarges and is bigger than it, and
/// `RenderStack.hitTestChildren` walks back to front and stops at the first
/// child that returns true — so the opaque layer above masks the part of the
/// touch layer underneath it, and only the margin it adds is ever reached. That
/// is what keeps one pan recogniser in the arena rather than two identical ones
/// racing to accept it. Both are `HitTestBehavior.translucent`, so a pointer
/// they do not admit carries on down to the selection catcher and a mouse click
/// in the added margin still selects the module exactly as it always did. See
/// [kTouchDragDevices] for which kinds are admitted, and why they are the only
/// ones.
///
/// ---------------------------------------------------------------------------
/// The keyboard is not here
///
/// The canvas keeps a `Focus`, because a key event needs a focused node to
/// start from. It no longer keeps the bindings: they moved to
/// `lib/src/app/shortcuts.dart` in Phase 8 and now wrap the whole workspace,
/// because a table installed here stopped working the moment focus left the
/// canvas — opening the source picker was enough to silently disable undo.
class GridCanvas extends ConsumerStatefulWidget {
  const GridCanvas({required this.engine, required this.clock, super.key});

  final MeterSource engine;
  final MeterClock clock;

  @override
  ConsumerState<GridCanvas> createState() => _GridCanvasState();
}

class _GridCanvasState extends ConsumerState<GridCanvas> {
  /// Where the module being dragged would land. Null when nothing is dragging.
  final ValueNotifier<_Preview?> _preview = ValueNotifier<_Preview?>(null);

  _DragSession? _session;

  /// Side of the square resize grip at a module's bottom-right corner.
  static const double _gripSize = Space.md;

  /// The same grip for a finger. Nothing is drawn at this size — the ticks stay
  /// inside [_gripSize] — and only [kTouchDragDevices] may use it.
  static const double _gripTouchSize = Space.xl;

  /// The title bar's drag handle for a finger. The painted bar stays
  /// [ModuleFrame.titleBarHeight]; this is only how far down a drag is still
  /// acknowledged.
  static const double _handleTouchHeight = Space.lg + Space.md;

  @override
  void dispose() {
    _preview.dispose();
    super.dispose();
  }

  WorkspaceController get _controller => ref.read(workspaceProvider.notifier);

  /// Refusals that would otherwise be invisible — "no room for that".
  ///
  /// The canvas is one of two things that can refuse; the keyboard is the
  /// other, and it lives above this widget. See [canvasNoticeProvider].
  void _report(String message) =>
      ref.read(canvasNoticeProvider.notifier).say(message);

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
    _preview.value = _Preview(
      rect: module.rect,
      source: module.rect,
      valid: true,
    );
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
      //
      // The upper bound is taken as at least the lower one. A stored layout can
      // put a module narrower than its kind's minimum hard against the right
      // edge — that is why `ModuleHost` has a `ModuleTooSmall` placeholder at
      // all — and for such a module the room remaining was *less* than the
      // minimum, so the two bounds crossed and `clamp` threw ArgumentError out
      // of a pointer callback. Not an assert: it throws in release too.
      // `ModuleSpec.fromJson` now normalises rects on the way in, which should
      // make this unreachable; the max stays because a crash on a drag is a bad
      // way to find out it was not.
      final maxColumns = math.max(
        session.kind.minColumns,
        kGridColumns - origin.column,
      );
      final maxRows = math.max(session.kind.minRows, kGridRows - origin.row);
      target = origin.copyWith(
        columns: (origin.columns + columns).clamp(
          session.kind.minColumns,
          maxColumns,
        ),
        rows: (origin.rows + rows).clamp(session.kind.minRows, maxRows),
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
      source: origin,
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
    final colors = OaaTheme.of(context);
    _controller.select(module.id);

    // What this module *has*, above what can be done to any module. A module is
    // exactly one kind, so this holds at most one row today — it is a list
    // because the group is what the rule below divides, and a second setting on
    // some future module has to land inside it rather than beside it.
    //
    // **Drawn in `textPrimary`, like every other row.** These were `textMuted`
    // to mark them as a different sort of thing, and muted text in a menu does
    // not read as "a setting" — it reads as an entry that cannot be chosen,
    // sitting directly above a `Duplicate` at full brightness. The grouping is
    // a rule now, which says the same thing without making a live control look
    // dead.
    final settings = <PopupMenuEntry<_ModuleAction>>[
      if (module.kind == ModuleKind.numberBox)
        oaaMenuItem(
          context,
          _ModuleAction.metric,
          'Metric: ${module.metric.label}',
        ),
      // Named "Response" rather than a refresh rate, because that is what it
      // is: the analyser draws every frame the engine publishes at every
      // setting, and what changes is how long the drawn level takes to follow
      // one. See `SpectrumResponse`.
      // Which signal the bands are measured on, and it is the first row of
      // both frequency modules that have one: what is measured comes before
      // how it is drawn. The same row in the same words on the spectrogram
      // below, because the two read the same bands. See `SpectrumSource`.
      if (module.kind == ModuleKind.spectrumAnalyzer) ...[
        oaaMenuItem(
          context,
          _ModuleAction.source,
          'Source: ${module.spectrumSource.label}',
        ),
        oaaMenuItem(
          context,
          _ModuleAction.response,
          'Response: ${module.spectrumResponse.label}',
        ),
        // How far the drawn curve is rotated. See `SpectrumTilt` — it is a
        // view of the same measurement, and the module says which one is on.
        oaaMenuItem(
          context,
          _ModuleAction.tilt,
          'Tilt: ${module.spectrumTilt.label}',
        ),
      ],
      // Named "Smoothing" rather than a response or a time constant, because
      // unlike the analyser's this is not a ballistic: it is a centred window
      // over history that has already been measured, and it moves nothing in
      // time. See `HistogramSmoothing`.
      if (module.kind == ModuleKind.histogram)
        oaaMenuItem(
          context,
          _ModuleAction.smoothing,
          'Smoothing: ${module.histogramSmoothing.label}',
        ),
      // How much of the loudness axis the picture is given, which is a
      // question only this module has: it draws a distribution that occupies a
      // fifth of the published range, against an axis that publishes all of it.
      // See `DistributionScale`.
      if (module.kind == ModuleKind.loudnessDistribution)
        oaaMenuItem(
          context,
          _ModuleAction.distributionScale,
          'Scale: ${module.distributionScale.label}',
        ),
      // The spectrogram's only setting, and the one row the oscilloscope shares
      // with it: which colours a level is drawn in. Both modules answer with a
      // hue rather than with a length, so both have the same choice to make and
      // it is spelled the same way in both menus. See `ColorRamp`.
      if (module.kind == ModuleKind.spectrogram) ...[
        oaaMenuItem(
          context,
          _ModuleAction.source,
          'Source: ${module.spectrumSource.label}',
        ),
        oaaMenuItem(
          context,
          _ModuleAction.colorRamp,
          'Colour: ${module.colorRamp.label}',
        ),
      ],
      // The one control the oscilloscope has, and it is two settings in one:
      // it sets how much time the width holds *and*, by doing so, whether
      // the display is triggered or rolls. See `ScopeTimeBase`.
      if (module.kind == ModuleKind.oscilloscope) ...[
        // What the window is locked to, and then the width in whichever unit
        // that answer makes meaningful. Both width rows are never shown: a
        // millisecond width means nothing to a bar-locked display and a note
        // value means nothing without a tempo, and the width is asked for
        // either way — one setting, spelled in the unit that answers.
        oaaMenuItem(
          context,
          _ModuleAction.sync,
          'Sync: ${module.scopeSync.label}',
        ),
        if (module.scopeSync == ScopeSync.free)
          oaaMenuItem(
            context,
            _ModuleAction.timeBase,
            'Time base: ${module.scopeTimeBase.label}',
          ),
        if (module.scopeSync == ScopeSync.tempo)
          oaaMenuItem(
            context,
            _ModuleAction.division,
            'Division: ${module.scopeDivision.label}',
          ),
        // What starts the window, which only a free-running one has a choice
        // about — a tempo-locked window is already placed by the bar line. And
        // what the division's width is multiplied by, which only a tempo-locked
        // one has a choice about, for the mirror of that reason: there is no
        // triplet of a millisecond. So each is **disabled rather than dropped**,
        // and in the same row of the menu either way: a row that vanishes is a
        // row somebody hunts for, and the setting they would suspect is the one
        // that disappeared rather than the sync above it. The *threshold* the
        // trigger fires at is not a row at all — it is a slider on the module,
        // because it is chosen by watching the picture. See `ScopeTrigger` and
        // `ScopeGrid`.
        oaaMenuItem(
          context,
          _ModuleAction.trigger,
          'Trigger: ${module.scopeTrigger.label}',
          enabled: module.scopeSync == ScopeSync.free,
        ),
        oaaMenuItem(
          context,
          _ModuleAction.grid,
          'Grid: ${module.scopeGrid.label}',
          enabled: module.scopeSync == ScopeSync.tempo,
        ),
        // How the picture is arranged rather than what is in it, so it sits
        // under the settings that decide the window. See `ScopeStereo`.
        //
        // **`Height` used to be the row below this one and is now a slider on
        // the module itself.** It is a number over thirty decibels of range,
        // and a menu of four multipliers meant the setting that fitted the
        // material was usually between two rows — and that every step of
        // finding it closed a menu over the waveform it was being judged
        // against. See `ScopeZoom`.
        oaaMenuItem(
          context,
          _ModuleAction.stereo,
          'Stereo: ${module.scopeStereo.label}',
        ),
        // Last, under the arrangement, because it changes neither what is
        // measured nor where any of it is drawn — only what colour it is drawn
        // in. The same row the spectrogram has, in the same words.
        oaaMenuItem(
          context,
          _ModuleAction.colorRamp,
          'Colour: ${module.colorRamp.label}',
        ),
      ],
    ];

    final action = await showMenu<_ModuleAction>(
      context: context,
      color: colors.panelRaised,
      position: menuPositionAt(context, globalPosition),
      items: [
        ...settings,
        // Only where there is something above it to divide. Eleven of the
        // fourteen kinds have no setting, and a menu that opens with a rule
        // across its top edge looks like one whose first item failed to build.
        if (settings.isNotEmpty) const PopupMenuDivider(),
        oaaMenuItem(context, _ModuleAction.duplicate, 'Duplicate'),
        oaaMenuItem(
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
      case _ModuleAction.source:
        await _showSourceMenu(globalPosition, module);
      case _ModuleAction.response:
        await _showResponseMenu(globalPosition, module);
      case _ModuleAction.tilt:
        await _showTiltMenu(globalPosition, module);
      case _ModuleAction.smoothing:
        await _showSmoothingMenu(globalPosition, module);
      case _ModuleAction.distributionScale:
        await _showDistributionScaleMenu(globalPosition, module);
      case _ModuleAction.timeBase:
        await _showTimeBaseMenu(globalPosition, module);
      case _ModuleAction.sync:
        await _showSyncMenu(globalPosition, module);
      case _ModuleAction.division:
        await _showDivisionMenu(globalPosition, module);
      case _ModuleAction.grid:
        await _showGridMenu(globalPosition, module);
      case _ModuleAction.stereo:
        await _showStereoMenu(globalPosition, module);
      case _ModuleAction.trigger:
        await _showTriggerMenu(globalPosition, module);
      case _ModuleAction.colorRamp:
        await _showColorRampMenu(globalPosition, module);
      case _ModuleAction.duplicate:
        if (!_controller.duplicateModule(module.id)) {
          _report('No room on this tab for another ${module.kind.label}.');
        }
      case _ModuleAction.delete:
        _controller.removeModule(module.id);
    }
  }

  Future<void> _showMetricMenu(Offset globalPosition, ModuleSpec module) async {
    final colors = OaaTheme.of(context);
    final metric = await showMenu<Metric>(
      context: context,
      color: colors.panelRaised,
      position: menuPositionAt(context, globalPosition),
      items: [
        for (final metric in Metric.values)
          oaaMenuItem(
            context,
            metric,
            metric.label,
            selected: metric == module.metric,
          ),
      ],
    );

    if (metric == null || !mounted) return;
    _controller.setModuleOption(module.id, 'metric', metric.id);
  }

  Future<void> _showResponseMenu(
    Offset globalPosition,
    ModuleSpec module,
  ) async {
    final colors = OaaTheme.of(context);
    final current = module.spectrumResponse;
    final response = await showMenu<SpectrumResponse>(
      context: context,
      color: colors.panelRaised,
      position: menuPositionAt(context, globalPosition),
      items: [
        for (final response in SpectrumResponse.values)
          oaaMenuItem(
            context,
            response,
            response.label,
            selected: response == current,
          ),
      ],
    );

    if (response == null || !mounted) return;
    _controller.setModuleOption(module.id, 'response', response.id);
  }

  Future<void> _showTiltMenu(Offset globalPosition, ModuleSpec module) async {
    final colors = OaaTheme.of(context);
    final current = module.spectrumTilt;
    final tilt = await showMenu<SpectrumTilt>(
      context: context,
      color: colors.panelRaised,
      position: menuPositionAt(context, globalPosition),
      items: [
        for (final tilt in SpectrumTilt.values)
          oaaMenuItem(context, tilt, tilt.label, selected: tilt == current),
      ],
    );

    if (tilt == null || !mounted) return;
    _controller.setModuleOption(module.id, 'tilt', tilt.id);
  }

  Future<void> _showSmoothingMenu(
    Offset globalPosition,
    ModuleSpec module,
  ) async {
    final colors = OaaTheme.of(context);
    final current = module.histogramSmoothing;
    final smoothing = await showMenu<HistogramSmoothing>(
      context: context,
      color: colors.panelRaised,
      position: menuPositionAt(context, globalPosition),
      items: [
        for (final smoothing in HistogramSmoothing.values)
          oaaMenuItem(
            context,
            smoothing,
            smoothing.label,
            selected: smoothing == current,
          ),
      ],
    );

    if (smoothing == null || !mounted) return;
    _controller.setModuleOption(module.id, 'smoothing', smoothing.id);
  }

  Future<void> _showDistributionScaleMenu(
    Offset globalPosition,
    ModuleSpec module,
  ) async {
    final colors = OaaTheme.of(context);
    final current = module.distributionScale;
    final scale = await showMenu<DistributionScale>(
      context: context,
      color: colors.panelRaised,
      position: menuPositionAt(context, globalPosition),
      items: [
        for (final scale in DistributionScale.values)
          oaaMenuItem(context, scale, scale.label, selected: scale == current),
      ],
    );

    if (scale == null || !mounted) return;
    _controller.setModuleOption(module.id, 'scale', scale.id);
  }

  Future<void> _showTimeBaseMenu(
    Offset globalPosition,
    ModuleSpec module,
  ) async {
    final colors = OaaTheme.of(context);
    final current = module.scopeTimeBase;
    final base = await showMenu<ScopeTimeBase>(
      context: context,
      color: colors.panelRaised,
      position: menuPositionAt(context, globalPosition),
      items: [
        for (final base in ScopeTimeBase.values)
          oaaMenuItem(context, base, base.label, selected: base == current),
      ],
    );

    if (base == null || !mounted) return;
    _controller.setModuleOption(module.id, 'timeBase', base.id);
  }

  Future<void> _showSyncMenu(Offset globalPosition, ModuleSpec module) async {
    final colors = OaaTheme.of(context);
    final current = module.scopeSync;
    final sync = await showMenu<ScopeSync>(
      context: context,
      color: colors.panelRaised,
      position: menuPositionAt(context, globalPosition),
      items: [
        for (final sync in ScopeSync.values)
          oaaMenuItem(context, sync, sync.label, selected: sync == current),
      ],
    );

    if (sync == null || !mounted) return;
    _controller.setModuleOption(module.id, 'sync', sync.id);
  }

  Future<void> _showDivisionMenu(
    Offset globalPosition,
    ModuleSpec module,
  ) async {
    final colors = OaaTheme.of(context);
    final current = module.scopeDivision;
    final division = await showMenu<ScopeDivision>(
      context: context,
      color: colors.panelRaised,
      position: menuPositionAt(context, globalPosition),
      items: [
        for (final division in ScopeDivision.values)
          oaaMenuItem(
            context,
            division,
            division.label,
            selected: division == current,
          ),
      ],
    );

    if (division == null || !mounted) return;
    _controller.setModuleOption(module.id, 'division', division.id);
  }

  Future<void> _showGridMenu(Offset globalPosition, ModuleSpec module) async {
    final colors = OaaTheme.of(context);
    final current = module.scopeGrid;
    final grid = await showMenu<ScopeGrid>(
      context: context,
      color: colors.panelRaised,
      position: menuPositionAt(context, globalPosition),
      items: [
        for (final grid in ScopeGrid.values)
          oaaMenuItem(context, grid, grid.label, selected: grid == current),
      ],
    );

    if (grid == null || !mounted) return;
    _controller.setModuleOption(module.id, 'grid', grid.id);
  }

  Future<void> _showStereoMenu(Offset globalPosition, ModuleSpec module) async {
    final colors = OaaTheme.of(context);
    final current = module.scopeStereo;
    final mode = await showMenu<ScopeStereo>(
      context: context,
      color: colors.panelRaised,
      position: menuPositionAt(context, globalPosition),
      items: [
        for (final mode in ScopeStereo.values)
          oaaMenuItem(context, mode, mode.label, selected: mode == current),
      ],
    );

    if (mode == null || !mounted) return;
    _controller.setModuleOption(module.id, 'stereo', mode.id);
  }

  Future<void> _showTriggerMenu(
    Offset globalPosition,
    ModuleSpec module,
  ) async {
    final colors = OaaTheme.of(context);
    final current = module.scopeTrigger;
    final trigger = await showMenu<ScopeTrigger>(
      context: context,
      color: colors.panelRaised,
      position: menuPositionAt(context, globalPosition),
      items: [
        for (final trigger in ScopeTrigger.values)
          oaaMenuItem(
            context,
            trigger,
            trigger.label,
            selected: trigger == current,
          ),
      ],
    );

    if (trigger == null || !mounted) return;
    _controller.setModuleOption(module.id, 'trigger', trigger.id);
  }

  Future<void> _showSourceMenu(Offset globalPosition, ModuleSpec module) async {
    final colors = OaaTheme.of(context);
    final current = module.spectrumSource;
    final source = await showMenu<SpectrumSource>(
      context: context,
      color: colors.panelRaised,
      position: menuPositionAt(context, globalPosition),
      items: [
        for (final source in SpectrumSource.values)
          oaaMenuItem(
            context,
            source,
            source.label,
            selected: source == current,
          ),
      ],
    );

    if (source == null || !mounted) return;
    _controller.setModuleOption(module.id, 'source', source.id);
  }

  Future<void> _showColorRampMenu(
    Offset globalPosition,
    ModuleSpec module,
  ) async {
    final colors = OaaTheme.of(context);
    final current = module.colorRamp;
    final ramp = await showMenu<ColorRamp>(
      context: context,
      color: colors.panelRaised,
      position: menuPositionAt(context, globalPosition),
      items: [
        for (final ramp in ColorRamp.values)
          oaaMenuItem(context, ramp, ramp.label, selected: ramp == current),
      ],
    );

    if (ramp == null || !mounted) return;
    _controller.setModuleOption(module.id, 'ramp', ramp.id);
  }

  // --- Build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    final workspace = ref.watch(workspaceProvider);
    final calibration = ref.watch(calibrationProvider);
    final tab = workspace.tab;

    // The `Focus` stays and the bindings do not — see the class comment. It is
    // `autofocus` so that a launch straight into the canvas has somewhere for a
    // key event to begin without the user clicking first.
    return Focus(
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
                // right click and long press add a module where the pointer
                // is. A single left click deliberately does not open a menu —
                // every stray click on the background would.
                //
                // **Long press rather than the double click this used to
                // be.** A `DoubleTapGestureRecognizer` holds the gesture arena
                // from the first tap until `kDoubleTapTimeout` expires, and a
                // held arena is never swept — so clearing the selection took
                // 300 ms and read as a canvas that was thinking about it. A
                // long press rejects as soon as the pointer lifts, and reaches
                // the tablets that have no second mouse button either.
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _controller.select(null),
                    onLongPressStart: (details) => _showAddMenu(
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
                  const Positioned.fill(child: IgnorePointer(child: _Empty())),

                for (final module in tab.modules)
                  _slotFor(
                    module,
                    geometry,
                    calibration,
                    selected: module.id == workspace.selectedModuleId,
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

                // The refusal line. A `Consumer` so that the message can
                // arrive from the keyboard as well as from a dropped drag,
                // and so that saying it rebuilds this corner rather than the
                // fourteen meters above it.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Consumer(
                      builder: (context, ref, _) {
                        final message = ref.watch(canvasNoticeProvider);
                        return message == null
                            ? const SizedBox.shrink()
                            : _Toast(message: message);
                      },
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// One module's slot, with its touch targets sized to the room it has.
  ///
  /// The clamping happens here rather than inside [_ModuleSlot] because it needs
  /// the module's pixel rect, and the slot only learns its own size at layout.
  /// **Neither target may grow into the title bar.** The touch grip sits above
  /// [ModuleHost] in the stack, so on a short module an unclamped square would
  /// reach the frame's menu button and the move strip and take both; the floor
  /// is the size each affordance already had, so a module too small for the
  /// larger target simply keeps today's.
  ///
  /// `math.max` and `math.min` rather than `clamp`, deliberately: `clamp` throws
  /// `ArgumentError` when the bounds cross, and that is a crash out of a build
  /// on a small window. [_updateDrag] carries the same note for the same reason.
  Widget _slotFor(
    ModuleSpec module,
    GridGeometry geometry,
    Calibration calibration, {
    required bool selected,
  }) {
    final rect = geometry.rectFor(module.rect);
    final gripTouch = math.max(
      _gripSize,
      math.min(
        _gripTouchSize,
        math.min(rect.width, rect.height - ModuleFrame.titleBarHeight),
      ),
    );
    final handleTouch = math.max(
      ModuleFrame.titleBarHeight,
      math.min(_handleTouchHeight, rect.height - gripTouch),
    );

    return Positioned.fromRect(
      rect: rect,
      // Keyed by module id so that moving one preserves its State — and with
      // it the laid-out paragraphs its painter has cached. Without the key,
      // Flutter matches children by position in the list and a move throws
      // that cache away.
      key: ValueKey<String>(module.id),
      child: _ModuleSlot(
        module: module,
        engine: widget.engine,
        clock: widget.clock,
        calibration: calibration,
        selected: selected,
        gripSize: _gripSize,
        gripTouchSize: gripTouch,
        handleTouchHeight: handleTouch,
        onSelect: () => _controller.select(module.id),
        onMenu: (position) => _showModuleMenu(position, module),
        onOption: (key, value) =>
            _controller.setModuleOption(module.id, key, value),
        onDragStart: (resize) => _beginDrag(module, resize: resize),
        onDragUpdate: (details) => _updateDrag(details, geometry),
        onDragEnd: _endDrag,
      ),
    );
  }

  GridRect _rectAt(GridGeometry geometry, Offset local) {
    final (column, row) = geometry.cellAt(local);
    return GridRect(column: column, row: row, columns: 1, rows: 1);
  }
}

enum _ModuleAction {
  metric,
  source,
  response,
  tilt,
  smoothing,
  distributionScale,
  timeBase,
  trigger,
  sync,
  division,
  grid,
  stereo,
  colorRamp,

  duplicate,
  delete,
}

/// One module and the five transparent layers that make it manipulable.
class _ModuleSlot extends StatelessWidget {
  const _ModuleSlot({
    required this.module,
    required this.engine,
    required this.clock,
    required this.calibration,
    required this.selected,
    required this.gripSize,
    required this.gripTouchSize,
    required this.handleTouchHeight,
    required this.onSelect,
    required this.onMenu,
    required this.onOption,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final ModuleSpec module;
  final MeterSource engine;
  final MeterClock clock;
  final Calibration calibration;
  final bool selected;
  final double gripSize;

  /// The grip's target for a finger, already clamped out of the title bar by
  /// `_GridCanvasState._slotFor`. Equal to [gripSize] when there is no room.
  final double gripTouchSize;

  /// How far down a finger may still start a move, likewise clamped. Equal to
  /// [ModuleFrame.titleBarHeight] when there is no room.
  final double handleTouchHeight;
  final VoidCallback onSelect;
  final void Function(Offset globalPosition) onMenu;

  /// A setting the module changes itself, from a control of its own. The
  /// oscilloscope's height and trigger level are the only two — see
  /// `ModuleHost.onOption`.
  final void Function(String key, Object? value) onOption;
  final void Function(bool resize) onDragStart;
  final void Function(DragUpdateDetails details) onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        // Beneath everything: select and context-menu anywhere on the module.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onSelect,
          onSecondaryTapUp: (details) => onMenu(details.globalPosition),
        ),

        // The same handle, for a finger. Taller than the bar it enlarges and
        // masked by the opaque strip above, so it is reached only in the margin
        // it adds below the bar. Translucent, so that a mouse press here starts
        // nothing — `supportedDevices` will not admit one — and falls through to
        // the selection catcher beneath, which selects the module as it always
        // has. See the header, and [kTouchDragDevices].
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: handleTouchHeight,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            dragStartBehavior: DragStartBehavior.down,
            supportedDevices: kTouchDragDevices,
            onPanStart: (_) => onDragStart(false),
            onPanUpdate: onDragUpdate,
            onPanEnd: (_) => onDragEnd(),
            onPanCancel: onDragEnd,
          ),
        ),

        // The title bar is the drag handle. Dragging by the body is tempting
        // and wrong: a histogram that can be scrubbed and a spectrum with a
        // cursor both need the body, and a canvas that claims it now is a
        // canvas that has to be unpicked in Phase 3.
        //
        // A finger is the one exception, and it is a concession rather than a
        // reversal — the layer above, which reaches [handleTouchHeight] rather
        // than these twenty-four pixels. A finger has no cursor to tell it what
        // it is over and covers the whole bar, and the target cannot grow
        // outward instead: the slot is a `Positioned.fromRect`, and a
        // `RenderBox` rejects hits outside its own size, so a box overhanging
        // the gutter would paint there and never be touched. A module that
        // later wants its body scrubbed takes those pixels back by shrinking
        // that layer, not by moving this one.
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
              // Or a two-finger gesture over the title bar drags the module —
              // including the one macOS sends as a right click, which put the
              // placement grid on screen for as long as the menu took to open.
              // See [kDragDevices].
              supportedDevices: kDragDevices,
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
          onOption: onOption,
        ),

        // The corner grip's target for a finger, on the same principle as the
        // band over the title bar and masked the same way by the grip below it.
        // Sized by `_GridCanvasState._slotFor` rather than here: this layer is
        // above [ModuleHost], so on a short module an unclamped square would
        // reach up and take the frame's menu button.
        Positioned(
          right: 0,
          bottom: 0,
          width: gripTouchSize,
          height: gripTouchSize,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            dragStartBehavior: DragStartBehavior.down,
            supportedDevices: kTouchDragDevices,
            onPanStart: (_) => onDragStart(true),
            onPanUpdate: onDragUpdate,
            onPanEnd: (_) => onDragEnd(),
            onPanCancel: onDragEnd,
          ),
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
              // Or a two-finger gesture that starts on the grip resizes the
              // module. See [kDragDevices].
              supportedDevices: kDragDevices,
              // Without this the grip is the one place on a module where a tap
              // does nothing at all: it is opaque, so it takes the hit from the
              // selection catcher, and it had nothing of its own to spend it
              // on. Barely noticeable at sixteen pixels; plainly wrong with a
              // finger's target around it, where tapping two millimetres away
              // selects the module and tapping the ticks does not.
              onTap: onSelect,
              onPanStart: (_) => onDragStart(true),
              onPanUpdate: onDragUpdate,
              onPanEnd: (_) => onDragEnd(),
              onPanCancel: onDragEnd,
              child: CustomPaint(
                painter: _GripPainter(
                  selected ? colors.textPrimary : colors.textFaint,
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
        ..strokeWidth = OaaStroke.hairline
        ..isAntiAlias = false;

  /// Distance from the slot's edge to the corner the ticks are drawn around.
  ///
  /// The grip sits in the same square as the frame's bottom-right corner, and
  /// that corner is a rounded rectangle: a tick that ran to the slot's edge
  /// ended *on* the border — half a hairline of it outside the panel, over the
  /// gutter between modules — and at [OaaStroke.emphasis], while the module is
  /// selected, it crossed the selection outline outright. [Space.xs] is the
  /// frame's corner radius, so insetting by it keeps both ticks clear of the
  /// arc as well as of the widest border the frame draws.
  static const double _clearance = Space.xs;

  final Color color;
  final Paint _stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final right = size.width - _clearance;
    final bottom = size.height - _clearance;
    final side = size.width - _clearance;

    for (var i = 1; i <= 2; i++) {
      final inset = i * (side / 3);
      canvas.drawLine(
        Offset(right - inset, bottom),
        Offset(right, bottom - inset),
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
  const _Preview({
    required this.rect,
    required this.source,
    required this.valid,
  });

  final GridRect rect;

  /// Where the module being dragged still is, since a drag moves nothing until
  /// it is released. It is the one thing on the canvas the scrim does not
  /// cover: you have to be able to see what you are carrying.
  ///
  /// Constant for the whole gesture, so it costs no repaints — it is carried
  /// here rather than read off the session because the painter is given the
  /// notifier and nothing else.
  final GridRect source;

  /// False when the target overlaps another module. Drawn in [OaaColors.over]
  /// and refused on release.
  final bool valid;

  @override
  bool operator ==(Object other) =>
      other is _Preview &&
      other.rect == rect &&
      other.source == source &&
      other.valid == valid;

  @override
  int get hashCode => Object.hash(rect, source, valid);
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
      ..strokeWidth = OaaStroke.hairline
      ..isAntiAlias = false;
    _edge = Paint()
      ..color = colors.hairlineStrong
      ..style = PaintingStyle.stroke
      ..strokeWidth = OaaStroke.hairline;
    _scrim = Paint()..color = colors.background.withValues(alpha: _scrimAlpha);
  }

  /// How much of the canvas colour is washed over the modules that are not
  /// being carried.
  ///
  /// Enough that a dozen live meters stop competing with the grid ruled on top
  /// of them, and not so much that the canvas goes blank — the layout being
  /// dropped into is the thing the user is aiming at, so the other modules have
  /// to stay legible as shapes. At this value a reading recedes to about 3:1
  /// against the panel it sits on, from 15:1.
  ///
  /// A blur says the same thing and costs far more. `BackdropFilter` re-runs a
  /// full-screen Gaussian every frame, and the meters underneath are still
  /// publishing at 47 Hz throughout the drag — it is the one effect on this
  /// canvas whose cost is proportional to how *live* the display is, and it
  /// would land on the raster thread at the moment the user is watching the
  /// screen most closely. It would also need a widget, and so a rebuild of the
  /// canvas on both edges of the gesture; this is a paint.
  static const double _scrimAlpha = 0.62;

  final ValueListenable<_Preview?> preview;
  final GridGeometry geometry;
  final OaaColors colors;

  late final Paint _guide;
  late final Paint _edge;
  late final Paint _scrim;

  @override
  void paint(Canvas canvas, Size size) {
    final target = preview.value;
    if (target == null) return;

    // The border sits one gutter *outside* the grid rather than on it. The grid
    // has no outer margin — cell 0 starts at pixel 0 — so a border on the
    // bounds would land against the edge modules' own borders and read as one
    // doubled line. A gutter out, it stands off a module by exactly what its
    // neighbours do, and there is still half of the canvas padding left between
    // it and the window. The radius is the module's, so the sheet the modules
    // are arranged on is shaped like the things arranged on it.
    final bounds = (Offset.zero & size).inflate(geometry.gap / 2);
    final border = RRect.fromRectAndRadius(bounds, OaaRadius.sm);

    // The sheet the modules are arranged on, with the one being carried punched
    // out of it: everything else is washed toward the canvas colour, so the
    // grid can be read over the top of a dozen live meters and the eye lands on
    // the ghost rather than on whatever the meters happen to be doing.
    // Even-odd rather than a saved layer or two clips — one path, drawn once
    // and then reused as the clip for the ruling.
    final sheet = Path()
      ..fillType = PathFillType.evenOdd
      ..addRRect(border)
      ..addRRect(
        RRect.fromRectAndRadius(geometry.rectFor(target.source), OaaRadius.sm),
      );

    canvas.drawPath(sheet, _scrim);

    // The grid appears only while something is being dragged. Permanently
    // ruled lines behind fourteen meters is graph paper, and it competes with
    // the measurements; during a drag it is the thing the eye needs.
    //
    // Clipped to the sheet, so the ruling stops at the module being carried
    // instead of running through it. The module is the one thing here that is
    // *not* on the sheet — it has been picked up — and lines drawn across it
    // read as the grid being in front of it.
    canvas.save();
    canvas.clipPath(sheet);
    for (var column = 1; column < kGridColumns; column++) {
      final x = column * geometry.columnStride - geometry.gap / 2;
      canvas.drawLine(Offset(x, bounds.top), Offset(x, bounds.bottom), _guide);
    }
    for (var row = 1; row < kGridRows; row++) {
      final y = row * geometry.rowStride - geometry.gap / 2;
      canvas.drawLine(Offset(bounds.left, y), Offset(bounds.right, y), _guide);
    }
    canvas.restore();

    // Last, so it covers the ends of the ruling, and in the border colour that
    // is meant to be seen rather than the hairline the cells are drawn in: it
    // is the edge of what can be placed, which is the one thing on this overlay
    // that is not a suggestion.
    canvas.drawRRect(border, _edge);

    // A valid landing is a neutral ghost, not the signal hue. This wash is
    // painted over the meters themselves, so tinting it `accent` puts "in
    // spec" across readings that are still live underneath. Refusal keeps
    // `over` — see its note in tokens.dart.
    final colour = target.valid ? colors.textPrimary : colors.over;
    final box = RRect.fromRectAndRadius(
      geometry.rectFor(target.rect),
      OaaRadius.sm,
    );

    canvas.drawRRect(box, Paint()..color = colour.withValues(alpha: 0.10));
    canvas.drawRRect(
      box,
      Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeWidth = OaaStroke.emphasis,
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
    final colors = OaaTheme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'EMPTY TAB',
            style: OaaType.label.copyWith(color: colors.textFaint),
          ),
          const SizedBox(height: Space.sm),
          Text(
            'Right-click anywhere to add a module.',
            style: OaaType.caption.copyWith(color: colors.textFaint),
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
    final colors = OaaTheme.of(context);
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
          borderRadius: OaaRadius.allSm,
          border: Border.all(color: colors.warn, width: OaaStroke.hairline),
        ),
        child: Text(
          message,
          style: OaaType.caption.copyWith(color: colors.textPrimary),
        ),
      ),
    );
  }
}
