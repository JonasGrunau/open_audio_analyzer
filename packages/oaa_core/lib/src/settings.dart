// SPDX-License-Identifier: MIT

/// What Open Audio Analyzer remembers between launches.
///
/// Small, flat and entirely made of things a human chose. Nothing derived and
/// nothing measured — if a field here could be recomputed from the audio it is
/// in the wrong file.
library;

/// Where the signal comes from.
///
/// This mirrors `OaaSource` in `oaa_engine` and deliberately is not it.
/// `oaa_core` may not import `dart:ffi`, and the remote display persists a
/// source selection it will never open, so the vocabulary has to exist on this
/// side of the boundary too. The app maps between them in one place.
enum AudioSourceKind {
  testTone('test_tone', 'Test tone'),
  silence('silence', 'Silence'),
  device('device', 'Device');

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
    );
  }
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
