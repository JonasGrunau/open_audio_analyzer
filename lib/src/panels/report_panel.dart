// Offline file analysis, and the report it produces.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Drop a file on this panel and it is measured by the same engine the live
// meters run on, through the same decoder the `bel` CLI uses. That is not an
// implementation detail worth being quiet about — it is the reason the number
// here can be trusted, and it is why this panel has no DSP of its own at all.
// Everything below the analysis call is presentation.
//
// The panel is one of three states and never two at once: waiting for a file,
// measuring one, or showing what it found. A panel that keeps a stale report
// visible while a new file analyses is a panel somebody reads the wrong number
// off.
//
// ---------------------------------------------------------------------------
// This file is why the macOS build declares a file-access entitlement
//
// This is the only place in the app that opens a file the user chose or writes
// one where they chose, so `com.apple.security.files.user-selected.read-write`
// in `macos/Runner/{DebugProfile,Release}.entitlements` exists for this panel.
// Dropped files arrive through the same mechanism.
//
// The macOS build is **not** sandboxed today — see the reasoning at the top of
// `Release.entitlements`, which turns on where Bel keeps its configuration —
// so that entitlement is currently a correct declaration of what this panel
// does rather than something it depends on. If the sandbox is ever switched
// back on, it becomes load-bearing, and the failure it prevents is unusually
// misleading: powerbox draws the open and save panels out of process, so they
// still *appear*, the user picks a file, and only then does the read or write
// fail — surfacing as a decode or write error rather than as a permission
// problem. If either ever fails on macOS and nowhere else, check the
// entitlements before reading a line of this file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bel_core/bel_core.dart';
import 'package:bel_engine/bel_engine.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/offline_job.dart';
import '../data/providers.dart';
import 'report_card.dart';

/// Opens the analysis panel.
Future<void> showReportPanel(BuildContext context) => showBelPanel<void>(
  context: context,
  builder: (context) => const ReportPanel(),
);

/// Extensions the engine's decoder actually handles.
///
/// Used only to filter the Open dialog and to give a clearer message on a
/// wrong drop — the decoder identifies a file by its contents, not its name,
/// so a mislabelled file still analyses correctly if it is really audio.
const _audioExtensions = <String>[
  'wav',
  'wave',
  'aif',
  'aiff',
  'aifc',
  'rf64',
  'w64',
  'flac',
  'mp3',
];

class ReportPanel extends ConsumerStatefulWidget {
  const ReportPanel({super.key});

  @override
  ConsumerState<ReportPanel> createState() => _ReportPanelState();
}

class _ReportPanelState extends ConsumerState<ReportPanel> {
  OfflineAnalysisJob? _job;
  StreamSubscription<OfflineEvent>? _subscription;

  String? _path;
  double? _progress;
  String? _error;
  AnalysisReport? _report;
  bool _dropActive = false;

  @override
  void dispose() {
    _subscription?.cancel();
    _job
      ?..cancel()
      ..dispose();
    super.dispose();
  }

  bool get _isRunning => _job != null;

  Future<void> _pick() async {
    const group = XTypeGroup(label: 'Audio', extensions: _audioExtensions);
    final file = await openFile(acceptedTypeGroups: const [group]);
    if (file != null) await _analyse(file.path);
  }

  Future<void> _analyse(String path) async {
    await _stop();

    setState(() {
      _path = path;
      _progress = 0;
      _error = null;
      _report = null;
    });

    final OfflineAnalysisJob job;
    try {
      job = await OfflineAnalysisJob.start(path);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
      return;
    }

    if (!mounted) {
      job
        ..cancel()
        ..dispose();
      return;
    }

    setState(() => _job = job);
    _subscription = job.events.listen(_onEvent, onDone: _onDone);
  }

  void _onEvent(OfflineEvent event) {
    if (!mounted) return;

    switch (event) {
      case OfflineProgressEvent(:final fraction):
        setState(() => _progress = fraction);
      case OfflineDoneEvent(:final result):
        setState(() => _report = _buildReport(result));
      case OfflineFailedEvent(:final message):
        setState(() => _error = message);
      case OfflineCancelledEvent():
        setState(() {
          _path = null;
          _progress = null;
        });
    }
  }

  void _onDone() {
    _subscription = null;
    final job = _job;
    if (job == null) return;
    job.dispose();
    if (mounted) setState(() => _job = null);
  }

  Future<void> _stop() async {
    _job?.cancel();
    await _subscription?.cancel();
    _subscription = null;
    _job?.dispose();
    _job = null;
  }

  /// Joins the engine's measurements to the domain report.
  ///
  /// The calibration comes from the app's current selection, so the verdict
  /// this panel shows and the verdict the meters show are the same judgement
  /// against the same target.
  AnalysisReport _buildReport(OfflineResult result) {
    final path = _path ?? '';
    final separator = path.contains('/') ? '/' : r'\';

    return AnalysisReport(
      fileName: path.split(separator).last,
      filePath: path,
      formatLabel: result.formatLabel,
      sampleRate: result.sampleRate,
      channels: result.channels,
      bitsPerSample: result.bitsPerSample,
      durationSeconds: result.durationSeconds,
      generatedAt: DateTime.now(),
      lufsIntegrated: result.lufsIntegrated,
      loudnessRange: result.loudnessRange,
      loudnessRangeLow: result.loudnessRangeLow,
      loudnessRangeHigh: result.loudnessRangeHigh,
      truePeakMax: result.truePeakMax,
      samplePeakMax: result.samplePeakMax,
      momentaryMax: result.momentaryMax,
      shortTermMax: result.shortTermMax,
      shortTermMin: result.shortTermMin,
      correlationMin: result.correlationMin,
      correlationMax: result.correlationMax,
      correlationMean: result.correlationMean,
      channelPeakMax: result.channelPeakMax,
      calibration: ref.read(calibrationProvider),
      timeline: [
        for (final point in result.timeline)
          ReportTimelinePoint(
            seconds: point.seconds,
            momentary: point.momentary,
            shortTerm: point.shortTerm,
            truePeak: point.truePeak,
          ),
      ],
      toolVersion: 'Bel',
    );
  }

  Future<void> _export(ReportFormat format) async {
    final report = _report;
    if (report == null) return;

    final location = await getSaveLocation(
      suggestedName: format.suggestedFileName(report),
      acceptedTypeGroups: [
        XTypeGroup(label: format.label, extensions: [format.extension]),
      ],
    );
    if (location == null) return;

    // Written through dart:io rather than XFile.saveTo, which on desktop is
    // the same write with a copy of the bytes in front of it. UTF-8 explicitly
    // because a report contains an em dash for every unmeasured value and the
    // platform default encoding is not the same on all three desktops.
    final data = exportReport(report, format);
    await File(location.path).writeAsString(data, encoding: utf8);
  }

  /// The report as a PNG, for pasting into a message rather than parsing.
  ///
  /// Separate from [ReportFormat] on purpose: the other three are rendered in
  /// `bel_core`, which is pure Dart and cannot reach `dart:ui`. Drawing a
  /// picture needs a `Canvas`, so the card lives in the app — see
  /// `report_card.dart`.
  Future<void> _exportCard() async {
    final report = _report;
    if (report == null) return;

    final colors = BelTheme.of(context);
    final bytes = await renderReportCard(report, colors);
    if (bytes == null) return;

    final location = await getSaveLocation(
      suggestedName: '${_stem(report.fileName)} — Bel report.png',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PNG', extensions: ['png']),
      ],
    );
    if (location == null) return;

    await File(location.path).writeAsBytes(bytes);
  }

  static String _stem(String fileName) => fileName.contains('.')
      ? fileName.substring(0, fileName.lastIndexOf('.'))
      : fileName;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return PanelScaffold(
      title: 'File analysis',
      onClose: () => Navigator.of(context).maybePop(),
      footer: _footer(colors),
      child: DropTarget(
        onDragEntered: (_) => setState(() => _dropActive = true),
        onDragExited: (_) => setState(() => _dropActive = false),
        onDragDone: (details) {
          setState(() => _dropActive = false);
          final first = details.files.firstOrNull;
          if (first != null) unawaited(_analyse(first.path));
        },
        child: _body(colors),
      ),
    );
  }

  Widget _body(BelColors colors) {
    if (_error != null) return _Message(text: _error!, tone: colors.over);
    if (_isRunning) return _progressView(colors);

    final report = _report;
    if (report == null) return _DropZone(active: _dropActive, onPick: _pick);

    return _ReportView(report: report);
  }

  Widget _progressView(BelColors colors) {
    final name = (_path ?? '').split(RegExp(r'[/\\]')).last;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Analysing $name',
            style: BelType.body.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: Space.md),
          SizedBox(
            width: 320,
            child: LinearProgressIndicator(
              value: _progress,
              minHeight: 2,
              backgroundColor: colors.meterTrack,
              color: colors.accent,
            ),
          ),
          const SizedBox(height: Space.md),
          BelButton(label: 'Cancel', onPressed: () => unawaited(_stop())),
        ],
      ),
    );
  }

  Widget? _footer(BelColors colors) {
    final report = _report;
    if (report == null) return null;

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        BelButton(
          label: 'Analyse another…',
          onPressed: () => unawaited(_pick()),
        ),
        const SizedBox(width: Space.sm),
        for (final format in ReportFormat.values) ...[
          BelButton(
            label: format.extension.toUpperCase(),
            onPressed: () => unawaited(_export(format)),
          ),
          const SizedBox(width: Space.sm),
        ],
        BelButton(label: 'PNG', onPressed: () => unawaited(_exportCard())),
      ],
    );
  }
}

/// Where a file is dropped when there is nothing to show yet.
class _DropZone extends StatelessWidget {
  const _DropZone({required this.active, required this.onPick});

  final bool active;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Painted, not decorated. A DecoratedBox here would swallow the
          // pointer events the button below it needs — the same trap the
          // module frames hit, documented at the head of module_frame.dart.
          CustomPaint(
            painter: _DropOutlinePainter(
              color: active ? colors.accent : colors.hairlineStrong,
            ),
            child: SizedBox(
              width: double.infinity,
              height: 140,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Drop an audio file here',
                      style: BelType.body.copyWith(
                        color: active ? colors.accent : colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: Space.xs),
                    Text(
                      'WAV, AIFF, RF64, Wave64, FLAC, MP3',
                      style: BelType.caption.copyWith(color: colors.textFaint),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: Space.md),
          BelButton(label: 'Choose a file…', onPressed: onPick),
        ],
      ),
    );
  }
}

/// The dashed outline of the drop zone.
class _DropOutlinePainter extends MeterPainter {
  const _DropOutlinePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = BelStroke.hairline
      ..color = color;

    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(4),
    );

    // Dashes are drawn as a path rather than faked with a border, because
    // Flutter has no dashed border and a solid one reads as a container rather
    // than as a target.
    final path = Path()..addRRect(rect);
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + 6).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += 11;
      }
    }
  }

  @override
  bool shouldRepaint(_DropOutlinePainter old) => old.color != color;
}

class _Message extends StatelessWidget {
  const _Message({required this.text, required this.tone});

  final String text;
  final Color tone;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Space.xxl),
    child: Center(
      child: Text(text, style: BelType.body.copyWith(color: tone)),
    ),
  );
}

/// The measured result.
class _ReportView extends StatelessWidget {
  const _ReportView({required this.report});

  final AnalysisReport report;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelSection(
          title: 'Source',
          children: [
            PanelRow(label: 'File', child: _Value(report.fileName)),
            PanelRow(label: 'Format', child: _Value(report.describeSource())),
            PanelRow(
              label: 'Duration',
              child: _Value(report.describeDuration()),
            ),
          ],
        ),
        PanelSection(
          title: 'Measurements',
          children: [
            for (final (metric, value) in report.summary)
              PanelRow(
                label: metric.label,
                child: _Reading(metric: metric, value: value),
              ),
          ],
        ),
        if (report.timeline.length > 1)
          PanelSection(
            title: 'Loudness over time',
            note: 'Short-term loudness, with the integrated level marked.',
            children: [
              SizedBox(
                height: 120,
                child: CustomPaint(
                  painter: _TimelinePainter(
                    timeline: report.timeline,
                    integrated: report.lufsIntegrated,
                    colors: colors,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),
        if (report.calibration != null)
          PanelSection(
            title: 'Target — ${report.calibration!.name}',
            children: [
              for (final check in report.checks)
                PanelRow(
                  label: check.metric.label,
                  note: 'required ${check.limitLabel}',
                  child: _Verdict(check: check, colors: colors),
                ),
            ],
          ),
      ],
    );
  }
}

class _Value extends StatelessWidget {
  const _Value(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: BelType.body.copyWith(color: BelTheme.of(context).textPrimary),
    textAlign: TextAlign.end,
  );
}

class _Reading extends StatelessWidget {
  const _Reading({required this.metric, required this.value});

  final Metric metric;
  final double value;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    final unit = metric.unit.isEmpty ? '' : ' ${metric.unit}';

    return Text(
      '${metric.format(value)}$unit',
      style: BelType.readingSmall.copyWith(
        color: value.isNaN ? colors.textFaint : colors.textPrimary,
      ),
      textAlign: TextAlign.end,
    );
  }
}

class _Verdict extends StatelessWidget {
  const _Verdict({required this.check, required this.colors});

  final ComplianceCheck check;
  final BelColors colors;

  @override
  Widget build(BuildContext context) {
    final tone = switch (check.verdict) {
      ComplianceVerdict.pass => colors.accent,
      ComplianceVerdict.fail => colors.over,
      ComplianceVerdict.notMeasured => colors.textFaint,
    };

    final unit = check.metric.unit.isEmpty ? '' : ' ${check.metric.unit}';

    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          '${check.metric.format(check.value)}$unit',
          style: BelType.readingSmall.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(width: Space.smd),
        Text(check.verdictLabel, style: BelType.caption.copyWith(color: tone)),
      ],
    );
  }
}

/// Short-term loudness across the programme, with the integrated level marked.
///
/// Drawn from the report's own timeline rather than from anything live, so it
/// is a picture of the file and not of the moment it was opened.
class _TimelinePainter extends MeterPainter {
  const _TimelinePainter({
    required this.timeline,
    required this.integrated,
    required this.colors,
  });

  final List<ReportTimelinePoint> timeline;
  final double integrated;
  final BelColors colors;

  /// The window the graph spans. Fixed rather than fitted to the data: an axis
  /// that rescales per file is one you cannot compare two files on, which is
  /// the same reason the spectrum analyser's frequency axis is fixed.
  static const double _top = 0.0;
  static const double _bottom = -40.0;

  double _y(double lufs, double height) {
    final clamped = lufs.clamp(_bottom, _top);
    return height * (_top - clamped) / (_top - _bottom);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (timeline.isEmpty || size.width <= 0) return;

    final grid = Paint()
      ..color = colors.hairline
      ..strokeWidth = BelStroke.hairline;

    for (var lufs = _top; lufs >= _bottom; lufs -= 10) {
      final y = _y(lufs, size.height);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final duration = timeline.last.seconds;
    if (duration <= 0) return;

    // One path built per paint, which would be forbidden on the frame path and
    // is fine here: this panel repaints when a file finishes analysing, not
    // sixty times a second.
    final path = Path();
    var started = false;

    for (final point in timeline) {
      if (point.shortTerm.isNaN) continue;
      final x = size.width * (point.seconds / duration);
      final y = _y(point.shortTerm, size.height);
      if (started) {
        path.lineTo(x, y);
      } else {
        path.moveTo(x, y);
        started = true;
      }
    }

    if (started) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = BelStroke.mark
          ..color = colors.meterFill,
      );
    }

    if (integrated.isFinite) {
      final y = _y(integrated, size.height);
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..color = colors.accent
          ..strokeWidth = BelStroke.hairline,
      );
    }
  }

  @override
  bool shouldRepaint(_TimelinePainter old) =>
      !identical(old.timeline, timeline) ||
      old.integrated != integrated ||
      old.colors != colors;
}
