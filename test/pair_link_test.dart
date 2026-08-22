// SPDX-License-Identifier: GPL-3.0-or-later
//
// The one parser that stands behind both the typed address and the camera.
//
// It is one file so that the field and the scanner cannot come to differ about
// what a bare host name means, and this suite is what holds that: every case
// below is asked of `PairLink.parse` without saying which of the two asked it,
// because neither is allowed an answer of its own.

import 'package:oaa/src/remote/display_host.dart';
import 'package:oaa/src/remote/pair_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('what a code carries', () {
    test('an address and a port, under the scheme', () {
      expect(PairLink.format('192.168.1.20', 5555), 'oaa://192.168.1.20:5555');
    });

    // Otherwise `fe80::1:5555` is a v6 literal whose last group happens to be
    // 5555, and the port is gone.
    test('an IPv6 literal is bracketed so the port survives it', () {
      expect(
        PairLink.format('fe80::1c2d:3e4f', 5555),
        'oaa://[fe80::1c2d:3e4f]:5555',
      );
      expect(PairLink.format('[fe80::1]', 5555), 'oaa://[fe80::1]:5555');
    });

    test('what it writes is what it reads', () {
      for (final (address, port) in const [
        ('192.168.1.20', 5555),
        ('10.0.0.2', 47000),
        ('studio-mac.local', 5555),
        ('fe80::1c2d:3e4f', 5555),
      ]) {
        final link = PairLink.parse(PairLink.format(address, port));
        expect(link?.host, address, reason: PairLink.format(address, port));
        expect(link?.port, port);
      }
    });
  });

  group('what it accepts', () {
    test('a code this application wrote', () {
      final link = PairLink.parse('oaa://192.168.1.20:5555');
      expect(link?.host, '192.168.1.20');
      expect(link?.port, 5555);
    });

    // The scheme is matched without regard to case because a URI's scheme is
    // case-insensitive, and a code somebody re-encoded by hand may well shout.
    test('the scheme in any case, with or without a trailing path', () {
      for (final text in const [
        'OAA://192.168.1.20:5555',
        'Oaa://192.168.1.20:5555/',
        'oaa://192.168.1.20:5555/anything',
      ]) {
        expect(PairLink.parse(text)?.host, '192.168.1.20', reason: text);
        expect(PairLink.parse(text)?.port, 5555, reason: text);
      }
    });

    // Nobody types a scheme into a field labelled Host, and the field and the
    // scanner share this parser.
    test('a bare address, with the default port', () {
      expect(PairLink.parse('192.168.1.20'), (
        host: '192.168.1.20',
        port: DisplayHost.defaultPort,
      ));
      expect(PairLink.parse('  studio-mac.local  '), (
        host: 'studio-mac.local',
        port: DisplayHost.defaultPort,
      ));
    });

    test('a bracketed IPv6 literal, and the brackets come off', () {
      expect(PairLink.parse('[fe80::1]:5555'), (host: 'fe80::1', port: 5555));
      expect(PairLink.parse('[fe80::1]'), (
        host: 'fe80::1',
        port: DisplayHost.defaultPort,
      ));
    });

    // An unbracketed literal cannot be told from a host and a port, so the
    // last colon is not treated as one: `fe80::1` keeps all of itself and
    // takes the default. Connecting to `fe80:` on port 1 is the alternative.
    test('an unbracketed IPv6 literal keeps its last group', () {
      expect(PairLink.parse('fe80::1')?.port, DisplayHost.defaultPort);
    });

    test('a zone on a link-local literal survives', () {
      expect(PairLink.parse('[fe80::1%en0]:5555'), (
        host: 'fe80::1%en0',
        port: 5555,
      ));
    });
  });

  group('what it refuses', () {
    test('nothing at all', () {
      expect(PairLink.parse(''), isNull);
      expect(PairLink.parse('   '), isNull);
      expect(PairLink.parse('oaa://'), isNull);
      expect(PairLink.parse('oaa:///path'), isNull);
    });

    // Somebody who meant a port and mistyped it. Keeping the whole string as a
    // host name turns that into a name lookup that fails several seconds later
    // for a reason nobody can read.
    test('a port that is not a port', () {
      expect(PairLink.parse('192.168.1.20:70000'), isNull);
      expect(PairLink.parse('192.168.1.20:0'), isNull);
      expect(PairLink.parse('192.168.1.20:'), isNull);
      expect(PairLink.parse('192.168.1.20:port'), isNull);
    });

    // Neither is an unbracketed literal with something after it: `fe80::1:5555`
    // is a whole address whose last group happens to look like a port, and
    // there is no way to tell the two apart. Bracketing is how somebody says
    // which they meant, in this reader and in every other.
    test('an unbracketed literal with a port on the end', () {
      expect(PairLink.parse('[fe80::1]:5555')?.port, 5555);
      expect(PairLink.parse('fe80::1:5555')?.port, DisplayHost.defaultPort);
      expect(PairLink.parse('fe80::1:5555')?.host, 'fe80::1:5555');
    });

    // The whole reason the scheme is there. A camera reads what is in front of
    // it, and a studio wall has other codes on it — the point is that this
    // panel says "that is not an Open Audio Analyzer address" rather than
    // opening a socket to a host called `WIFI`.
    test('somebody else’s QR code', () {
      for (final text in const [
        'https://example.com/thing',
        'http://192.168.1.20:5555',
        'WIFI:S:Studio;T:WPA;P:hunter2;;',
        'mailto:someone@example.com',
      ]) {
        expect(PairLink.parse(text), isNull, reason: text);
      }
    });
  });
}
