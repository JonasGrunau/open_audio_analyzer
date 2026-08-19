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
/// Listen to [events] once; the stream closes when the run finishes, fails or
/// is cancelled. Call [dispose] afterwards — it frees the native cancel flag,
/// which is small but is native memory all the same.
class OfflineAnalysisJob {
  OfflineAnalysisJob._(this._token, this._events);

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

    return OfflineAnalysisJob._(token, _listen(receive));
  }

  final OaaCancelToken _token;
  final Stream<OfflineEvent> _events;

  Stream<OfflineEvent> get events => _events;

  /// Asks the worker to stop. It checks between decoded blocks, so this takes
  /// effect within a few milliseconds and unwinds cleanly rather than leaking
  /// the engine and the open file.
  void cancel() => _token.cancel();

  void dispose() => _token.dispose();

  /// Turns the port's untyped messages into the sealed event type.
  ///
  /// `onExit` sends a bare null and `onError` sends a two-element list, so both
  /// arrive on the same port as the worker's own messages and have to be told
  /// apart here. An isolate that dies without ever reporting — an out-of-memory
  /// kill, say — closes the stream rather than leaving the UI on a progress bar
  /// that will never move again.
  static Stream<OfflineEvent> _listen(ReceivePort receive) async* {
    try {
      await for (final message in receive) {
        if (message == null) return; // onExit

        if (message is List && message.length == 2) {
          yield OfflineFailedEvent('${message.first}');
          return;
        }

        if (message is OfflineEvent) {
          yield message;
          if (message is! OfflineProgressEvent) return;
        }
      }
    } finally {
      receive.close();
    }
  }
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
