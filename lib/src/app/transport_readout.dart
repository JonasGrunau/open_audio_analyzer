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
//
// **The box is a reservation and the ink is packed against one edge of it.**
// The width is fixed so that the row does not move when the position does: a
// host that starts rolling goes from `--:--:--` to a timecode, and a readout
// that resized on that would shove every control beside it sideways the moment
// somebody pressed play. But what the box reserves is room for a *timecode*,
// and a host that counts bars instead fills 36 px of it — so the fields are
// drawn against the edge the readout's row packs against, [TransportAlign], and
// the unspent reserve joins the row's own slack instead of sitting between two
// items as a hole. Left-aligned in the desktop's bar, `1|1.0` had 56 px of
// nothing to its right and whatever the window was not using to its left, and
// read as a number floating in the middle of the title bar.

import 'package:flutter/widgets.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';

/// Which edge of the box the fields are drawn against.
///
/// A readout belongs to the group it is packed with, and the reserve it is not
/// using belongs on the far side of it — which is a different edge on the two
/// screens. In the desktop's status bar the readout is the first item of the
/// right-hand group, so it is [trailing] and its ink sits one gap from the
/// elapsed clock, exactly as `ElapsedReadout` right-aligns inside its own 72 px
/// box for the same reason. In the tablet's link bar it is the last item before
/// the row's slack, so it is [leading] and its ink sits one gap from the tab
/// control.
///
/// **Which edge is right follows from where the slack is, so a readout that
/// moves in its row is a readout whose alignment has to be looked at again.**
/// The tablet's sat between the host name and the tabs at first, and [leading]
/// there put the unspent reserve between the ink and a control — the same hole
/// this enum exists to prevent, in the one place neither value could have
/// removed it.
enum TransportAlign { leading, trailing }

/// A readout of a DAW's transport, repainting on a clock.
class TransportReadout extends StatefulWidget {
  const TransportReadout({
    required this.transportOf,
    required this.repaint,
    this.width = defaultWidth,
    this.align = TransportAlign.leading,
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

  /// The edge the fields are packed against inside [width]. See
  /// [TransportAlign].
  final TransportAlign align;

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
          align: widget.align,
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
    required this.align,
    required this.state,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final Transport Function() transportOf;
  final OaaColors colors;
  final TransportAlign align;
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

    // The tempo is laid out before anything is drawn, because whether it is
    // drawn decides how wide the group is and therefore where the *position*
    // starts. Drawn only if it fits, rather than ellipsised: half a tempo is
    // not a tempo, and the caller that gave this box its width has already
    // decided how much of the truth it has room for.
    final tempo = transportTempo(transport);
    final tempoLine = tempo == null
        ? null
        : state._tempo.of(
            tempo,
            OaaType.readingSmall.copyWith(color: colors.textFaint),
          );
    final drawTempo =
        tempoLine != null &&
        position.longestLine + Space.md + tempoLine.longestLine <= size.width;

    final extent = drawTempo
        ? position.longestLine + Space.md + tempoLine.longestLine
        : position.longestLine;

    // The reserve the fields are not using goes to one side of them rather
    // than between them and the next item — see the note at the top of this
    // file. `size.width` is what the caller reserved for a timecode; `extent`
    // is what this host's counters actually came to.
    final origin = switch (align) {
      TransportAlign.leading => 0.0,
      TransportAlign.trailing => size.width - extent,
    };

    canvas.drawParagraph(
      position,
      // Centred in the box the way `ElapsedReadout` is, and for the reason
      // written there: a painted line drawn at the origin sits high by whatever
      // slack the box has, and every label beside it in the row is a `Text`
      // that centres itself.
      Offset(origin, (size.height - position.height) / 2),
    );

    if (drawTempo) {
      canvas.drawParagraph(
        tempoLine,
        Offset(
          origin + position.longestLine + Space.md,
          (size.height - tempoLine.height) / 2,
        ),
      );
    }
  }

  /// Only consulted when the widget hands over a new painter — a theme change.
  /// Positions arrive through `repaint` and never reach this.
  @override
  bool shouldRepaint(_TransportPainter oldDelegate) =>
      oldDelegate.colors != colors || oldDelegate.align != align;
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
