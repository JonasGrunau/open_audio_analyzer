// Running a file analysis without stopping the meters.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
// `analyseFile` decodes and measures a whole file on the thread that calls it.
// An hour of audio is a few seconds of work — fast, but several hundred frames
// long, and a metering app whose display freezes while it thinks is a metering
// app that has stopped metering. So the analysis runs on its own isolate and
// reports back, and the live meters keep their frame budget throughout.
//
// Cancellation goes through [OaaCancelToken] rather than killing the isolate,
// because the worker owns a native engine and an open decoder and killing it
// mid-loop leaks both. The reasoning is with the token, in oaa_engine.

import 'dart:async';
import 'dart:isolate';

import 'package:oaa_engine/oaa_engine.dart';

/// What a running analysis reports back.
sealed class OfflineEvent {
  const OfflineEvent();
}

/// [seconds] of [totalSeconds] analysed. [totalSeconds] is 0 when the file's
/// length is unknown, which the UI shows as an indeterminate bar rather than
/// as a position it cannot actually know.
class OfflineProgressEvent extends OfflineEvent {
  const OfflineProgressEvent(this.seconds, this.totalSeconds);

  final double seconds;
  final double totalSeconds;

  /// 0..1, or null when the length is unknown.
  double? get fraction {
    if (totalSeconds <= 0) return null;
    return (seconds / totalSeconds).clamp(0.0, 1.0);
  }
}

class OfflineDoneEvent extends OfflineEvent {
  const OfflineDoneEvent(this.result);

  final OfflineResult result;
}

class OfflineFailedEvent extends OfflineEvent {
  const OfflineFailedEvent(this.message);

  final String message;
}

class OfflineCancelledEvent extends OfflineEvent {
  const OfflineCancelledEvent();
}

/// One file analysis, running on its own isolate.
///
/// Listen to [events] once. **The stream closes when the worker isolate has
/// exited**, not when the last event arrived — those are different instants and
/// the difference is a use-after-free. The worker reads the cancel flag out of
/// native memory this object owns, and it only looks between decoded blocks, so
/// for a few milliseconds after a cancel the flag is still being read. Freeing
/// it there returned four bytes that the *next* job's token then reallocated
/// and zeroed, so the old worker read the new job's flag, saw "not cancelled",
/// and analysed the rest of its file at full speed against the meters the
/// isolate exists to protect.
///
/// So [stop] is the way to end a run early: it asks, waits for the exit, and
/// only then frees. [dispose] is safe once the stream has closed.
class OfflineAnalysisJob {
  OfflineAnalysisJob._(this._token, this._events, this._exited);

  /// Starts analysing [path].
  static Future<OfflineAnalysisJob> start(
    String path, {
    Duration timelineInterval = const Duration(milliseconds: 100),
  }) async {
    final token = OaaCancelToken();
    final receive = ReceivePort();

    try {
      await Isolate.spawn(
        _worker,
        _Request(
          reply: receive.sendPort,
          path: path,
          timelineIntervalMs: timelineInterval.inMilliseconds,
          cancelAddress: token.address,
        ),
        errorsAreFatal: true,
        onError: receive.sendPort,
        onExit: receive.sendPort,
      );
    } on Object {
      receive.close();
      token.dispose();
      rethrow;
    }

    final exited = Completer<void>();
    final events = StreamController<OfflineEvent>();

    // The port is drained here rather than by whoever listens to [events], and
    // that is the whole mechanism. A subscriber can cancel at any moment — the
    // panel does, when it is disposed mid-run — and if the drain were the
    // subscriber's `await for`, cancelling it would stop the drain and nothing
    // would ever observe the isolate's exit. The flag would then be freed while
    // the worker was still reading it, which is the bug this shape exists to
    // remove. So: the port is read until the isolate is gone, whatever the
    // consumer does with the stream.
    late final StreamSubscription<dynamic> messages;
    messages = receive.listen((message) {
      if (message == null) {
        // onExit. The worker has stopped touching the cancel flag.
        if (!exited.isCompleted) exited.complete();
        messages.cancel();
        receive.close();
        events.close();
        return;
      }

      // `onError` sends a two-element list. An isolate that died without
      // reporting still reaches the null above, so the UI is never left on a
      // progress bar that will not move again.
      if (message is List && message.length == 2) {
        if (!events.isClosed) {
          events.add(OfflineFailedEvent('${message.first}'));
        }
        return;
      }

      if (message is OfflineEvent && !events.isClosed) events.add(message);
    });

    return OfflineAnalysisJob._(token, events.stream, exited.future);
  }

  final OaaCancelToken _token;
  final Stream<OfflineEvent> _events;

  /// Completes when the worker isolate is gone and the flag can be freed.
  final Future<void> _exited;

  Stream<OfflineEvent> get events => _events;

  /// Asks the worker to stop, without waiting.
  ///
  /// It checks between decoded blocks, so this takes effect within a few
  /// milliseconds and unwinds cleanly rather than leaking the engine and the
  /// open file. **The flag it reads is only safe to free once it has actually
  /// gone** — use [stop] unless the stream is already closed.
  void cancel() => _token.cancel();

  /// Cancels, waits for the isolate to exit, then releases the flag.
  Future<void> stop() async {
    _token.cancel();
    await _exited;
    _token.dispose();
  }

  /// Releases the cancel flag. Only valid once [events] has closed, which is
  /// the point at which the worker is known to be gone. Mid-run, use [stop].
  void dispose() => _token.dispose();
}

class _Request {
  const _Request({
    required this.reply,
    required this.path,
    required this.timelineIntervalMs,
    required this.cancelAddress,
  });

  final SendPort reply;
  final String path;
  final int timelineIntervalMs;
  final int cancelAddress;
}

void _worker(_Request request) {
  final reply = request.reply;
  final cancel = OaaCancelToken.fromAddress(request.cancelAddress);

  // Progress is throttled on wall-clock time rather than sent for every
  // timeline point. At a point every 100 ms of signal, an hour-long file would
  // otherwise post 36,000 messages at a progress bar that can show about sixty
  // of them a second, and the message traffic would slow down the analysis it
  // was reporting on.
  final stopwatch = Stopwatch()..start();
  var lastPost = -1;

  try {
    final result = analyseFile(
      request.path,
      timelineInterval: Duration(milliseconds: request.timelineIntervalMs),
      shouldCancel: () => cancel.isCancelled,
      onProgress: (seconds, totalSeconds) {
        final elapsed = stopwatch.elapsedMilliseconds;
        if (elapsed - lastPost < 50) return;
        lastPost = elapsed;
        reply.send(OfflineProgressEvent(seconds, totalSeconds));
      },
    );
    reply.send(OfflineDoneEvent(result));
  } on OfflineCancelled {
    reply.send(const OfflineCancelledEvent());
  } on OaaFileException catch (error) {
    reply.send(OfflineFailedEvent(error.message));
  } on OaaEngineException catch (error) {
    reply.send(OfflineFailedEvent(error.message));
  } on Object catch (error) {
    reply.send(OfflineFailedEvent('$error'));
  }
}
