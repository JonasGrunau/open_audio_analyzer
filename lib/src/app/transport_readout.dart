// SPDX-License-Identifier: GPL-3.0-or-later
//
// The host's playhead, on whichever screen is showing it.
//
// One widget for two places: the desktop's status bar, where the transport
// belongs to the plugin being metered, and the tablet's link bar, where it
// belongs to the desktop being mirrored. Two readouts would be two ideas about
// what a missing tempo looks like, and the tablet is the screen where somebody
// is *reading* rather than working — it is the one that must not be the
// approximate version.
//
// **Painted, not built.** The position moves at the publish rate, so a
// `ValueListenableBuilder` here would rebuild a widget thirty times a second for
// as long as a DAW is rolling. `ElapsedReadout` in `lib/src/modules/
// number_box.dart` is the same shape and says the same thing: the status bar is
// exactly where that habit starts.
//
// **It draws what fits and nothing it cannot back up.** The fields are in
// priority order — position, tempo, meter — and each is skipped if the box is
// too narrow for it, so the desktop's cramped bar shows a timecode where the
// tablet shows a timecode, a tempo and a time signature, from one formatter.
// A value whose presence bit is clear is not printed at all: "120.0 BPM" under a
// host that never mentioned a tempo is exactly the invented measurement this
// project forbids, and 4/4 is the most plausible-looking of all of them.

import 'package:flutter/widgets.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';

/// A readout of a DAW's transport, repainting on a clock.
class TransportReadout extends StatefulWidget {
  const TransportReadout({
    required this.transportOf,
    required this.repaint,
    this.width = defaultWidth,
    super.key,
  });

  /// Read once per paint. A getter rather than a value because the thing it
  /// reads changes far faster than this widget should rebuild — on the desktop
  /// it is the active plugin session, on a tablet the display client's notifier.
  final Transport Function() transportOf;

  /// The single [MeterClock]. Nothing here owns a ticker: two clocks in one
  /// window drift, and a transport that disagreed with the meters beside it
  /// about when "now" is would be worse than one that is absent.
  final Listenable repaint;

  final double width;

  /// Room for a drop-frame timecode and nothing more — `01:00:03;12` at
  /// [OaaType.readingSmall]. What the desktop bar can afford.
  static const double defaultWidth = 92;

  /// Room for the position, the tempo and the time signature. What a tablet's
  /// link bar has to spare.
  static const double fullWidth = 232;

  @override
  State<TransportReadout> createState() => _TransportReadoutState();
}

class _TransportReadoutState extends State<TransportReadout> {
  // One per field rather than one for the joined string: they are laid out
  // separately because they are *placed* separately, and a single paragraph
  // would re-lay-out the whole line every time the frame counter ticked.
  final ValueParagraph _position = ValueParagraph();
  final ValueParagraph _tempo = ValueParagraph();

  @override
  void dispose() {
    _position.dispose();
    _tempo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: 16,
      child: CustomPaint(
        painter: _TransportPainter(
          transportOf: widget.transportOf,
          colors: OaaTheme.of(context),
          state: this,
          repaint: widget.repaint,
        ),
      ),
    );
  }
}

class _TransportPainter extends MeterPainter {
  _TransportPainter({
    required this.transportOf,
    required this.colors,
    required this.state,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final Transport Function() transportOf;
  final OaaColors colors;
  final _TransportReadoutState state;

  @override
  void paint(Canvas canvas, Size size) {
    final transport = transportOf();

    // Nothing known, nothing drawn — not an em dash. This widget is on screen
    // whenever a plugin is being metered or a display is attached, and neither
    // of those is a promise that a DAW exists on the far end: a dash in the
    // status bar of a desktop metering a sound card would be the application
    // reporting the absence of something nobody asked it for. When a host *is*
    // there and says nothing, the dashes belong to the fields it did not
    // mention, and those are simply not printed either.
    if (!transport.isPresent) return;

    // **Brightness carries rolling versus parked**, which is the one fact a
    // position cannot state on its own: a stopped playhead and a playing one
    // sitting on the same frame print identical strings. Not a hue — the signal
    // colour in this application means "in spec" and nothing else, and a
    // transport is not a verdict.
    final positionColour = transport.isPlaying
        ? colors.textPrimary
        : colors.textMuted;

    final position = state._position.of(
      transportPosition(transport),
      OaaType.readingSmall.copyWith(color: positionColour),
    );
    canvas.drawParagraph(
      position,
      // Centred in the box the way `ElapsedReadout` is, and for the reason
      // written there: a painted line drawn at the origin sits high by whatever
      // slack the box has, and every label beside it in the row is a `Text`
      // that centres itself.
      Offset(0, (size.height - position.height) / 2),
    );

    final tempo = transportTempo(transport);
    if (tempo == null) return;

    final paragraph = state._tempo.of(
      tempo,
      OaaType.readingSmall.copyWith(color: colors.textFaint),
    );

    final left = position.longestLine + Space.md;
    // Drawn only if it fits, rather than ellipsised. Half a tempo is not a
    // tempo, and the caller that gave this box its width has already decided
    // how much of the truth it has room for.
    if (left + paragraph.longestLine <= size.width) {
      canvas.drawParagraph(
        paragraph,
        Offset(left, (size.height - paragraph.height) / 2),
      );
    }
  }

  /// Only consulted when the widget hands over a new painter — a theme change.
  /// Positions arrive through `repaint` and never reach this.
  @override
  bool shouldRepaint(_TransportPainter oldDelegate) =>
      oldDelegate.colors != colors;
}

/// Where the playhead is, in the most precise unit the host gave.
///
/// Timecode first, because it is the one an engineer can match to somebody
/// else's session; then bars and beats, which is what a musician reads; then
/// plain elapsed time, which every host reports. A host that gave none of the
/// three has said nothing about where it is, and says so.
///
/// Top-level and tested directly. What a readout *says* is the part that can be
/// wrong in a way nobody notices — a bar number under a host that never sent a
/// time signature, a tempo of 0.0 printed as `0.0 BPM` — and none of that is
/// visible in a widget test of a painter. The pixels are checked by looking at
/// the application; the rules are checked here.
@visibleForTesting
String transportPosition(Transport transport) {
  final timecode = transport.timecode;
  if (timecode != null) return timecode;

  final barBeat = transport.barAndBeat;
  if (barBeat != null) {
    // `bar|beat`, the convention a Pro Tools counter uses, rather than the
    // dotted `3.3.5` an Ableton one does: the dot form puts three numbers in a
    // row with no unit between them, and this readout sits beside a timecode
    // that is also digits and colons. The bar separates the two counters.
    //
    // One decimal on the beat: a bar and beat that only moved on the beat would
    // look frozen for most of a bar at 128 bpm, and the tenth is exactly the
    // precision `barAndBeat` documents as trustworthy — the beat is exact, the
    // bar number is counted.
    return '${barBeat.bar}|${barBeat.beat.toStringAsFixed(1)}';
  }

  if (transport.hasTimeSeconds) return _clock(transport.timeSeconds);

  // Present — the host said *something* — but nothing about where it is.
  return '--:--:--';
}

/// Tempo and time signature, or null when the host offered neither.
///
/// Each half appears only behind its own presence bit. A host that reports a
/// tempo and no meter gets `128.0 BPM`, and one that reports neither gets
/// nothing at all rather than `0.0 BPM · 0/0` — which is not a degraded
/// readout, it is a made-up one.
@visibleForTesting
String? transportTempo(Transport transport) {
  final parts = <String>[
    if (transport.hasBpm) '${transport.bpm.toStringAsFixed(1)} BPM',
    if (transport.hasTimeSignature)
      '${transport.timeSigNumerator}/${transport.timeSigDenominator}',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

String _clock(double seconds) {
  if (!seconds.isFinite) return '--:--:--';
  final negative = seconds < 0;
  final total = seconds.abs().floor();
  String pad(int value) => value.toString().padLeft(2, '0');
  return '${negative ? '-' : ''}${pad(total ~/ 3600)}:'
      '${pad((total % 3600) ~/ 60)}:${pad(total % 60)}';
}
