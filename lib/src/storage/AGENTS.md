# lib/src/storage/

Everything Open Audio Analyzer remembers between launches. GPL-3.0-or-later.

| File | Purpose |
|------|---------|
| `config_store.dart` | Reading and writing it. Atomic writes, debounced session saves, and no exceptions. |
| `startup_config.dart` | The one read of the whole directory, performed before the first frame. |
| `android_files_dir.dart` | `getFilesDir()`, over the one channel this layer has. Android is the only platform that will not name a writable directory through the environment; its native half is `android/.../OaaFilesDir.kt`. |

**Where the configuration lives is not here either.** `resolveConfigRoot`,
`ConfigDir`, `ConfigFile` and `slugify` are in
`packages/oaa_core/lib/src/config_locations.dart`, because the `oaa` CLI reads
the same delivery targets the app writes and cannot import this package. While
those rules lived here the CLI knew only the six built-in targets, so a
corrected `atsc-a85.json` changed the verdict in the window and not the exit
code — which is the one a release pipeline believes.

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

- **`root` is not a boundary.** `readJsonAt` and `writeJsonAt` take an absolute
  path anywhere on the machine, because a preset opened or saved through a file
  dialog is wherever the user put it — that is the whole point of presets being
  documents. They are *here*, rather than in the code that opens the dialog, so
  that the three rules above still hold for those files: a preset saved to a
  Desktop is written atomically, and one that cannot be read there names itself
  in `lastError` instead of throwing. Nothing outside this directory opens a
  `File`.

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
  permission error at save time.

- **Android is the same hole, and the environment cannot be made to fill it.**
  It has no `HOME` either, and the iPad's trick does not transfer: its temporary
  directory is `/data/local/tmp`, which belongs to no app, and the container path
  contains the Android *user* — 0 on a tablet, 10 in a work profile — so it
  cannot be guessed without eventually writing into somebody else's profile.
  `getFilesDir()` is the only correct answer and it is a platform call, so
  `android_files_dir.dart` asks for it and hands it to the same pure resolver
  the iPad's container goes through. It resolved to null for eight phases and a
  tablet started from the defaults at every launch — the display worked, so
  nothing looked broken. **The channel is asked on Android even when
  `--config-dir` or `OAA_CONFIG_DIR` will win**, so that the precedence between
  the three stays in the one function that owns it rather than being decided
  twice.

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
  means launching `Open Audio Analyzer.app/Contents/MacOS/Open Audio Analyzer`
  directly, and a bare binary launch changes how TCC attributes the microphone
  request — so the device fails
  to open and the engine falls back to the test tone. Through `open` the device
  works and the variable never reaches the process. For a phase that was the
  choice of one or the other, and it was mis-reported once as "the persisted
  source is ignored". The flag settles it:

  ```sh
  open "build/macos/Build/Products/Debug/Open Audio Analyzer.app" \
    --args --config-dir=/tmp/oaa
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
