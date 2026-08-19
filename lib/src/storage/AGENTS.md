# lib/src/storage/

Everything Open Audio Analyzer remembers between launches. GPL-3.0-or-later.

| File | Purpose |
|------|---------|
| `config_paths.dart` | Where the configuration lives, per platform. Pure functions of an environment map and, on iOS, of the temporary directory — no `dart:io`, no Flutter. |
| `config_store.dart` | Reading and writing it. Atomic writes, debounced session saves, and no exceptions. |
| `startup_config.dart` | The one read of the whole directory, performed before the first frame. |

The models these files serialise are **not here** — `AppSettings`, `Skin`,
`PresetSpec` and `Calibration` all live in `oaa_core`, because the `oaa` CLI and
the remote display parse the same documents and neither may drag Flutter in.
This directory knows about files; it does not know what is in them.

## Rules

- **Every write is atomic.** Write to `<file>.tmp`, then rename over the target.
  A crash mid-save then costs the last edit rather than the whole preset, which
  is a difference the user only discovers at the moment they try to open it.

- **Nothing here throws.** A failed read is null, a failed write is false, and
  the reason lands in `lastError` for the interface to show. A metering session
  three hours into an integration must not end because a directory went
  read-only. It follows that every caller has to *look* at the result — a
  discarded `false` is a silent data loss.

- **A document that fails to parse is skipped, named, and left alone.** Never
  rewrite a file Open Audio Analyzer could not read: the user hand-edited it,
  the mistake is probably a trailing comma, and overwriting it destroys the
  thing they were trying to write. One broken skin costs one skin.

- **One file per preset, per skin, per target.** A single `presets.json` is
  marginally less code and takes the whole library out with one corrupt byte,
  and it makes "send me your preset" impossible without a text editor.

- **Session saves are debounced; explicit saves are not.** The canvas commits a
  layout on every drag, resize and option change. A user rearranging a tab would
  otherwise issue a hundred writes in a few seconds. Anything the user pressed a
  button for goes to disk immediately.

- **`flush()` before the process exits.** A debounced write that has not landed
  is the last edit before quitting — the one edit a user is most likely to
  notice losing. `oaa_app.dart` calls it from `AppLifecycleListener`.

- **Do not reach for `path_provider`.** It needs a `WidgetsBinding`, so it
  throws in a plain Dart entrypoint and in a unit test — both of which have to
  find the same configuration as the app. On macOS it also returns a sandbox
  container keyed by bundle identifier, which relocates every user's
  configuration the first time a build is signed differently.

- **The precedence is `--config-dir`, then `OAA_CONFIG_DIR`, then the
  platform's convention** — and all three are decided in one place.
  `resolveConfigRoot` takes the flag as an argument rather than reading it, so
  it stays pure and the order is visible in a single function instead of being
  spread across whoever happens to call it. The variable is how the tests point
  at a temporary directory and how a portable install keeps its configuration
  beside the binary; the flag exists because macOS cannot hand an environment to
  a bundle at all, which is the paragraph below. **Do not add a third escape
  hatch** — two already need this note to explain which wins.

- **iOS has no `HOME`, and the temporary directory is how its container is
  found.** `TMPDIR` is set to `<container>/tmp`, so the container is one
  component up — `resolveConfigRoot` takes `Directory.systemTemp.path` as an
  argument and `ConfigStore.open` is the only place that reads it. That keeps
  the resolver pure and makes an iPad's paths testable from a Mac, which is
  otherwise a device build away. It shipped resolving to *nothing* on iPadOS
  for a phase: the Unix branch asked for `HOME`, an iPad has none, and the app
  opened with "no configuration directory" and forgot every layout. **Do not
  fall back to `HOME` on iOS** — when it is set at all it is `/var/mobile`,
  which the app cannot write to, and that turns a notice at launch into a
  permission error at save time. Android is the same hole and is *not* fixed:
  its temporary directory is `/data/local/tmp`, which belongs to no app, so an
  Android display persists nothing until somebody adds a channel to
  `getFilesDir()`.

- **Every path here is only correct because the macOS app is not sandboxed.**
  A sandboxed app's `HOME` is its own container, so all three platform branches
  would quietly resolve under `~/Library/Containers/<bundle id>/Data` and
  `OAA_CONFIG_DIR` could not escape it — with the denial surfacing as "could not
  read <file>", which reads like a corrupt file rather than a permission.
  `macos/Runner/*.entitlements` omits `com.apple.security.app-sandbox` for that
  reason and documents it. **No test can catch a regression here**: it is a
  property of the app bundle, not of the Dart, and it shipped green for a full
  phase before anybody ran the app and went looking for the folder.

- **On macOS override the path with the flag, not the variable, whenever the
  microphone is also in play.** Handing an environment variable to a bundle
  means launching `oaa.app/Contents/MacOS/oaa` directly, and a bare binary
  launch changes how TCC attributes the microphone request — so the device fails
  to open and the engine falls back to the test tone. Through `open` the device
  works and the variable never reaches the process. For a phase that was the
  choice of one or the other, and it was mis-reported once as "the persisted
  source is ignored". The flag settles it:

  ```sh
  open -a build/macos/Build/Products/Debug/oaa.app --args --config-dir=/tmp/oaa
  ```

  overrides the directory with TCC still attributing the request to the bundle,
  so a config path and a real capture device can finally be exercised in one
  launch. That took a change outside this directory:
  `macos/Runner/MainFlutterWindow.swift` forwarded **no** arguments to the Dart
  entrypoint, because the stock runner builds a bare `FlutterViewController`.
  Windows and Linux pass the command line through out of the box — so a flag
  tested only there would have worked on the two platforms that did not need it
  and been silently ignored on the one that did.

- **Anything that tells a user where their files are must print
  `ConfigStore.root`**, never a path assembled from the documented convention.
  The two agree today; the whole point of the store resolving it once is that
  they cannot disagree tomorrow. Print it as selectable text — a path somebody
  has to retype from a screenshot is a path they will get wrong.

## Testing

`test/storage_test.dart` runs against a real temporary directory rather than a
fake filesystem: the atomic rename, the tolerance for a corrupt file and the
directory that does not exist yet are all properties of an actual filesystem,
and a fake would only assert that the fake behaves as its author assumed.

Path resolution is tested for all four platforms — the three desktops and
iPadOS — from whichever one is running, because `resolveConfigRoot` takes the
operating system, the environment and the temporary directory as arguments
rather than reading them.
