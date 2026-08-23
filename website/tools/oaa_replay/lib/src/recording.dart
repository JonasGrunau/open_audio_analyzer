// SPDX-License-Identifier: GPL-3.0-or-later

/// A recording, in memory: the planes, and how to read a frame out of them.
library;

import 'dart:typed_data';

import 'format.dart';

/// One decoded recording.
///
/// The bytes are kept as they are on disk — quantised, and for the spectrum
/// arrays delta-coded — and a frame is gathered on demand. Gathering a spectrum
/// is one pass over 512 contiguous bytes accumulating the delta, which is the
/// same walk the dequantisation needs anyway; nothing is unpacked in advance,
/// so the recording sits in memory at its file size rather than at eight times
/// it. See `format.dart` for why the layout is what it is.
class Recording {
  Recording._({
    required this.header,
    required Float32List scalars,
    required Float32List channelPeak,
    required Float32List channelRms,
    required Float32List channelVu,
    required Uint16List channelClip,
    required Uint8List spectrum,
    required Uint8List spectrumPeak,
    required Uint8List spectrumPan,
    required Uint16List histogram,
  }) : _scalars = scalars,
       _channelPeak = channelPeak,
       _channelRms = channelRms,
       _channelVu = channelVu,
       _channelClip = channelClip,
       _spectrum = spectrum,
       _spectrumPeak = spectrumPeak,
       _spectrumPan = spectrumPan,
       _histogram = histogram;

  final RecordingHeader header;

  // The small series are series-major, `[series][frames]`: one quantity's whole
  // timeline at a time.
  final Float32List _scalars;
  final Float32List _channelPeak;
  final Float32List _channelRms;
  final Float32List _channelVu;
  final Uint16List _channelClip;

  // The spectrum arrays are frame-major, `[frames][bands]`, each frame delta-
  // coded along the bands.
  final Uint8List _spectrum;
  final Uint8List _spectrumPeak;
  final Uint8List _spectrumPan;

  final Uint16List _histogram;

  int get frames => header.frames;
  double get seconds => header.seconds;

  /// Read [bytes], which is the file exactly as `oaa_record` wrote it.
  factory Recording.parse(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final header = RecordingHeader.decode(data);
    final frames = header.frames;
    final channels = header.channels;

    var offset = RecordingHeader.bytes;

    Float32List floats(int series) {
      final count = series * frames;
      // A copy rather than a view: the byte offset of a plane is only
      // guaranteed to be 4-aligned if every plane before it happens to be, and
      // `asFloat32List` on an unaligned offset throws on some platforms and
      // silently misreads on none of them, which is worse to debug than a copy
      // that costs a millisecond.
      final out = Float32List(count);
      for (var i = 0; i < count; i++) {
        out[i] = data.getFloat32(offset + i * 4, Endian.little);
      }
      offset += count * 4;
      return out;
    }

    Uint16List uint16s(int series) {
      final count = series * frames;
      final out = Uint16List(count);
      for (var i = 0; i < count; i++) {
        out[i] = data.getUint16(offset + i * 2, Endian.little);
      }
      offset += count * 2;
      return out;
    }

    Uint8List bytesFor(int series) {
      final count = series * frames;
      final out = Uint8List.sublistView(bytes, offset, offset + count);
      offset += count;
      return out;
    }

    final scalars = floats(Scalar.count);
    final peak = floats(channels);
    final rms = floats(channels);
    final vu = floats(channels);
    final clip = header.has(RecordingParts.clip)
        ? uint16s(channels)
        : Uint16List(0);
    final spectrum = header.has(RecordingParts.spectrum)
        ? bytesFor(header.spectrumBands)
        : Uint8List(0);
    final spectrumPeak = header.has(RecordingParts.spectrumPeak)
        ? bytesFor(header.spectrumBands)
        : Uint8List(0);
    final spectrumPan = header.has(RecordingParts.spectrumPan)
        ? bytesFor(header.spectrumBands)
        : Uint8List(0);
    final histogram = header.has(RecordingParts.histogram)
        ? uint16s(header.histogramBins)
        : Uint16List(0);

    return Recording._(
      header: header,
      scalars: scalars,
      channelPeak: peak,
      channelRms: rms,
      channelVu: vu,
      channelClip: clip,
      spectrum: spectrum,
      spectrumPeak: spectrumPeak,
      spectrumPan: spectrumPan,
      histogram: histogram,
    );
  }

  /// The frame covering [seconds] of programme, clamped to the recording.
  int frameAt(double seconds) {
    final index = (seconds * header.fps).floor();
    if (index < 0) return 0;
    if (index >= frames) return frames - 1;
    return index;
  }

  double scalar(Scalar which, int frame) =>
      _scalars[which.index * frames + frame];

  double channel(_ChannelPlane plane, int channel, int frame) =>
      switch (plane) {
        _ChannelPlane.peak => _channelPeak[channel * frames + frame],
        _ChannelPlane.rms => _channelRms[channel * frames + frame],
        _ChannelPlane.vu => _channelVu[channel * frames + frame],
      };

  int clipAt(int channel, int frame) =>
      _channelClip.isEmpty ? 0 : _channelClip[channel * frames + frame];

  /// Fill [into] with the spectrum at [frame], in dBFS.
  void readSpectrum(Float32List into, int frame) =>
      _readDbPlane(_spectrum, into, frame);

  void readSpectrumPeak(Float32List into, int frame) =>
      _readDbPlane(_spectrumPeak, into, frame);

  /// Per-band stereo position, −1..+1. Stored as an unsigned byte around 128
  /// so that it delta-codes with the same code path as the two dB planes.
  void readSpectrumPan(Float32List into, int frame) {
    if (_spectrumPan.isEmpty) {
      into.fillRange(0, into.length, double.nan);
      return;
    }
    final bands = header.spectrumBands;
    final base = frame * bands;
    var previous = 0;
    for (var band = 0; band < bands; band++) {
      previous = (previous + _spectrumPan[base + band]) & 0xFF;
      if (band < into.length) into[band] = (previous - 128) / 127.0;
    }
  }

  void readHistogram(Float32List into, int frame) {
    if (_histogram.isEmpty) {
      into.fillRange(0, into.length, 0.0);
      return;
    }
    final bins = header.histogramBins;
    for (var bin = 0; bin < bins && bin < into.length; bin++) {
      into[bin] = _histogram[bin * frames + frame] / 65535.0;
    }
  }

  /// One frame's bands: contiguous, and delta-coded low band first, so this is
  /// a single accumulating pass rather than 512 strided reads.
  void _readDbPlane(Uint8List plane, Float32List into, int frame) {
    if (plane.isEmpty) {
      into.fillRange(0, into.length, double.nan);
      return;
    }
    final bands = header.spectrumBands;
    final base = frame * bands;
    var previous = 0;
    for (var band = 0; band < bands; band++) {
      previous = (previous + plane[base + band]) & 0xFF;
      if (band < into.length) into[band] = dequantiseDb(previous);
    }
  }
}

enum _ChannelPlane { peak, rms, vu }

/// Named so the source below reads as prose rather than as an enum index.
const channelPeakPlane = _ChannelPlane.peak;
const channelRmsPlane = _ChannelPlane.rms;
const channelVuPlane = _ChannelPlane.vu;
