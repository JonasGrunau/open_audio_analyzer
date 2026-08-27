/// A DAW's transport position.
///
/// SPDX-License-Identifier: GPL-3.0-or-later
///
/// This is domain vocabulary, not wire format — `oaa_wire` decodes bytes into
/// it, the LUFS module renders it, and neither knows about the other. The same
/// split `MeterSource` and `WireSnapshot` use, for the same reason.
///
/// It is deliberately **not** part of `oaa_snapshot`. The engine measures audio
/// and does not know what a DAW is; giving it a playhead field would leave
/// every consumer that has no host — device capture, file analysis, the
/// conformance suite — carrying a field that is permanently meaningless, and
/// would require an engine API to set it. That API is the moment `engine/`
/// learns about hosts, and it does not get to.
library;

/// What a LUFS module counts from.
///
/// Decibel offers the same four and the distinction matters more than it looks:
/// an integrated reading is only meaningful relative to a stated start, and
/// four people measuring "the loudness of this mix" from four different origins
/// get four different numbers, all correct.
/// **Declaration order is the wire encoding.** `docs/WIRE.md` `0x0020` freezes
/// `continuous` as 0, `system` as 1, `elapsed` as 2 and `timecode` as 3, and the
/// index of a value here is the integer that goes on the socket. A mode may
/// therefore only ever be *appended*, and reordering these is a protocol change
/// wearing the clothes of a tidy-up.
enum LufsTimeMode {
  /// Measures from the last manual reset and keeps going regardless of what the
  /// host is doing. The only mode available without a DAW.
  continuous('continuous', 'Continuous'),

  /// Measures from when audio started arriving, resetting when it stops.
  ///
  /// Silence rather than the stream stopping, because a sound card with nothing
  /// playing goes on delivering its own noise floor all day — so a mode keyed on
  /// "is audio arriving" would never restart on a device and would be
  /// indistinguishable from [continuous] there. The engine owns the threshold;
  /// see `oaa_engine_set_silence_reset`.
  system('system', 'System'),

  /// Measures from when the host's transport started rolling, and holds while
  /// it is stopped. Needs [Transport.isPlaying].
  elapsed('elapsed', 'Elapsed'),

  /// Measures between two timeline positions, so the same region of a session
  /// measures the same on every pass. Needs [Transport.hasTimecode].
  timecode('timecode', 'Timecode');

  const LufsTimeMode(this.id, this.label);

  /// Stable identifier for presets. Never change one of these; add a new mode
  /// instead. Distinct from [wireValue], which is the index — a preset is text
  /// a human may have edited, and the wire is a frozen byte table.
  final String id;

  /// What the module's menu says.
  final String label;

  /// The integer `docs/WIRE.md` `0x0020` carries for this mode.
  int get wireValue => index;

  /// Whether this mode can be honoured by a producer that has no playhead.
  bool get needsTransport =>
      this == LufsTimeMode.elapsed || this == LufsTimeMode.timecode;

  /// Whether this mode needs a region alongside it.
  bool get needsRegion => this == LufsTimeMode.timecode;

  static LufsTimeMode? fromId(String id) {
    for (final mode in values) {
      if (mode.id == id) return mode;
    }
    return null;
  }

  /// Decodes a wire value, returning null for one this build does not know —
  /// which is what a producer newer than its consumer looks like.
  static LufsTimeMode? fromWireValue(int value) =>
      value >= 0 && value < values.length ? values[value] : null;
}

/// The stretch of timeline [LufsTimeMode.timecode] measures between.
///
/// Seconds from the timeline origin, the same origin as [Transport.timeSeconds],
/// because that is the field a producer compares against per audio block. What
/// the user typed as timecode is a rendering of this and not its storage — a
/// region stored as timecode would change meaning the moment the session's frame
/// rate did.
class LufsRegion {
  const LufsRegion(this.startSeconds, this.endSeconds);

  final double startSeconds;
  final double endSeconds;

  /// End is exclusive, so a zero-length region measures nothing and is not
  /// valid. `docs/WIRE.md` requires end greater than start.
  bool get isValid =>
      endSeconds > startSeconds &&
      startSeconds.isFinite &&
      endSeconds.isFinite &&
      startSeconds >= 0;

  double get durationSeconds => endSeconds - startSeconds;

  Map<String, Object?> toJson() => {'from': startSeconds, 'to': endSeconds};

  static LufsRegion? fromJson(Map<String, Object?> json) {
    final from = (json['from'] as num?)?.toDouble();
    final to = (json['to'] as num?)?.toDouble();
    if (from == null || to == null) return null;
    final region = LufsRegion(from, to);
    return region.isValid ? region : null;
  }

  @override
  bool operator ==(Object other) =>
      other is LufsRegion &&
      other.startSeconds == startSeconds &&
      other.endSeconds == endSeconds;

  @override
  int get hashCode => Object.hash(startSeconds, endSeconds);

  @override
  String toString() => 'LufsRegion($startSeconds, $endSeconds)';
}

/// Timecode frame rates, using the values carried on the wire verbatim.
///
/// The odd numbering — and `unknown` at 99 rather than 9 — is JUCE's
/// `AudioPlayHead::FrameRateType`, kept rather than renumbered so that the
/// plugin, this package and `docs/WIRE.md` all say the same integers. A tidier
/// local enum would be one more mapping to get wrong.
enum TimecodeFrameRate {
  fps23976(0, 24000 / 1001, 24),
  fps24(1, 24, 24),
  fps25(2, 25, 25),
  fps2997(3, 30000 / 1001, 30),
  fps30(4, 30, 30),
  fps2997drop(5, 30000 / 1001, 30),
  fps30drop(6, 30, 30),
  fps60(7, 60, 60),
  fps60drop(8, 60, 60),
  unknown(99, 0, 0);

  const TimecodeFrameRate(
    this.wireValue,
    this.framesPerSecond,
    this.nominalRate,
  );

  final int wireValue;

  /// Frames actually shown per second of real time. 29.97, not 30.
  final double framesPerSecond;

  /// What the frame counter counts to before rolling over — 30 for every
  /// 29.97 variant.
  ///
  /// Distinct from [framesPerSecond], and conflating the two is the classic
  /// timecode bug: a 29.97 stream still labels its frames 0–29, it just takes
  /// slightly longer than a second to get through them. Counting to 29.97 of
  /// anything produces a timecode that is wrong in a way nobody can see until
  /// they try to match it to picture.
  final int nominalRate;

  /// True for the rates that skip frame *numbers* to stay with the wall clock.
  ///
  /// The pictures are not dropped — a drop-frame stream contains exactly as
  /// many frames as a non-drop one — only their labels are. 29.97 non-drop
  /// runs slow against the clock by about 3.6 seconds an hour, which is
  /// unusable for broadcast, so drop-frame omits two numbers at the start of
  /// every minute except every tenth and lands back within a frame.
  bool get isDropFrame =>
      this == fps2997drop || this == fps30drop || this == fps60drop;

  static TimecodeFrameRate fromWire(int value) {
    for (final rate in values) {
      if (rate.wireValue == value) return rate;
    }
    return unknown;
  }
}

/// One reading of the host's transport, as of the start of an audio block.
///
/// Every optional value carries a `has…` flag, and reading a value whose flag
/// is clear gives you a zero that means nothing. That is not defensive
/// programming — hosts genuinely differ in what they report, and a missing
/// tempo arriving as 0.0 is indistinguishable from a real one. "Bar 1, beat 1,
/// 00:00:00:00" is a perfectly plausible readout to show somebody while the
/// host is parked at bar 57, which makes it exactly the invented measurement
/// the project forbids. Check the flag; render an em dash when it is clear.
class Transport {
  const Transport({
    this.flags = 0,
    this.frameRate = TimecodeFrameRate.unknown,
    this.timeSeconds = 0,
    this.ppqPosition = 0,
    this.ppqBarStart = 0,
    this.bpm = 0,
    this.editOriginSeconds = 0,
    this.loopStartPpq = 0,
    this.loopEndPpq = 0,
    this.timeSamples = 0,
    this.timeSigNumerator = 0,
    this.timeSigDenominator = 0,
    this.hostFrames = 0,
  });

  /// Nothing known. What a display shows before a host has ever spoken, and
  /// what the plugin publishes when the host offers no playhead at all.
  static const Transport none = Transport();

  static const int flagPlaying = 1 << 0;
  static const int flagRecording = 1 << 1;
  static const int flagLooping = 1 << 2;
  static const int flagHasTimeSeconds = 1 << 3;
  static const int flagHasPpq = 1 << 4;
  static const int flagHasBpm = 1 << 5;
  static const int flagHasTimeSig = 1 << 6;
  static const int flagHasTimecode = 1 << 7;
  static const int flagHasTimeSamples = 1 << 8;
  static const int flagHasLoopPoints = 1 << 9;
  static const int flagHasBarStart = 1 << 10;
  static const int flagDiscontinuity = 1 << 11;

  final int flags;
  final TimecodeFrameRate frameRate;

  /// Playhead position on the host's timeline, seconds.
  final double timeSeconds;
  final double ppqPosition;
  final double ppqBarStart;
  final double bpm;

  /// Offset from timeline zero to the session's start. Add to [timeSeconds]
  /// for wall-clock timecode; hosts that place bar 1 at 01:00:00:00 report it
  /// here, and ignoring it puts every timecode an hour out.
  final double editOriginSeconds;

  final double loopStartPpq;
  final double loopEndPpq;
  final int timeSamples;
  final int timeSigNumerator;
  final int timeSigDenominator;

  /// Frames in the block this position describes.
  final int hostFrames;

  bool get isPlaying => flags & flagPlaying != 0;
  bool get isRecording => flags & flagRecording != 0;
  bool get isLooping => flags & flagLooping != 0;

  bool get hasTimeSeconds => flags & flagHasTimeSeconds != 0;
  bool get hasPpq => flags & flagHasPpq != 0;
  bool get hasBpm => flags & flagHasBpm != 0;
  bool get hasTimeSignature => flags & flagHasTimeSig != 0;
  bool get hasTimecode => flags & flagHasTimecode != 0;
  bool get hasTimeSamples => flags & flagHasTimeSamples != 0;
  bool get hasLoopPoints => flags & flagHasLoopPoints != 0;
  bool get hasBarStart => flags & flagHasBarStart != 0;

  /// The playhead did not arrive where the previous block left it — the user
  /// relocated, looped, or scrubbed.
  ///
  /// The only flag here that is about a measurement rather than about the host.
  /// Somebody who plays bars 1–16, stops, drags back and plays again has fed
  /// the engine both passes, and its integrated loudness is now the average of
  /// two takes of the same music reported as one programme. Nothing about that
  /// number looks wrong, which is exactly why it has to be said out loud.
  ///
  /// The same class of problem as [MeterSource.hasOverrun]: an integrated
  /// reading that describes different audio than the listener believes.
  ///
  /// Deciding what to *do* about it — whether a relocate restarts the
  /// integration — belongs to the [LufsTimeMode] the user picked, and acting on
  /// it needs the app-to-plugin control channel that protocol version 1 does
  /// not have. Until then, report it.
  bool get isDiscontinuous => flags & flagDiscontinuity != 0;

  /// True when a host has said anything at all. False means no DAW, and the
  /// [LufsTimeMode.elapsed] and [LufsTimeMode.timecode] modes are unavailable
  /// rather than merely empty.
  bool get isPresent => flags != 0;

  /// The bar and beat the playhead is in, one-based, or null when the host did
  /// not supply enough to work it out.
  ///
  /// **`beat` is exact; `bar` assumes the time signature has not changed since
  /// the start of the timeline.** The two halves are not equally trustworthy
  /// and it is worth knowing which is which.
  ///
  /// The beat is measured from the bar the host itself reported the start of,
  /// so it is right regardless of what came before. The bar *number* has to be
  /// counted, and nothing in the protocol says how many bars have gone by —
  /// only how far along the timeline this bar begins. Dividing by the current
  /// bar length is correct for a session in one meter throughout, which is
  /// nearly all of them, and drifts after a meter change.
  ///
  /// Open Audio Analyzer does not attempt to hide that by refusing to show a
  /// bar number: a number that is right in the ordinary case and stated to be
  /// approximate in the unusual one is more use than no number at all. It is,
  /// however, why nothing downstream should treat this as a measurement.
  ({int bar, double beat})? get barAndBeat {
    if (!hasPpq || !hasBarStart || !hasTimeSignature) return null;
    if (timeSigNumerator <= 0 || timeSigDenominator <= 0) return null;

    // Quarter notes to the bar. `ppq` is quarter notes, so the denominator is
    // what converts: 7/8 is seven eighths, which is 3.5 quarter notes — not
    // seven of anything ppq counts.
    final quarterNotesPerBar = timeSigNumerator * 4.0 / timeSigDenominator;
    if (quarterNotesPerBar <= 0) return null;

    // Beats within the bar, in units of the denominator: in 7/8 a beat is an
    // eighth, so a quarter-note past the bar line is beat 3, not beat 2.
    final beatInBar = (ppqPosition - ppqBarStart) * timeSigDenominator / 4.0;
    final bar = ppqBarStart / quarterNotesPerBar;

    return (bar: bar.floor() + 1, beat: beatInBar + 1);
  }

  /// Wall-clock timecode as `HH:MM:SS:FF`, or `HH:MM:SS;FF` for drop-frame, or
  /// null when the host gave no frame rate to count frames against.
  ///
  /// Counted from the session start, not from the timeline origin —
  /// [editOriginSeconds] is added, because hosts that place bar 1 at
  /// 01:00:00:00 report that offset separately and ignoring it puts every
  /// reading exactly an hour out. Which looks entirely reasonable until
  /// somebody matches it to picture.
  ///
  /// **Drop-frame is really computed, not just punctuated differently.** The
  /// semicolon is the convention, but it is not the substance: a drop-frame
  /// counter omits two frame numbers at the start of every minute except every
  /// tenth, which is what keeps 29.97 within a frame of the wall clock instead
  /// of losing 3.6 seconds an hour. Rendering the same numbers as 30 fps and
  /// changing only the separator would be a timecode that is wrong by up to
  /// four seconds across a feature, displayed with complete confidence.
  String? get timecode {
    if (!hasTimecode || !hasTimeSeconds) return null;

    final fps = frameRate.framesPerSecond;
    final nominal = frameRate.nominalRate;
    if (fps <= 0 || nominal <= 0) return null;

    final total = timeSeconds + editOriginSeconds;
    if (total.isNaN || total.isInfinite) return null;

    final negative = total < 0;

    // The count of real frames elapsed, at the true rate. Everything below is
    // relabelling this number; none of it changes which frame is being named.
    //
    // Truncated, not rounded. Timecode names the frame currently on screen,
    // and a frame stays on screen for its whole duration — rounding would name
    // the *next* one for the back half of every frame, so a playhead parked
    // still would read one frame ahead of the picture it is sitting on.
    var frame = (total.abs() * fps).floor();

    if (frameRate.isDropFrame) {
      // Two numbers per minute at 30, four at 60 — the count that keeps the
      // labels tracking the clock.
      final dropped = (nominal / 15).round();

      // A ten-minute block is the repeating unit: nine minutes drop, the tenth
      // does not, which is what stops the correction over-shooting.
      final framesPerTenMinutes = (fps * 600).round();
      final framesPerMinute = nominal * 60 - dropped;

      final tenMinuteBlocks = frame ~/ framesPerTenMinutes;
      final remainder = frame % framesPerTenMinutes;

      frame += dropped * 9 * tenMinuteBlocks;
      if (remainder > dropped) {
        frame += dropped * ((remainder - dropped) ~/ framesPerMinute);
      }
    }

    // Divided by the nominal rate, never the true one: a 29.97 stream still
    // labels its frames 0–29.
    final frames = frame % nominal;
    final totalSeconds = frame ~/ nominal;

    String pad(int v) => v.toString().padLeft(2, '0');
    final separator = frameRate.isDropFrame ? ';' : ':';

    return '${negative ? '-' : ''}${pad(totalSeconds ~/ 3600)}:'
        '${pad((totalSeconds ~/ 60) % 60)}:'
        '${pad(totalSeconds % 60)}$separator${pad(frames)}';
  }

  /// This reading with [isDiscontinuous] set.
  ///
  /// For a relay. `docs/WIRE.md` is explicit that the bit is **an edge,
  /// delivered once** rather than a state to be sampled: a producer that emits
  /// frames less often than blocks arrive has to accumulate it between frames,
  /// because the jump is visible to it for exactly one block. Anything that
  /// forwards transport at its own rate inherits that obligation — the desktop
  /// relaying a plugin's playhead to a tablet publishes thirty times a second
  /// against a DAW's ninety-odd blocks, so two frames in three would take the
  /// bit with them if it were copied rather than carried forward. A relocate
  /// that vanishes on the way to a screen is a screen that cannot be used to
  /// count them, which `docs/WIRE.md` says a consumer may do.
  Transport asDiscontinuous() => isDiscontinuous
      ? this
      : Transport(
          flags: flags | flagDiscontinuity,
          frameRate: frameRate,
          timeSeconds: timeSeconds,
          ppqPosition: ppqPosition,
          ppqBarStart: ppqBarStart,
          bpm: bpm,
          editOriginSeconds: editOriginSeconds,
          loopStartPpq: loopStartPpq,
          loopEndPpq: loopEndPpq,
          timeSamples: timeSamples,
          timeSigNumerator: timeSigNumerator,
          timeSigDenominator: timeSigDenominator,
          hostFrames: hostFrames,
        );

  /// Value equality, because a relay sends on change.
  ///
  /// The desktop forwards a plugin's transport to its displays only when it
  /// differs from the last one it sent, which is what keeps a parked session
  /// and a machine with no DAW at all off the wire entirely. That comparison is
  /// this operator, and it has to include every field: a host that moves the
  /// playhead without changing anything else — which is every block of ordinary
  /// playback — must not compare equal.
  @override
  bool operator ==(Object other) =>
      other is Transport &&
      other.flags == flags &&
      other.frameRate == frameRate &&
      other.timeSeconds == timeSeconds &&
      other.ppqPosition == ppqPosition &&
      other.ppqBarStart == ppqBarStart &&
      other.bpm == bpm &&
      other.editOriginSeconds == editOriginSeconds &&
      other.loopStartPpq == loopStartPpq &&
      other.loopEndPpq == loopEndPpq &&
      other.timeSamples == timeSamples &&
      other.timeSigNumerator == timeSigNumerator &&
      other.timeSigDenominator == timeSigDenominator &&
      other.hostFrames == hostFrames;

  @override
  int get hashCode => Object.hash(
    flags,
    frameRate,
    timeSeconds,
    ppqPosition,
    ppqBarStart,
    bpm,
    editOriginSeconds,
    loopStartPpq,
    loopEndPpq,
    timeSamples,
    timeSigNumerator,
    timeSigDenominator,
    hostFrames,
  );

  @override
  String toString() =>
      'Transport(playing: $isPlaying, time: $timeSeconds, bpm: $bpm)';
}
