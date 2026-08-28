// SPDX-License-Identifier: GPL-3.0-or-later
//
// The material the benchmarks measure, and the one path they all drive.
//
// ---------------------------------------------------------------------------
// Why this is shared, and why it does not write bytes by hand
//
// Each benchmark used to build a payload itself, writing fields at the offsets
// it believed the protocol had. That is a second implementation of the wire,
// and it drifted the moment protocol version 4 made five arrays fixed point:
// the harness went on writing float32 into `u16` slots, overran the payload,
// and the app it was measuring rendered an empty window while still reporting
// perfectly plausible frame times. A benchmark that quietly measures nothing is
// worse than no benchmark, so this drives `SnapshotWire.encode` — the real
// encoder — and decodes with the real decoder. There is no offset arithmetic
// here to be wrong.
//
// It is also the honest simulation of a remote display: encode, socket, decode,
// paint is exactly what a tablet does.
//
// The material is jagged on purpose. The engine takes the peak bin per band, so
// adjacent bands genuinely disagree, and smooth synthetic data flatters
// anything that coalesces runs — the mistake that made a spectrogram look six
// times cheaper than it was for a whole phase.

import 'dart:math';
import 'dart:typed_data';

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_wire/oaa_wire.dart';

/// The engine's real cadence: 1,024 frames a block at 48 kHz, so a measurement
/// every 21.3 ms and about 47 of them a second.
const int kBlockFrames = 1024;
const int kSampleRate = 48000;

/// Refills a measurement, encodes it the way a host does and decodes it into
/// the `WireSnapshot` a remote display holds.
class BenchMaterial {
  BenchMaterial() {
    publish();
  }

  final Random _random = Random(20260822);
  final _Source _source = _Source();

  /// What a tablet would be drawing from.
  final WireSnapshot snapshot = WireSnapshot();

  late final ByteData _payload = ByteData(SnapshotWire.payloadBytes);

  /// The encoded frame, for a benchmark that wants the codec on its own rather
  /// than the cost of inventing a measurement first.
  ByteData get payload => _payload;

  /// The measuring side, likewise.
  MeterSource get source => _source;

  void _band(Float32List into, double low, double high) {
    for (var i = 0; i < into.length; i++) {
      into[i] = low + _random.nextDouble() * (high - low);
    }
  }

  /// One analysis block of new material, through the real codec.
  void publish() {
    final s = _source;
    s.generation++;
    s.elapsedSeconds += kBlockFrames / kSampleRate;

    s.lufsMomentary = -14 + _random.nextDouble() * 4;
    s.lufsShort = -15 + _random.nextDouble() * 2;
    s.lufsIntegrated = -14.2;
    s.loudnessRange = 7.4;
    s.loudnessRangeLow = -18.1;
    s.loudnessRangeHigh = -10.7;
    s.loudnessRangeGate = -34.0;
    s.truePeak = -1.2 + _random.nextDouble();
    s.truePeakMax = -0.3;
    s.samplePeakMax = -0.6;
    s.crestFactor = 11.2;
    s.odrIntegrated = 13.9;
    s.odrShort = 9.1;
    s.correlation = 0.3 + _random.nextDouble() * 0.4;
    s.balance = -0.05 + _random.nextDouble() * 0.1;

    _band(s.peak, -12, -0.5);
    _band(s.rms, -24, -12);
    _band(s.vu, -8, 2);
    _band(s.spectrum, -84, -8);
    _band(s.spectrumPeak, -80, -6);
    _band(s.spectrumPan, -0.8, 0.8);
    _band(s.scope, -0.85, 0.85);
    _band(s.histogram, 0, 0.03);

    SnapshotWire.encode(s, _payload);
    snapshot.decode(_payload);
  }
}

/// A measurement nobody took, shaped like one somebody did.
class _Source implements MeterSource {
  @override
  Transport transport = Transport.none;

  @override
  int generation = 0;
  @override
  double elapsedSeconds = 0;
  @override
  int sampleRate = kSampleRate;
  @override
  int channels = 2;
  @override
  bool isRunning = true;
  @override
  int droppedFrames = 0;
  @override
  bool hasOverrun = false;
  @override
  bool hasLoudness = true;
  @override
  bool hasSpectrum = true;

  @override
  double lufsMomentary = double.nan;
  @override
  double lufsShort = double.nan;
  @override
  double lufsIntegrated = double.nan;
  @override
  double loudnessRange = double.nan;
  @override
  double loudnessRangeLow = double.nan;
  @override
  double loudnessRangeHigh = double.nan;
  @override
  double loudnessRangeGate = double.nan;
  @override
  double truePeak = double.nan;
  @override
  double truePeakMax = double.nan;
  @override
  double samplePeakMax = double.nan;
  @override
  double crestFactor = double.nan;
  @override
  double odrIntegrated = double.nan;
  @override
  double odrShort = double.nan;
  @override
  double correlation = double.nan;
  @override
  double balance = double.nan;

  @override
  final Float32List peak = Float32List(MeterShape.maxChannels);
  @override
  final Float32List rms = Float32List(MeterShape.maxChannels);
  @override
  final Float32List vu = Float32List(MeterShape.maxChannels);
  @override
  final Uint32List clip = Uint32List(MeterShape.maxChannels);
  @override
  final Float32List spectrum = Float32List(MeterShape.spectrumBands);
  @override
  final Float32List spectrumPeak = Float32List(MeterShape.spectrumBands);
  @override
  final Float32List spectrumPan = Float32List(MeterShape.spectrumBands);

  @override
  Float32List spectrumOf(SpectrumSource source) => spectrum;

  @override
  Float32List spectrumPeakOf(SpectrumSource source) => spectrumPeak;
  @override
  final Float32List scope = Float32List(MeterShape.scopePoints * 2);
  @override
  final Float32List histogram = Float32List(MeterShape.histogramBins);

  @override
  int get scopeFrames => MeterShape.scopePoints;

  @override
  bool refresh() => true;
}
