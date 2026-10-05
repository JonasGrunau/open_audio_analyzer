// SPDX-License-Identifier: GPL-3.0-or-later
//
// A `MeterSource` a test can move by hand: bump [FakeSource.generation] and the
// host publishes a new snapshot. Shared by the suites that run a real
// `DisplayHost` — over a socket, and over a USB relay.

import 'dart:typed_data';

import 'package:oaa_core/oaa_core.dart';

class FakeSource implements MeterSource {
  @override
  Transport transport = Transport.none;

  @override
  int generation = 0;

  @override
  double elapsedSeconds = 0;

  @override
  int sampleRate = 48000;

  @override
  int channels = 2;

  @override
  bool isRunning = false;

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
  int scopeFrames = MeterShape.scopePoints;

  @override
  final Float32List histogram = Float32List(MeterShape.histogramBins);

  @override
  bool refresh() => true;
}
