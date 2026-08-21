// SPDX-License-Identifier: GPL-3.0-or-later

/// The permission-shaped thing that stands between Android and a multicast
/// socket that receives anything.
///
/// **Android's Wi-Fi driver drops every multicast packet not addressed to the
/// device unless somebody holds a `WifiManager.MulticastLock`.** Nothing about
/// that is visible from Dart: the bind succeeds, the group join succeeds, the
/// query goes out, and the answers every other device on the network sends back
/// are discarded below the socket. There is no error and nothing is logged, so
/// an Android tablet browsed an empty network for eight phases under a panel
/// that said *Looking for hosts on this network…* — the exact failure
/// `HostDiscovery.failure` exists to prevent, arriving through a door that had
/// no error to report.
///
/// Taking the lock is a platform call, so it is a channel:
/// `android/app/src/main/kotlin/dev/openaudioanalyzer/oaa/OaaMulticastLock.kt`.
/// Everywhere else this is a no-op, and deliberately not a `Platform.isAndroid`
/// check at the call sites — a search either needs a lock or it does not, and
/// the two callers should not each have to know which platforms those are.
///
/// **Reference counted here rather than in Kotlin.** Two searches overlap every
/// time one host picker replaces another, because a route's `initState` runs
/// before the outgoing route's `dispose`, and on a desktop the responder and
/// the browser hold sockets at the same time. The count is what makes the
/// leaving one's release stop being the arriving one's problem. It lives on this
/// side because this is the side that knows how many searches there are; the
/// native lock is not reference counted at all, which is what keeps it from
/// drifting out of step with a Dart isolate that was hot-restarted.
///
/// Held only while something is searching, never for the life of the process.
/// The lock lifts multicast filtering for the whole device, and a tablet on a
/// stand showing meters all day pays for it in battery.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The channel `OaaMulticastLock` answers on.
const MethodChannel multicastLockChannel = MethodChannel(
  'dev.openaudioanalyzer.oaa/multicast_lock',
);

/// Lifting Android's multicast filter, for as long as somebody is listening.
abstract final class MulticastLock {
  /// Whether this platform needs the lock at all.
  ///
  /// Assignable because a test on a Mac cannot otherwise reach a line of this
  /// file, and what is worth holding is the counting and the sentence — neither
  /// of which is Android-specific in anything but which platform runs it.
  @visibleForTesting
  static bool platformNeedsLock = Platform.isAndroid;

  /// How many searches currently want multicast delivered.
  static int _holders = 0;

  /// Why the lock is not held, in a sentence for a person, or null.
  ///
  /// Remembered rather than recomputed so that a second holder is told the same
  /// thing as the first without a second trip across the channel.
  static String? _failure;

  @visibleForTesting
  static int get holders => _holders;

  /// Takes the lock if this is the first holder. Returns null when multicast
  /// will be delivered, and otherwise the reason it will not.
  ///
  /// **A failure here is not a reason to give up on the search.** A device with
  /// no Wi-Fi hardware has nothing filtering multicast in the first place, and a
  /// wired tablet discovers perfectly without a lock. So this reports rather
  /// than refuses, the caller browses anyway, and the sentence reaches the panel
  /// — where it sits next to a typed-address field, which is the answer whatever
  /// the reason turns out to be.
  static Future<String?> acquire() async {
    _holders++;
    if (_holders > 1) return _failure;
    if (!platformNeedsLock) return _failure = null;

    try {
      await multicastLockChannel.invokeMethod<void>('acquire');
      return _failure = null;
    } on PlatformException catch (error) {
      return _failure = error.message ?? _generalFailure;
    } on MissingPluginException {
      // The channel is not registered — an Android build whose runner has lost
      // `OaaMulticastLock`, or a platform that has grown an Android-shaped
      // `Platform.isAndroid` without one. Silent otherwise, and indistinguishable
      // from a quiet network.
      return _failure = _generalFailure;
    }
  }

  /// Gives the lock back once the last holder has stopped searching.
  ///
  /// Synchronous, and it has to be: it is called from `dispose`, which cannot
  /// await, and from the teardown path of a browser whose notifiers are about
  /// to go away. The channel call is fired and not waited on — there is nothing
  /// to do with the answer, and a release that fails costs battery rather than
  /// correctness.
  static void release() {
    if (_holders == 0) return;
    _holders--;
    if (_holders > 0) return;
    _failure = null;
    if (!platformNeedsLock) return;
    unawaited(
      multicastLockChannel
          .invokeMethod<void>('release')
          .catchError((Object _) => null),
    );
  }

  /// Forgets that anything is held, for a test that has finished with it.
  @visibleForTesting
  static void reset() {
    _holders = 0;
    _failure = null;
  }

  static const String _generalFailure =
      'Android is not delivering multicast to Open Audio Analyzer, so hosts '
      'cannot be found automatically. Enter an address below.';
}
