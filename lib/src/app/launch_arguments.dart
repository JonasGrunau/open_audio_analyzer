// SPDX-License-Identifier: GPL-3.0-or-later

/// The command line, on the one platform that does not hand it over.
///
/// `main(List<String> arguments)` is handed the real thing on Windows, Linux and
/// — because `macos/Runner/MainFlutterWindow.swift` sets
/// `dartEntrypointArguments` — macOS. On iOS it is handed an empty list, and
/// there is no supported way to change that: the engine is created implicitly by
/// the `FlutterViewController` the storyboard builds, and the delegate hook the
/// runner gets, `didInitializeImplicitFlutterEngine`, arrives with the engine
/// already running.
///
/// **The two obvious detours are both dead ends, and each looks like it works
/// until it is checked.** `xcrun simctl launch` passes `SIMCTL_CHILD_…` variables
/// into the process — `ps eww` shows them on the running app — and Dart's
/// `Platform.environment` on iOS is *empty*, always, so nothing arrives.
/// `Platform.executableArguments` is empty too. Both answer without error, which
/// is why the first attempt at this shipped a flag that silently did nothing.
///
/// So iOS is asked. `ios/Runner/OaaLaunchArguments.swift` answers with argv, and
/// `xcrun simctl launch <device> <bundle> --args --attach=oaa://host:port` then
/// works exactly as `open --args` does on a Mac. Every other platform already
/// knows and never calls.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The channel `ios/Runner/OaaLaunchArguments.swift` answers on.
const MethodChannel launchArgumentsChannel = MethodChannel(
  'oaa/launch_arguments',
);

/// [entrypoint], or what the platform says when the entrypoint was told nothing.
///
/// **Failure is silent and returns [entrypoint], which is the right trade.** A
/// flag nobody passed is the overwhelmingly common case, and an application that
/// refused to start because a diagnostic channel was not ready would be trading
/// a launch for a convenience. The one cost is that a mistyped flag on an iPad
/// is a flag that did nothing, which is the same thing that happens on a desktop
/// — `parseLaunchOptions` collects those as warnings and the interface shows
/// them.
Future<List<String>> launchArguments(List<String> entrypoint) async {
  // Not `Platform.isIOS` alone: a test runs on the host, where the channel is
  // unimplemented and every call is an exception to swallow.
  if (entrypoint.isNotEmpty || !Platform.isIOS) return entrypoint;

  try {
    final arguments = await launchArgumentsChannel.invokeListMethod<String>(
      'arguments',
    );
    return arguments ?? entrypoint;
  } on Object catch (error) {
    // `MissingPluginException` if this runs before the runner has registered —
    // the engine is created and the entrypoint started by the same framework
    // call, so the order is not ours to guarantee — and a `PlatformException`
    // if the handler itself failed.
    debugPrint('Could not read the launch arguments: $error');
    return entrypoint;
  }
}
