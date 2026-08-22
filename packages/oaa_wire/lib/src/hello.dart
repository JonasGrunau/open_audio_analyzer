// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'package:oaa_core/oaa_core.dart';

import 'frame.dart';
import 'snapshot_codec.dart';

/// The `0x0001 HELLO` frame: what a producer says about itself before it says
/// anything about the signal.
///
/// Its whole job is to make an incompatible pair of builds fail at connect
/// time, with a sentence a human can act on, rather than at draw time with a
/// picture that looks fine. Everything in it is a number that decides *what a
/// byte means* — how long a snapshot is, how many bands are in it — and a
/// display that guesses at one of those does not crash. It draws half a
/// spectrum stretched across the full width, or a channel's peak in the next
/// channel's meter, and somebody makes a delivery decision from it.
class WireHello {
  WireHello({
    required this.snapshotPayloadBytes,
    required this.abiVersion,
    required this.maxChannels,
    required this.spectrumBands,
    required this.scopePoints,
    required this.histogramBins,
    required this.producerName,
    this.protocolVersion = WireFrame.protocolVersion,
  });

  /// What this build would send.
  factory WireHello.local({
    required int abiVersion,
    required String producerName,
  }) => WireHello(
    snapshotPayloadBytes: SnapshotWire.payloadBytes,
    abiVersion: abiVersion,
    maxChannels: MeterShape.maxChannels,
    spectrumBands: MeterShape.spectrumBands,
    scopePoints: MeterShape.scopePoints,
    histogramBins: MeterShape.histogramBins,
    producerName: producerName,
  );

  final int protocolVersion;
  final int snapshotPayloadBytes;

  /// `OAA_ABI_VERSION` of the producer. Informational — see [incompatibility].
  final int abiVersion;

  final int maxChannels;
  final int spectrumBands;
  final int scopePoints;
  final int histogramBins;

  /// What to show a human: the host's name, not its address.
  final String producerName;

  static const int _fixedBytes = 32;

  Uint8List encodeFrame() {
    final name = utf8.encode(producerName);
    final payload = Uint8List(_fixedBytes + name.length);
    final view = ByteData.view(payload.buffer);

    view.setUint16(0, protocolVersion, Endian.little);
    view.setUint16(2, 0, Endian.little); // flags, reserved
    view.setUint32(4, snapshotPayloadBytes, Endian.little);
    view.setUint32(8, abiVersion, Endian.little);
    view.setUint32(12, maxChannels, Endian.little);
    view.setUint32(16, spectrumBands, Endian.little);
    view.setUint32(20, scopePoints, Endian.little);
    view.setUint32(24, histogramBins, Endian.little);
    view.setUint32(28, name.length, Endian.little);
    payload.setRange(_fixedBytes, _fixedBytes + name.length, name);

    return WireFrame.encode(WireFrameType.hello, payload);
  }

  static WireHello decode(ByteData payload) {
    if (payload.lengthInBytes < _fixedBytes) {
      throw WireFormatException(
        'hello frame is ${payload.lengthInBytes} bytes, expected at least '
        '$_fixedBytes',
      );
    }

    final nameLength = payload.getUint32(28, Endian.little);
    if (_fixedBytes + nameLength > payload.lengthInBytes) {
      throw WireFormatException('hello frame claims a name past its end');
    }

    return WireHello(
      protocolVersion: payload.getUint16(0, Endian.little),
      snapshotPayloadBytes: payload.getUint32(4, Endian.little),
      abiVersion: payload.getUint32(8, Endian.little),
      maxChannels: payload.getUint32(12, Endian.little),
      spectrumBands: payload.getUint32(16, Endian.little),
      scopePoints: payload.getUint32(20, Endian.little),
      histogramBins: payload.getUint32(24, Endian.little),
      // **`allowMalformed` is deliberate, and it stays.** It looks like the lax
      // choice and is the useful one: a producer name is a label, not a
      // measurement, so showing exactly what arrived is both the honest
      // rendering and — as it turned out — the diagnostic.
      //
      // The plugin once built this field with `juce::String`'s `const char*`
      // constructor, which reads one byte per codepoint, so an em dash went on
      // the wire as six bytes instead of three. Decoding faithfully put
      // `Open Audio Analyzer plugin â<80><94>` in the application's title bar,
      // where a person saw it within a minute. Hardened to refuse — reject the
      // frame, or blank the name — the plugin would have connected, metered
      // correctly and shown a nameless producer, and the encoding fault would
      // have stayed invisible for as long as nobody read the bytes.
      //
      // Refusing is right for anything the display *computes* from. Nothing is
      // computed from this.
      producerName: utf8.decode(
        Uint8List.view(
          payload.buffer,
          payload.offsetInBytes + _fixedBytes,
          nameLength,
        ),
        allowMalformed: true,
      ),
    );
  }

  /// Why this build cannot draw this producer's frames, or null if it can.
  ///
  /// The producer's ABI version is deliberately **not** checked. A host at ABI
  /// 4 and a display at ABI 3 whose snapshot layout is identical must be
  /// allowed to talk — refusing a link that would have worked perfectly is its
  /// own kind of wrong answer, and the payload size below is what actually
  /// catches a layout that moved.
  String? get incompatibility {
    // A version this build knows is a version it can decode, and that includes
    // one *older* than its own: version 3 added a frame type and moved no
    // table, so every table a version-2 producer sends is a table this build
    // froze unchanged.
    //
    // Equality here was survivable while the only producer was the app itself,
    // shipped as one binary with the display. It stopped being survivable when
    // the producer became a plugin: a plugin lives in the DAW's own folder and
    // stays there across app upgrades, so an app one version ahead of the
    // plugin somebody installed months ago is the ordinary case. Under equality
    // the first app to speak 3 would have refused every plugin already
    // installed — and what that looks like from the plugin is a port that
    // accepts and immediately hangs up, forever, which is indistinguishable
    // from the defect where the port was never bound at all.
    //
    // What must *not* happen is the reverse: a producer newer than this build
    // may have moved a table underneath us, and misreading a measurement table
    // is how a meter draws a confident wrong number.
    if (!WireFrame.isKnownVersion(protocolVersion)) {
      return 'The host speaks wire protocol $protocolVersion and this display '
          'speaks ${WireFrame.minimumVersion}-${WireFrame.protocolVersion}.';
    }
    // Two sizes are legal, and for the same reason the version range is: this
    // build writes the version 4 table and can read the one versions 1 to 3
    // froze, so an older plugin is a producer it understands rather than one it
    // hangs up on. Anything else is a table nobody here has seen.
    if (snapshotPayloadBytes != SnapshotWire.payloadBytes &&
        snapshotPayloadBytes != SnapshotWireLegacy.payloadBytes) {
      return 'The host sends $snapshotPayloadBytes-byte measurements and this '
          'display expects ${SnapshotWire.payloadBytes} or '
          '${SnapshotWireLegacy.payloadBytes}.';
    }
    if (maxChannels != MeterShape.maxChannels ||
        spectrumBands != MeterShape.spectrumBands ||
        scopePoints != MeterShape.scopePoints ||
        histogramBins != MeterShape.histogramBins) {
      return 'The host and this display disagree about the shape of a '
          'measurement: $maxChannels/$spectrumBands/$scopePoints/'
          '$histogramBins against ${MeterShape.maxChannels}/'
          '${MeterShape.spectrumBands}/${MeterShape.scopePoints}/'
          '${MeterShape.histogramBins}.';
    }
    return null;
  }
}
