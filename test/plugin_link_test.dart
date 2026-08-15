// SPDX-License-Identifier: GPL-3.0-or-later
//
// The desktop end of the plugin link, driven by bytes the plugin actually
// produced.
//
// The fixture read here is written by `plugin/test/wire_fixture.cpp`, compiled
// from the same source the VST3 uses. So this is not a test of the app against
// its own idea of the protocol — it is the app against the plugin's output,
// which is the only arrangement that catches the two drifting apart.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:bel/src/plugin/plugin_link.dart';

Future<Uint8List> _goldenFrames() =>
    File('plugin/test/golden/wire_v1.bin').readAsBytes();

/// Waits for [condition], failing the test rather than hanging forever.
///
/// Socket delivery is asynchronous and chunked, so there is no single future to
/// await — the frames arrive when they arrive. Polling with a deadline is the
/// honest way to express "shortly", and a test that hangs is far worse than one
/// that fails.
Future<void> _eventually(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition was still false after $timeout.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late PluginLink link;
  late Uint8List frames;

  setUpAll(() async => frames = await _goldenFrames());

  setUp(() async {
    // Port 0 asks the OS for a free one. Binding the real 47822 would make the
    // suite fail whenever the developer happens to have Bel open, which is
    // exactly when they are most likely to be running it.
    link = PluginLink(port: 0);
    await link.start();
  });

  tearDown(() async {
    await link.stop();
    link.dispose();
  });

  test('listens, and says so', () {
    expect(link.isListening, isTrue);
    expect(link.failure.value, isNull);
    expect(link.boundPort, isNotNull);
    expect(link.sessions, isEmpty);
    expect(link.active, isNull);
  });

  test('accepts a plugin and decodes what it sends', () async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      link.boundPort!,
    );
    addTearDown(socket.destroy);

    socket.add(frames);
    await socket.flush();

    await _eventually(
      () => link.active?.snapshot.generation == 0x0123456789ABCDEF,
    );

    final session = link.active!;
    expect(session.producerName, 'Bel plugin — fixture');
    expect(session.abiVersion, isNotNull);

    // The measurements the app will draw.
    expect(session.snapshot.sampleRate, 48000);
    expect(session.snapshot.channels, 2);
    expect(session.snapshot.lufsIntegrated, closeTo(-14.0, 1e-5));

    // Unmeasured stays unmeasured all the way through the socket.
    expect(session.snapshot.lufsMomentary.isNaN, isTrue);
    expect(session.snapshot.truePeak, double.negativeInfinity);

    // And the transport, which is the whole reason this link exists rather
    // than the app simply metering its own input.
    expect(session.transport.isPlaying, isTrue);
    expect(session.transport.hasTimecode, isTrue);
    expect(session.transport.timecode, '01:01:01;15');
    expect(session.transport.bpm, closeTo(120.0, 1e-9));
  });

  test('a frame split across chunks is reassembled', () async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      link.boundPort!,
    );
    addTearDown(socket.destroy);

    // TCP is a stream, not a message queue. A 15 kB snapshot will not arrive in
    // one piece on any real network, and a reader that assumed it did would
    // work perfectly over loopback and fail the moment a tablet was involved.
    // Deliberately awkward boundaries: mid-envelope, mid-payload.
    for (var offset = 0; offset < frames.length; offset += 7) {
      socket.add(frames.sublist(offset, (offset + 7).clamp(0, frames.length)));
    }
    await socket.flush();

    await _eventually(
      () => link.active?.snapshot.generation == 0x0123456789ABCDEF,
    );
    expect(link.active!.transport.timecode, '01:01:01;15');
  });

  test('the most recently connected plugin becomes the active one', () async {
    final first = await Socket.connect(
      InternetAddress.loopbackIPv4,
      link.boundPort!,
    );
    addTearDown(first.destroy);
    await _eventually(() => link.sessions.length == 1);
    final firstSession = link.active;

    final second = await Socket.connect(
      InternetAddress.loopbackIPv4,
      link.boundPort!,
    );
    addTearDown(second.destroy);
    await _eventually(() => link.sessions.length == 2);

    // Inserting a plugin is itself the selection: the one somebody just placed
    // is the one they want to look at.
    expect(link.active, isNot(same(firstSession)));
    expect(link.sessions.length, 2);
  });

  test('a disconnecting plugin hands the selection back', () async {
    final first = await Socket.connect(
      InternetAddress.loopbackIPv4,
      link.boundPort!,
    );
    addTearDown(first.destroy);
    await _eventually(() => link.sessions.length == 1);
    final firstSession = link.active;

    final second = await Socket.connect(
      InternetAddress.loopbackIPv4,
      link.boundPort!,
    );
    await _eventually(() => link.sessions.length == 2);

    await second.close();
    second.destroy();

    await _eventually(() => link.sessions.length == 1);
    expect(link.active, same(firstSession));
  });

  test('measurements go stale rather than freezing when frames stop', () async {
    // A plugin whose DAW is idle still sends frames; silence means the link is
    // gone. A meter that simply held its last value would be indistinguishable
    // from a quiet passage, and somebody would read a delivery decision off a
    // picture of the past.
    final quick = PluginLink(
      port: 0,
      staleAfter: const Duration(milliseconds: 80),
    );
    await quick.start();
    addTearDown(() async {
      await quick.stop();
      quick.dispose();
    });

    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      quick.boundPort!,
    );
    addTearDown(socket.destroy);

    socket.add(frames);
    await socket.flush();
    await _eventually(() => quick.active?.snapshot.isStale == false);

    await _eventually(() => quick.active?.snapshot.isStale == true);
  });

  test('a plugin talking nonsense is dropped, not drawn', () async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      link.boundPort!,
    );
    addTearDown(socket.destroy);

    // A valid envelope claiming a payload far larger than any real frame. The
    // reader must refuse it rather than allocate what it was told to.
    final hostile = Uint8List(12);
    ByteData.view(hostile.buffer)
      ..setUint32(0, 0x574C4542, Endian.little)
      ..setUint16(4, 1, Endian.little)
      ..setUint16(6, 0x0003, Endian.little)
      ..setUint32(8, 0x7FFFFFFF, Endian.little);

    socket.add(hostile);
    await socket.flush();

    await _eventually(() => link.sessions.isEmpty);
    expect(link.active, isNull);
  });
}
