// SPDX-License-Identifier: GPL-3.0-or-later

/// What Open Audio Analyzer remembers between launches.
///
/// Small, flat and entirely made of things a human chose. Nothing derived and
/// nothing measured — if a field here could be recomputed from the audio it is
/// in the wrong file.
library;

import 'metric.dart';

/// Where the signal comes from.
///
/// This mirrors `OaaSource` in `oaa_engine` and deliberately is not it.
/// `oaa_core` may not import `dart:ffi`, and the remote display persists a
/// source selection it will never open, so the vocabulary has to exist on this
/// side of the boundary too. The app maps between them in one place.
///
/// **[plugin] is the one with no `OaaSource` behind it at all**, which is the
/// clearest argument this enum is not the engine's. A DAW plugin's
/// measurements arrive already made, over a socket — nothing local captures
/// them and there is no device to open — so it is a source in the only sense
/// that matters to a person choosing one, and not a source the engine has ever
/// heard of.
enum AudioSourceKind {
  testTone('test_tone', 'Test tone'),
  silence('silence', 'Silence'),
  device('device', 'Device'),
  plugin('plugin', 'DAW plugin');

  const AudioSourceKind(this.id, this.label);

  final String id;
  final String label;

  static AudioSourceKind? fromId(String id) {
    for (final kind in AudioSourceKind.values) {
      if (kind.id == id) return kind;
    }
    return null;
  }
}

/// The version stamped into every file Open Audio Analyzer writes.
///
/// It exists so that the *next* format change has somewhere to branch, and it is
/// written from the first release rather than added later — a file with no
/// version is a file whose migration has to guess.
const int kConfigSchemaVersion = 1;

/// The user's persistent choices.
class AppSettings {
  const AppSettings({
    this.sourceKind = AudioSourceKind.testTone,
    this.deviceId,
    this.deviceName,
    this.targetFps = 60,
    this.calibrationId = 'streaming-14',
    this.skinId = 'precision-instrument',
    this.restoreSession = true,
    this.remoteDisplayName,
    this.remoteDisplayPort = 47821,
    this.remoteDisplayFps = 30,
    this.dynamicsNaming = DynamicsNaming.defaultNaming,
    this.recentHosts = const [],
    this.keepDisplayAwake = true,
  });

  final AudioSourceKind sourceKind;

  /// The capture device to reopen at launch, as miniaudio reports it.
  ///
  /// Device ids are not stable across reboots on any of the three platforms —
  /// they encode a bus position on macOS, a container id on Windows and an ALSA
  /// card index on Linux. That is why [deviceName] is stored beside it: when the
  /// id no longer matches anything, the app can still find "Scarlett 2i2" and
  /// reopen it, which is what the user meant.
  final String? deviceId;
  final String? deviceName;

  /// Meter refresh rate. One of 30, 60, 120.
  final int targetFps;

  /// The active delivery target. Never null: a session always measures against
  /// something, and "no target" is a state where half the interface has nothing
  /// to colour readings against.
  final String calibrationId;

  final String skinId;

  /// Whether the canvas layout is restored at launch.
  ///
  /// On by default, and worth being able to turn off: somebody using Open Audio
  /// Analyzer to check one file at a time wants the same clean default layout
  /// every time, and having yesterday's experiment restored is a small daily
  /// annoyance.
  final bool restoreSession;

  /// What the remote display advertises itself as, or null for the machine's
  /// own host name.
  ///
  /// Null rather than a computed default, because computing it needs
  /// `dart:io` and this package has none. The app resolves it when it
  /// publishes.
  final String? remoteDisplayName;

  /// The port the remote display listens on, and how often it sends.
  ///
  /// **There is deliberately no "publish at launch" setting.** Configuration is
  /// worth remembering; the decision to open a port with no password on it is
  /// worth asking for every time. A laptop carried to a café must not start
  /// advertising itself because somebody enabled it once at home.
  final int remoteDisplayPort;
  final int remoteDisplayFps;

  /// What the two dynamics readings are called on screen, in a report and on
  /// the tablet: the AES names or the ODR specification's. See
  /// [DynamicsNaming] for why the AES names are the default.
  final DynamicsNaming dynamicsNaming;

  /// The hosts this machine has been a display for, newest first, at most
  /// [kRecentHostLimit] of them.
  ///
  /// **Remembered on the receiving side, and that is not the same decision as
  /// the one [remoteDisplayPort] refuses.** Publishing opens a port with no
  /// password on it, so it is asked for every time. Attaching opens nothing: it
  /// is a connection this machine makes to somebody who has already chosen to
  /// publish, and it can only watch. Forgetting the address meant typing four
  /// numbers into a tablet every session, in exactly the rooms where discovery
  /// is blocked and typing is the only way in.
  ///
  /// Recorded only once a host has answered — see `RemoteDisplayScreen` — so a
  /// typo is never offered back as somewhere to go.
  final List<RecentHost> recentHosts;

  /// Whether the screen stays on while this machine is somebody's display.
  ///
  /// On by default, because a display is a screen nobody touches and that is
  /// exactly the screen an idle timeout switches off. It governs only the
  /// display: the canvas, the panels and every other application on the device
  /// keep the system's own timeout.
  final bool keepDisplayAwake;

  /// [clearDevice] and [clearRemoteDisplayName] exist because null means *keep*
  /// everywhere else in here, and both of those fields have a null that is an
  /// instruction rather than an absence: no device chosen, and "advertise under
  /// this machine's own name". Without the flag, emptying the name field in the
  /// remote panel silently restored the previous name — the one way back to the
  /// default was unreachable once a name had ever been set.
  AppSettings copyWith({
    AudioSourceKind? sourceKind,
    String? deviceId,
    String? deviceName,
    bool clearDevice = false,
    int? targetFps,
    String? calibrationId,
    String? skinId,
    bool? restoreSession,
    String? remoteDisplayName,
    bool clearRemoteDisplayName = false,
    int? remoteDisplayPort,
    int? remoteDisplayFps,
    DynamicsNaming? dynamicsNaming,
    List<RecentHost>? recentHosts,
    bool? keepDisplayAwake,
  }) => AppSettings(
    sourceKind: sourceKind ?? this.sourceKind,
    deviceId: clearDevice ? null : (deviceId ?? this.deviceId),
    deviceName: clearDevice ? null : (deviceName ?? this.deviceName),
    targetFps: targetFps ?? this.targetFps,
    calibrationId: calibrationId ?? this.calibrationId,
    skinId: skinId ?? this.skinId,
    restoreSession: restoreSession ?? this.restoreSession,
    remoteDisplayName: clearRemoteDisplayName
        ? null
        : (remoteDisplayName ?? this.remoteDisplayName),
    remoteDisplayPort: remoteDisplayPort ?? this.remoteDisplayPort,
    remoteDisplayFps: remoteDisplayFps ?? this.remoteDisplayFps,
    dynamicsNaming: dynamicsNaming ?? this.dynamicsNaming,
    recentHosts: recentHosts ?? this.recentHosts,
    keepDisplayAwake: keepDisplayAwake ?? this.keepDisplayAwake,
  );

  Map<String, Object?> toJson() => {
    'version': kConfigSchemaVersion,
    'source': sourceKind.id,
    if (deviceId != null) 'device_id': deviceId,
    if (deviceName != null) 'device_name': deviceName,
    'fps': targetFps,
    'calibration': calibrationId,
    'skin': skinId,
    'restore_session': restoreSession,
    if (remoteDisplayName != null) 'remote_name': remoteDisplayName,
    'remote_port': remoteDisplayPort,
    'remote_fps': remoteDisplayFps,
    'dynamics_names': dynamicsNaming.id,
    if (recentHosts.isNotEmpty)
      'recent_hosts': [for (final host in recentHosts) host.toJson()],
    'keep_display_awake': keepDisplayAwake,
  };

  /// Reads settings, substituting the default for anything missing or absurd.
  ///
  /// Every field is defended individually rather than the document being
  /// validated as a whole. A settings file is the one file most likely to be
  /// hand-edited and the one whose corruption is least acceptable: a bad frame
  /// rate should cost the frame rate, not the window position, the device and
  /// the skin as well.
  factory AppSettings.fromJson(Map<String, Object?> json) {
    const defaults = AppSettings();

    final fps = json['fps'];
    final deviceId = json['device_id'];
    final deviceName = json['device_name'];
    final calibration = json['calibration'];
    final skin = json['skin'];
    final remoteName = json['remote_name'];
    final remotePort = json['remote_port'];
    final remoteFps = json['remote_fps'];
    final recent = json['recent_hosts'];

    return AppSettings(
      sourceKind:
          AudioSourceKind.fromId(json['source'] as String? ?? '') ??
          defaults.sourceKind,
      deviceId: deviceId is String && deviceId.isNotEmpty ? deviceId : null,
      deviceName: deviceName is String && deviceName.isNotEmpty
          ? deviceName
          : null,
      targetFps: fps is int && kTargetFpsOptions.contains(fps)
          ? fps
          : defaults.targetFps,
      calibrationId: calibration is String && calibration.isNotEmpty
          ? calibration
          : defaults.calibrationId,
      skinId: skin is String && skin.isNotEmpty ? skin : defaults.skinId,
      restoreSession: json['restore_session'] as bool? ?? true,
      remoteDisplayName: remoteName is String && remoteName.isNotEmpty
          ? remoteName
          : null,
      // Below 1024 needs privileges Open Audio Analyzer does not have and
      // should never ask for; above 65535 is not a port.
      remoteDisplayPort:
          remotePort is int && remotePort >= 1024 && remotePort <= 65535
          ? remotePort
          : defaults.remoteDisplayPort,
      remoteDisplayFps:
          remoteFps is int && kRemoteFpsOptions.contains(remoteFps)
          ? remoteFps
          : defaults.remoteDisplayFps,
      dynamicsNaming:
          DynamicsNaming.fromId(json['dynamics_names'] as String? ?? '') ??
          defaults.dynamicsNaming,
      // Entry by entry, like everything else here: one mangled address costs
      // that address and not the list.
      recentHosts: recent is List
          ? [
              for (final entry in recent)
                if (entry is Map)
                  ?RecentHost.tryFromJson(entry.cast<String, Object?>()),
            ].take(kRecentHostLimit).toList(growable: false)
          : const [],
      keepDisplayAwake:
          json['keep_display_awake'] as bool? ?? defaults.keepDisplayAwake,
    );
  }
}

/// How many hosts [AppSettings.recentHosts] keeps.
///
/// A handful: the studio, the venue, the rehearsal room. A list long enough to
/// scroll is a list where the one that was used yesterday is not where it was.
const int kRecentHostLimit = 5;

/// A host this machine has been a display for, as it was reached.
///
/// The address is the one that was *dialled*, not one the host reported about
/// itself — the same host has as many addresses as it has networks, and the
/// one that worked from here is the one worth trying again. [name] is what the
/// host called itself when it answered, for the row to be read by; it is not
/// used to find anything.
class RecentHost {
  const RecentHost({required this.host, required this.port, this.name});

  final String host;
  final int port;
  final String? name;

  /// Whether [other] is the same place to connect to. The name is not part of
  /// it: a host renamed since last time is still the same address.
  bool sameAddress(RecentHost other) =>
      host.toLowerCase() == other.host.toLowerCase() && port == other.port;

  Map<String, Object?> toJson() => {
    'host': host,
    'port': port,
    if (name != null) 'name': name,
  };

  /// Null for anything that could not be dialled.
  static RecentHost? tryFromJson(Map<String, Object?> json) {
    final host = json['host'];
    final port = json['port'];
    final name = json['name'];
    if (host is! String || host.trim().isEmpty) return null;
    if (port is! int || port < 1 || port > 65535) return null;
    return RecentHost(
      host: host.trim(),
      port: port,
      name: name is String && name.trim().isNotEmpty ? name.trim() : null,
    );
  }

  /// [list] with [host] at the front, any earlier entry for the same address
  /// removed, and the tail cut at [kRecentHostLimit].
  static List<RecentHost> remember(List<RecentHost> list, RecentHost host) => [
    host,
    ...list.where((entry) => !entry.sameAddress(host)),
  ].take(kRecentHostLimit).toList(growable: false);
}

/// The refresh rates offered.
///
/// 30 halves GPU load for a session left open all day; 120 exists because the
/// displays do. Lives here rather than in the app because the settings parser
/// above has to validate against it, and a validator that duplicates the list it
/// validates against is a validator that will disagree with it.
const List<int> kTargetFpsOptions = [30, 60, 120];

/// How often the remote display is sent a frame.
///
/// Lower than the meter rates on purpose: this one crosses a wireless network,
/// where the cost of a frame is bandwidth and latency rather than GPU time.
const List<int> kRemoteFpsOptions = [15, 30, 60];
