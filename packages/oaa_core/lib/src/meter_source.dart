// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'transport.dart';

/// The shape of one published measurement, as counts rather than bytes.
///
/// These mirror `OAA_MAX_CHANNELS` and friends in `engine/include/oaa/oaa.h`,
/// and they are restated here because the two things that need them most cannot
/// see that header: `oaa_wire`, which has to size its buffers without linking a
/// native library, and the remote display, which has no engine at all.
///
/// Restating a constant is how two components quietly come to disagree, so this
/// is guarded rather than trusted — `test/wire_test.dart` asserts every value
/// here against the `oaa_engine` constant it mirrors. If somebody widens the
/// spectrum to 1024 bands and forgets this file, that test fails; without it,
/// the remote display would decode 512 bands out of a 1024-band frame and draw
/// the bottom half of the spectrum stretched across the whole width, which is a
/// picture that looks entirely plausible and is wrong.
abstract final class MeterShape {
  /// Widest channel layout carried, 7.1.
  static const int maxChannels = 8;

  /// Log-spaced spectrum bands published for drawing.
  static const int spectrumBands = 512;

  /// Stereo sample pairs one analysis block carries — the engine's own block
  /// size, so a snapshot straight off an engine always holds exactly this many.
  static const int scopePoints = 1024;

  /// The most stereo pairs a *transported* snapshot may carry.
  ///
  /// A remote display publishes at 15, 30 or 60 Hz while the engine measures at
  /// about 47, so one transported frame may have to carry several blocks of
  /// audio if the waveform is to stay contiguous — see [MeterSource.scopeFrames]
  /// for what goes wrong when it does not. 4,096 covers 48 kHz at the slowest
  /// link rate (3,200 pairs) with headroom; past that the run is truncated and
  /// the consumer is told, which it can draw honestly as a gap.
  static const int maxScopeFrames = 4096;

  /// Bins in the published short-term loudness distribution, and the range in
  /// LUFS they span.
  static const int histogramBins = 120;
  static const double histogramMinLufs = -60.0;
  static const double histogramMaxLufs = 0.0;

  /// The floor every dB reading clamps to.
  static const double dbFloor = -144.0;

  /// The frequency range the spectrum bands span, log-spaced, at every sample
  /// rate.
  static const double spectrumHzLow = 20.0;
  static const double spectrumHzHigh = 20000.0;
}

/// Something a meter can read a measurement out of.
///
/// This exists because Open Audio Analyzer has two of them and they have
/// nothing in common underneath. On the desktop the source is `OaaEngine`, and
/// every array below is a window onto memory a C analysis thread owns. On the
/// tablet there is no engine, no native library doing any work and no audio
/// device — the numbers arrive over a socket and land in ordinary Dart lists.
/// Between those two the fourteen modules are *identical*, and they have to be:
/// a remote display whose meters were written a second time is a remote display
/// that will eventually disagree with the desktop about what the signal did,
/// and then neither reading can be trusted.
///
/// So the modules are written against this and nothing else, and the two
/// implementations meet the same contract:
///
///   - **The arrays are read-only and their identity is stable.** A painter may
///     hold one from build to build and hand it straight to
///     `Canvas.drawRawPoints` or `Vertices.raw`. Returning a fresh list per call
///     would put an allocation on the paint path, which is the one thing this
///     architecture exists to prevent — so an implementation refreshes the
///     *contents* of its arrays and never swaps the objects.
///   - **A value that was not measured is NaN, never zero.** Zero is a real
///     reading for correlation, balance and several dB quantities. Anything
///     that cannot produce a number — a build without the measurement, a link
///     that has gone quiet — reports NaN, and the UI renders an em dash.
///   - **[refresh] is the only method on the frame path**, called once per tick
///     by the single `MeterClock`, before anything paints.
///
/// Deliberately *not* on this interface: starting, stopping, resetting, picking
/// a device, pushing audio. A source is a thing you read. The remote display can
/// do none of those and pretending otherwise would give every module a set of
/// controls that silently do nothing on half the platforms.
abstract interface class MeterSource {
  /// Take the newest published measurement, and report whether it is new.
  ///
  /// Returns false when nothing has been published since the last call, which
  /// is the caller's cue to skip the repaint entirely. That case is the common
  /// one and not an edge case: the engine publishes at about 47 Hz against a
  /// display asking 60 or 120 times a second.
  bool refresh();

  /// Increments once per published measurement. Two readings taken from the
  /// same generation are guaranteed to describe the same instant.
  int get generation;

  // --- What the signal is ---------------------------------------------------

  /// Sample rate actually in use. Zero before a source has settled on one.
  int get sampleRate;

  /// Channels actually in use, 1..[MeterShape.maxChannels].
  int get channels;

  /// Seconds of *signal* measured since the last reset — not wall-clock time.
  double get elapsedSeconds;

  /// Whether measurement is under way. A stopped desktop engine and a remote
  /// link that has gone quiet both report false.
  bool get isRunning;

  /// The playhead of the DAW behind this source, or [Transport.none].
  ///
  /// **On the interface rather than beside it, because a module cannot be
  /// handed anything else.** The oscilloscope's tempo sync needs to know where
  /// the bar line is, and the rule in `CLAUDE.md` is that a module reads a
  /// [MeterSource] and never a concrete engine — so a display that needs the
  /// playhead widens this rather than growing a second path to it. The
  /// alternative was a callback threaded through the canvas, which the tablet
  /// would not have had: it runs the same fourteen modules over a socket.
  ///
  /// [Transport.none] is the honest answer for a sound card, and for a DAW that
  /// never says. Every field behind it has a presence bit — see [Transport] —
  /// because a tempo of 0.0 is indistinguishable from a real one and a bar
  /// counter that starts at 1 while the host is parked at bar 57 is exactly the
  /// invented measurement this project forbids.
  Transport get transport;

  // --- Whether the numbers can be trusted -----------------------------------

  /// Frames of audio lost since the last reset.
  ///
  /// Not a diagnostic counter: integrated loudness averages every block since
  /// the reset, so a dropped second does not make the reading slightly stale,
  /// it makes it an average of a different programme than the one that played.
  int get droppedFrames;

  /// Sticky once any audio has been lost. The UI has to say so rather than
  /// quietly showing an integrated reading taken over a gap.
  bool get hasOverrun;

  /// Whether this source computes the loudness family at all.
  bool get hasLoudness;

  /// Whether this source computes the spectrum arrays at all.
  bool get hasSpectrum;

  // --- Loudness, ITU-R BS.1770-4 / EBU R128, LUFS ---------------------------

  double get lufsMomentary;
  double get lufsShort;
  double get lufsIntegrated;

  /// Loudness range, LU.
  double get loudnessRange;

  /// The two percentiles [loudnessRange] is the difference of, and the relative
  /// gate they were taken above. NaN together with it.
  double get loudnessRangeLow;
  double get loudnessRangeHigh;
  double get loudnessRangeGate;

  // --- Peaks ----------------------------------------------------------------

  /// True peak over a 3 s sliding window, dBTP.
  double get truePeak;

  /// True peak since the last reset, dBTP.
  double get truePeakMax;

  /// Sample peak since the last reset, dBFS.
  double get samplePeakMax;

  // --- Dynamics -------------------------------------------------------------

  double get dynamicRangeShort;
  double get dynamicRangeIntegrated;
  double get crestFactor;
  double get peakToLoudnessRatio;
  double get peakToShortTermRatio;

  // --- Stereo field ---------------------------------------------------------

  /// −1 fully out of phase, +1 mono.
  double get correlation;

  /// −1 hard left, +1 hard right.
  double get balance;

  // --- Per channel, [MeterShape.maxChannels] long ---------------------------

  /// Peak, dBFS, with the meter's hold applied.
  Float32List get peak;

  /// RMS, dBFS, with the meter's decay applied.
  Float32List get rms;

  /// VU deflection. **0 VU is not 0 dBFS** — the reference level belongs to the
  /// calibration, so the offset is applied where the meter is drawn.
  Float32List get vu;

  /// Consecutive full-scale samples seen, per channel.
  Uint32List get clip;

  // --- Arrays ---------------------------------------------------------------

  /// Magnitudes, dBFS per log-spaced band,
  /// [MeterShape.spectrumBands] long.
  Float32List get spectrum;

  /// Per-band peak hold for [spectrum]. Held by the source rather than
  /// accumulated by the painter: a transform runs every hop but a publish
  /// carries only the last one, so a hold computed from what reaches the UI
  /// would miss every transient that landed between two publishes.
  Float32List get spectrumPeak;

  /// Per-band stereo position, −1 left to +1 right. Meaningless for a band with
  /// no energy in it — read [spectrum] first and skip bands at
  /// [MeterShape.dbFloor], because the pan of silence is not a direction.
  Float32List get spectrumPan;

  /// Stereo frames, interleaved x=left, y=right, oldest first, of which the
  /// first [scopeFrames] pairs are valid. Raw sample values, not rotated into
  /// goniometer axes — that rotation is a display choice and belongs in the
  /// painter's transform, where it costs nothing.
  ///
  /// **Read [scopeFrames], never `scope.length`.** The list is allocated once
  /// at its largest and only partly filled; the rest is whatever the previous
  /// frame left there.
  Float32List get scope;

  /// How many stereo pairs of [scope] are this measurement's.
  ///
  /// Always [MeterShape.scopePoints] from an engine, because a snapshot is
  /// published once per analysis block and that block is exactly that long. It
  /// varies over a wire, and the reason is the one thing about this interface
  /// worth reading twice.
  ///
  /// A remote display's link runs at 15, 30 or 60 Hz and the engine measures at
  /// about 47, so at the default 30 Hz a frame stands for 1,600 frames of audio
  /// at 48 kHz while one block carries 1,024. A transport that sent the newest
  /// block regardless would hand the oscilloscope 64 % of the waveform and no
  /// way to know it — and the module, which computes how much audio arrived
  /// from `elapsedSeconds`, would correctly conclude the ring was no longer
  /// contiguous and reset it. Every tick. So the host accumulates what it
  /// measured between two sends and this says how much of it there is.
  ///
  /// Never more than [MeterShape.maxScopeFrames]. A consumer that finds less
  /// audio here than elapsed knows a gap is real rather than assuming one.
  int get scopeFrames;

  /// Fraction of the gated short-term blocks in each of
  /// [MeterShape.histogramBins] bins. Sums to 1, or to 0 before anything is
  /// measured.
  Float32List get histogram;
}
