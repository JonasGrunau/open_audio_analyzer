// SPDX-License-Identifier: MIT

import 'package:oaa_core/oaa_core.dart';
import 'package:test/test.dart';

void main() {
  group('AudioSourceKind', () {
    test('ids round-trip', () {
      for (final kind in AudioSourceKind.values) {
        expect(AudioSourceKind.fromId(kind.id), kind);
      }
      expect(AudioSourceKind.fromId('microphone'), isNull);
    });
  });

  group('AppSettings', () {
    test('round-trips through JSON', () {
      const settings = AppSettings(
        sourceKind: AudioSourceKind.device,
        deviceId: 'usb:1234',
        deviceName: 'Scarlett 2i2',
        targetFps: 120,
        calibrationId: 'ebu-r128',
        skinId: 'daylight',
        restoreSession: false,
      );

      final parsed = AppSettings.fromJson(settings.toJson());

      expect(parsed.sourceKind, AudioSourceKind.device);
      expect(parsed.deviceId, 'usb:1234');
      expect(parsed.deviceName, 'Scarlett 2i2');
      expect(parsed.targetFps, 120);
      expect(parsed.calibrationId, 'ebu-r128');
      expect(parsed.skinId, 'daylight');
      expect(parsed.restoreSession, isFalse);
    });

    test('stamps a schema version', () {
      // Written from the first release rather than added later: a file with no
      // version is a file whose migration has to guess.
      expect(const AppSettings().toJson()['version'], kConfigSchemaVersion);
    });

    test('an empty document is the defaults', () {
      final parsed = AppSettings.fromJson({});
      const defaults = AppSettings();

      expect(parsed.sourceKind, defaults.sourceKind);
      expect(parsed.targetFps, defaults.targetFps);
      expect(parsed.calibrationId, defaults.calibrationId);
      expect(parsed.skinId, defaults.skinId);
      expect(parsed.restoreSession, defaults.restoreSession);
      expect(parsed.deviceId, isNull);
    });

    test('a bad field costs that field and nothing else', () {
      // The settings file is the one most likely to be hand-edited and the one
      // whose corruption is least acceptable. A nonsense frame rate must not
      // also lose the device, the target and the skin.
      final parsed = AppSettings.fromJson({
        'source': 'telepathy',
        'fps': 47,
        'calibration': 'ebu-r128',
        'skin': 'daylight',
        'device_id': 'usb:1234',
      });

      expect(parsed.sourceKind, AudioSourceKind.testTone);
      expect(parsed.targetFps, 60);
      expect(parsed.calibrationId, 'ebu-r128');
      expect(parsed.skinId, 'daylight');
      expect(parsed.deviceId, 'usb:1234');
    });

    test('only the offered frame rates are accepted', () {
      for (final fps in kTargetFpsOptions) {
        expect(AppSettings.fromJson({'fps': fps}).targetFps, fps);
      }
      expect(AppSettings.fromJson({'fps': 0}).targetFps, 60);
      expect(AppSettings.fromJson({'fps': 'sixty'}).targetFps, 60);
    });

    test('an empty device id reads as no device', () {
      // Distinct from a device that is merely not connected: the empty string
      // would be passed to the engine as a device name and fail obscurely.
      final parsed = AppSettings.fromJson({'device_id': '', 'device_name': ''});
      expect(parsed.deviceId, isNull);
      expect(parsed.deviceName, isNull);
    });

    test('a null device is omitted from the document', () {
      expect(const AppSettings().toJson().containsKey('device_id'), isFalse);
    });

    test('the remote display settings round-trip', () {
      const settings = AppSettings(
        remoteDisplayName: 'Studio iPad',
        remoteDisplayPort: 51000,
        remoteDisplayFps: 15,
      );
      final parsed = AppSettings.fromJson(settings.toJson());

      expect(parsed.remoteDisplayName, 'Studio iPad');
      expect(parsed.remoteDisplayPort, 51000);
      expect(parsed.remoteDisplayFps, 15);
    });

    test('no remote name means the machine decides', () {
      // Resolving the host name needs dart:io, which this package does not
      // have. Null is the instruction to the app, not a missing value.
      expect(const AppSettings().remoteDisplayName, isNull);
      expect(const AppSettings().toJson().containsKey('remote_name'), isFalse);
    });

    test('a privileged or impossible port falls back', () {
      // Below 1024 needs privileges Open Audio Analyzer must never ask for.
      for (final port in [0, 80, 1023, 65536, 99999, -1]) {
        expect(
          AppSettings.fromJson({'remote_port': port}).remoteDisplayPort,
          47821,
          reason: 'accepted $port',
        );
      }
      expect(
        AppSettings.fromJson({'remote_port': 1024}).remoteDisplayPort,
        1024,
      );
    });

    test('only the offered remote frame rates are accepted', () {
      for (final fps in kRemoteFpsOptions) {
        expect(AppSettings.fromJson({'remote_fps': fps}).remoteDisplayFps, fps);
      }
      expect(AppSettings.fromJson({'remote_fps': 120}).remoteDisplayFps, 30);
    });

    test('publishing is never remembered', () {
      // Configuration is worth remembering; the decision to open an
      // unauthenticated port is worth asking for every session. If a field for
      // this ever appears, this test is the argument against it.
      final keys = const AppSettings().toJson().keys;
      expect(keys.any((key) => key.contains('enable')), isFalse);
      expect(keys.any((key) => key.contains('publish')), isFalse);
    });

    test(
      'a settings file written before remote display existed still loads',
      () {
        // The forward-compatibility contract, exercised on a real change: three
        // fields were added after v1 files were already on disk.
        final old = AppSettings.fromJson({
          'version': 1,
          'source': 'device',
          'fps': 30,
          'calibration': 'ebu-r128',
          'skin': 'daylight',
          'restore_session': false,
        });

        expect(old.remoteDisplayPort, 47821);
        expect(old.remoteDisplayFps, 30);
        expect(old.remoteDisplayName, isNull);
        expect(old.calibrationId, 'ebu-r128');
      },
    );

    test('copyWith clears the device only when asked', () {
      const settings = AppSettings(
        deviceId: 'usb:1234',
        deviceName: 'Scarlett 2i2',
      );

      expect(settings.copyWith(targetFps: 30).deviceId, 'usb:1234');
      expect(settings.copyWith(clearDevice: true).deviceId, isNull);
      expect(settings.copyWith(clearDevice: true).deviceName, isNull);
    });

    test('the remote display name can be cleared, not only replaced', () {
      // Null means *keep* everywhere in `copyWith`, and this field's null is an
      // instruction — advertise under the machine's own host name. Without a
      // flag of its own, emptying the name box in the remote panel restored the
      // previous name and the default was unreachable once one had been set.
      const settings = AppSettings(remoteDisplayName: 'Studio Mac');

      expect(settings.copyWith(targetFps: 30).remoteDisplayName, 'Studio Mac');
      expect(
        settings.copyWith(remoteDisplayName: 'Booth').remoteDisplayName,
        'Booth',
      );
      expect(
        settings.copyWith(clearRemoteDisplayName: true).remoteDisplayName,
        isNull,
      );
    });
  });
}
