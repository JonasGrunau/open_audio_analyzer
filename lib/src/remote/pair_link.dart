// SPDX-License-Identifier: GPL-3.0-or-later

import 'display_host.dart';

/// Where to attach, as one line of text.
///
/// **One parser for the address somebody types and the one a camera reads**,
/// which is the whole reason this is a file rather than two private helpers.
/// The host picker's field and the QR scanner are the same question asked
/// twice, and two implementations of it would be two opinions about whether a
/// bare `studio-mac.local` means the default port — an answer a user discovers
/// by the tablet either connecting or not.
///
/// The code Open Audio Analyzer *writes* is always `oaa://host:port`, in full.
/// The scheme is not decoration: a QR code is read by whatever camera happens
/// to be pointed at it, so a payload has to say what it is. Without one, a
/// phone's own camera app offers to search the web for `192.168.1.20:5555`,
/// and this scanner cannot tell a pairing code from the Wi-Fi code taped to
/// the wall beside it — it would read `WIFI:S:Studio;T:WPA;…`, find a colon,
/// and try to open a socket to a host called `WIFI`.
///
/// What it *reads* is deliberately wider, because a person typing into the
/// field below the scanner is not going to type a scheme: a bare `host`,
/// `host:port`, or `[v6]:port` are all accepted, and anything carrying some
/// other scheme is refused rather than guessed at.
abstract final class PairLink {
  /// Not registered with IANA and never will be. It is here to be recognised
  /// by this application and ignored by everything else.
  static const String scheme = 'oaa';

  /// The text a pairing code carries for [address] on [port].
  static String format(String address, int port) =>
      '$scheme://${_bracket(address)}:$port';

  /// [text] as somewhere to connect to, or null if it is not one.
  ///
  /// The port defaults rather than being demanded, because almost nobody has
  /// changed it and asking for it turns a working default into a thing to get
  /// wrong.
  static ({String host, int port})? parse(String text) {
    var body = text.trim();
    if (body.isEmpty) return null;

    final prefix = '$scheme://';
    if (body.length > prefix.length &&
        body.substring(0, prefix.length).toLowerCase() == prefix) {
      body = body.substring(prefix.length);
      // A trailing slash, or a path nobody asked for. Version 1 of the
      // protocol has no notion of a path, so anything after the authority is
      // discarded rather than being carried somewhere it would be ignored.
      final slash = body.indexOf('/');
      if (slash >= 0) body = body.substring(0, slash);
    } else if (body.contains('://')) {
      // Somebody else's code. Refused rather than stripped: a URL is not an
      // address that happens to be dressed up, and connecting to the host part
      // of `https://example.com/x` is a guess with a two-second timeout on the
      // end of it.
      return null;
    }

    String host;
    String? tail;

    if (body.startsWith('[')) {
      // `[v6]` or `[v6]:port`. Brackets are for this parser's benefit, not the
      // socket's — `Socket.connect` wants the literal itself — so they come off
      // here.
      final close = body.indexOf(']');
      if (close < 1) return null;
      host = body.substring(1, close);
      tail = body.substring(close + 1);
      if (tail.isEmpty) {
        tail = null;
      } else if (tail.startsWith(':')) {
        tail = tail.substring(1);
      } else {
        return null;
      }
    } else {
      // **One colon is a port; two or more are an address.** An unbracketed
      // IPv6 literal is mostly colons, and splitting `fe80::1` at the last one
      // yields the host `fe80:` on port 1 — a plausible pair, dialled with
      // total confidence, that can never connect. Somebody who means a literal
      // *and* a port has to bracket it, which is what this and every other
      // reader of an address has always required.
      final colons = ':'.allMatches(body).length;
      if (colons > 1) {
        host = body;
      } else if (colons == 1) {
        final colon = body.indexOf(':');
        host = body.substring(0, colon);
        tail = body.substring(colon + 1);
      } else {
        host = body;
      }
    }

    var port = DisplayHost.defaultPort;
    if (tail != null) {
      // A port that is not a port is a refusal rather than a host with a colon
      // in it. `192.168.1.20:70000` is somebody who meant a port and mistyped
      // it, and treating the whole string as a host name turns that into a DNS
      // lookup that fails several seconds later for a reason nobody can read.
      final parsed = int.tryParse(tail);
      if (parsed == null || parsed < 1 || parsed > 65535) return null;
      port = parsed;
    }

    return _isAddress(host) ? (host: host, port: port) : null;
  }

  /// Whether [host] could be somewhere to connect to.
  ///
  /// **The scheme keeps other people's codes out; this keeps out everything
  /// that never had one.** `WIFI:S:Studio;T:WPA;P:hunter2;;` — the code taped
  /// to the wall of every studio this application is used in — has no `://` to
  /// be refused by, and without this it parses as a host named `WIFI` and
  /// several semicolons. The rule is not a validator and does not try to be:
  /// it rejects the shapes that are certainly not addresses, and leaves
  /// deciding whether one resolves to the resolver.
  static bool _isAddress(String host) =>
      host.contains(':') ? _literalV6.hasMatch(host) : _name.hasMatch(host);

  /// A host or domain name, or an IPv4 address. Hyphens inside, never at
  /// either end.
  static final RegExp _name = RegExp(
    r'^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$',
  );

  /// Hex groups and colons, optionally an embedded IPv4 tail, optionally a zone
  /// — `fe80::1%en0`, which is how a link-local address names the interface it
  /// is local to.
  static final RegExp _literalV6 = RegExp(
    r'^[0-9A-Fa-f:.]+(%[A-Za-z0-9._-]+)?$',
  );

  /// Brackets an IPv6 literal so that the port is still readable after it.
  static String _bracket(String address) =>
      address.contains(':') && !address.startsWith('[')
      ? '[$address]'
      : address;
}
