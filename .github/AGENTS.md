# .github/

**`ci.yml` is the only workflow.** One run answers all three questions a push
can raise — is this correct, does the site still build, can somebody install it
— and what runs is decided by the event rather than by which file a job lives
in:

| Event | Jobs |
|---|---|
| pull request | `checks`, `engine`, `website` |
| push to `main` | the same, and `website` deploys as well as builds |
| `workflow_dispatch` | the same, plus `plugin`, every installer, `ipa` and `android-aab` |
| `workflow_dispatch` with `asc_notes_build` | `checks`, `engine`, `website` and `asc-notes` alone — the nine expensive jobs are gated off, because a notes run exists to be cheap |

Three of the installer jobs — `macos-pkg`, `windows-installer` and
`linux-tarball` — additionally `needs: plugin`, because each of them carries
the VST3 (and on macOS the Audio Unit) and installs it behind a checkbox. They
download the bundles that job already built, signed and notarised rather than
building a second copy: fifteen minutes of JUCE per platform, a second trip
through Apple's notary, and two binaries meant to be identical that could
differ. The condition on those jobs is the one `plugin` already had, so nothing
here costs a push anything — what it costs is a release's wall clock, which now
starts the installers when the slowest JUCE build ends.

| tag `v*` | the same, plus `publish`, and `testflight` and `play-store` after it |

It was three files — `ci.yml`, `docs.yml`, `release.yml` — split on the argument
that packaging is an order of magnitude slower than testing and must not slow
the signal everybody waits on. **That argument was right about the cost and
wrong about the remedy.** What keeps a push fast is not running the packaging
jobs, which is an `if:` condition; the file boundary contributed nothing to it
and took away two things worth more.

It took away the gate. A tag could publish a release from a commit whose tests
were red, because a job in `release.yml` had no way to depend on a job in
`ci.yml`. `publish` now names every test job in `needs`, and the installers name
`checks`.

And it took away any coverage of the packaging paths. `release.yml` ran for the
first time on the v0.2.0 tag, long after it was written, and four of its six
jobs failed on that first execution. Every failure was a command that had never
run in CI. Keep `workflow_dispatch` for that reason: it builds every installer
without publishing, and it is the only thing standing between a packaging script
and six weeks of quiet rot.

The jobs are split by what they need, and that split is deliberate:

- **`checks`** runs `flutter analyze`, `dart format`, the `oaa_core` domain
  tests, the `oaa_wire` protocol tests, `plugin/test/sources_match.sh`, the
  framework-free half of `plugin/`'s own `ctest`, and then the widget tests. The
  first four need **no C toolchain** — `oaa_core` and `oaa_wire` depend on
  nothing, and the source-list check is a shell script — so they run first and a
  regression in any of them is diagnosed without waiting on a native build. The
  widget tests do compile the engine, because the app depends on `oaa_engine`.

  The `plugin/` step is `-DOAA_BUILD_PLUGIN=OFF`, which configures that
  directory with no JUCE: liboaa, the wire fixture and the transport box test,
  five seconds all told. It is here rather than in `plugin` because none of it
  needs the framework, and the thing it pins had already reached a release
  unnoticed once.
- **`plugin`** is the only thing that compiles `plugin/`, and it runs on a
  release or a manual run, not on a push — three parallel JUCE builds is the
  most expensive thing in the file by an order of magnitude. `sources_match.sh`
  in `checks` compares two text files and never invokes CMake, so before this
  job the VST3 and the AU were built by whoever last did it by hand, with a
  JUCE dependency fetched by tag. AU is macOS-only and
  `plugin/CMakeLists.txt` decides that, not this workflow.

  It also builds `plugin/host/`, the fake DAW, and then runs
  `dart test` in `packages/oaa_wire` a second time — the same suite `checks`
  runs, where the end-to-end cases skip for want of a built binary. Here they
  do not: the host plays a generated signal through the VST3 with no window and
  no sound card, and the Dart codec decodes what arrives on the socket. That is
  the only coverage anywhere of `prepareToPlay`, the FIFO, the playhead, the
  streaming thread and the socket. Linux needs `xvfb-run` because JUCE's
  initialisation wants a display even when the application never opens a
  window; nothing needs audio hardware.

  On Linux it then runs one file of the application's suite,
  `test/plugin_to_display_e2e_test.dart`, which is the same run carried one hop
  further: the app's `PluginLink` accepts the plugin, its `DisplayHost`
  publishes what arrives, and a `DisplayClient` reads it back as a tablet would.
  That join is covered nowhere else — what a display receives is a *re-encode*
  of a snapshot the app decoded, so a field lost in the middle leaves both
  halves' suites green. It is one runner rather than three because the hop is
  Dart over loopback and the same everywhere; it needs Flutter, which the rest
  of this job does not, and it skips in `checks` for want of a built plugin.

  **Know what the gating costs, and what it no longer costs.** The JUCE fetch in
  `plugin/CMakeLists.txt` is conditional, so `checks` configures this directory
  with `-DOAA_BUILD_PLUGIN=OFF` on every push and runs everything in its `ctest`
  that needs no framework: the transport box's delivered-exactly-once test, the
  source lists, and — the one worth naming — `oaa_wire_fixture` against
  `wire_v2.bin`. That last one closes a real hole. The golden is only worth
  anything from both ends, `checks` had been asserting that the committed bytes
  *decode* while nothing between releases asserted that `plugin/src/OaaWire.cpp`
  still *writes* them, and both halves now run on a push in five seconds.

  What stays gated is what genuinely needs the framework: the VST3, the AU, the
  fake DAW, the one `ctest` case that hosts the `AudioProcessor` itself
  (`transport_capture_invents_nothing` — the two branches no plugin format can
  ask for, see `plugin/test/transport_capture_test.cpp`), and every end-to-end
  case that drives them — so between releases the live path is not exercised at
  all. The cost of that is not hypothetical. The
  first dispatch after `plugin/host/` landed failed on macOS, on cases that had
  never run there, and there were two defects under it: an edge delivered twice
  by the plugin when two frames leave inside one audio block, and the fake DAW
  freezing its own playhead whenever its read-ahead thread fell behind, which
  made it report relocates that never happened. The first is pinned by the box
  test and therefore now runs on every push; the second needed a machine slow
  enough that the instrument stopped keeping time, and nothing in this workflow
  will find its like on a push.

- **`engine`** compiles the C through the build hook and runs the meters, the
  EBU Tech 3341/3342 conformance cases and then the `oaa` CLI on Linux, macOS
  and Windows. It needs no audio hardware — that is what the built-in test tone
  is for. The CLI runs on all three because **file decoding is where the
  platforms differ most**: Windows takes a UTF-16 path, so a filename with an
  umlaut in it fails there and nowhere else. It then **builds** the CLI with
  `dart build cli` and runs what it built. The tests invoke it with `dart run`,
  so nothing here would have noticed that the release's build command had
  stopped working — and nothing did: `dart compile exe` refuses a package whose
  dependencies have build hooks, and all three CLI jobs failed on the first tag
  that ever ran the packaging jobs.

- **`ipa` and `testflight`** are one path split across the release. `ipa` builds
  and signs the iPad build beside the other packagers; `testflight` uploads it,
  and it is the only job in this file that runs **after** `publish`.

  That ordering is the design rather than an accident of dependencies. An upload
  to App Store Connect cannot be withdrawn, and `xcodebuild -exportArchive` will
  happily export and upload in one step — which would have put the upload in
  `ipa`, before the other installers finished and before the release existed. A
  TestFlight build for a version that was never released is a state nothing else
  here can produce and nobody can clean up. So the IPA travels between the two
  jobs as an artefact, and `publish` names `ipa` in `needs` so that a signing
  failure fails the release rather than following it.

  A manual dispatch runs `ipa` and not `testflight`, which is the useful half:
  it proves the certificate, the profile and the export without spending a
  build number.

- **`asc-notes` is the other half of that**, and it exists because the notes
  `testflight.sh` writes were otherwise unprovable without a tag. Dispatch with
  `asc_notes_build` set to a build App Store Connect already has, and it writes
  What to Test onto that build and What's New onto the listing — the same two
  code paths the upload takes, with the upload removed. Setting that input also
  gates the nine expensive jobs off, so the run is a checkout and one script.

  Three things about it are deliberate. It runs on **ubuntu**, because the App
  Store Connect API needs python3, openssl and the network and none of altool,
  xcrun or a Mac — it is the only job here that reaches Apple without one. Its
  wait is **zero**, because `asc_notes.py` polls only for the minutes after an
  upload while Apple turns bytes into a build resource, and a build named by
  hand was processed long ago. And it **fails on a refusal**, where the same
  refusal inside `testflight.sh` is a warning: there a note is not worth
  failing an upload Apple has already accepted, and here the answer is the
  entire product of the run.

- **`android-aab` and `play-store`** are the same path for the same reason, and
  Play is the stricter store. A version code it has accepted can never be
  reused and never lowered, so an upload that ran ahead of a release which then
  went red would not merely leave a build behind — it would burn the number the
  retry wanted. `android-aab` builds and signs beside the other packagers,
  `publish` names it in `needs`, and `play-store` uploads afterwards.

  Where it differs from `ipa` is what a run with no secrets does, and the
  difference is real rather than a matter of taste. An App Store export with no
  distribution signature is not an unsigned IPA, it is a *failed export*, so
  `make_ipa.sh` produces nothing. An Android release build with no upload key
  **succeeds**: Gradle falls back to the debug key, which is what keeps
  `flutter run --release` working for a developer who has never seen the
  credential. So `make_aab.sh` builds either way and declines to hand over what
  it built — worth having, because Android is compiled nowhere else in this
  workflow and a dispatch is the only thing standing between that build and six
  weeks of quiet rot.

  The track is a repository **variable**, not a secret. It is a routing
  decision somebody should be able to read off the settings page, and unset it
  means `internal` — Play's nearest thing to TestFlight, and the only default
  under which a mistake is cheap.

## Rules

- **`FLUTTER_VERSION` and `JAVA_VERSION` must match `.tool-versions`.** CI that
  passes on a different toolchain than everybody develops against is worse than
  no CI. The JDK joined that file after the Android jobs landed, and the two
  disagreed for a day — `.tool-versions` said 25 while `setup-java` said 17,
  which is exactly the drift this rule exists to stop. Only the Android jobs
  need a JDK; nothing else in the file reads `JAVA_VERSION`.
- **Keep all three platforms in the `engine` matrix.** The first CI run failed
  on Linux and macOS and passed on Windows, because `-std=c11` hides POSIX
  declarations behind `__STRICT_ANSI__` and MSVC never sees them. Dropping a
  platform to save minutes would have hidden it; a local build had already
  hidden it once.
- **The conformance run is a gate, not a report.** The EBU Tech 3341/3342 cases
  run inside the `engine` job's Dart suite; a red conformance run blocks the
  release, because these are the numbers users deliver against. The official EBU
  and ITU vector files are deliberately *not* here — 811 MB that may not be
  redistributed, and fetching it would put a network dependency in front of the
  one suite that must never be flaky. `packages/oaa_engine/test/vectors_test.dart`
  runs them from a local copy and skips here, which is why **anything it catches
  that a generated signal can also express is added to the gated suite in the
  same change** — it caught two defects on its first run and CI could see
  neither. See `docs/METRICS.md`.
- **Never add `continue-on-error` to a test step.** A test that is allowed to
  fail is a test that has already been deleted, just more slowly.
- **A gate named in a document and missing from `ci.yml` is worse than no
  gate,** because everybody believes it is running. When a suite is added to the
  repository it is added here in the same change, and `CLAUDE.md`'s Testing
  Requirements and `README.md`'s Tests list are the two places that must agree
  with this file. `dart test packages/oaa_wire` and `sources_match.sh` were both
  documented as gates for a phase before either was actually wired in.
- **The flatpak job validates the metainfo before it builds, and prints the
  compose report when it fails.** `flatpak-builder` finishes with
  `appstreamcli compose`, which reports a component id and an error tag, says
  "refer to the generated issue report data", and then discards that report —
  so a metainfo defect surfaces ten minutes into the job as three lines naming
  no file. `appstreamcli validate --explain` is the same check in two seconds
  and runs first. Keep both: the second one is what makes a failure the log can
  answer rather than a guessing exercise against the manifest.

- **A packaging job is named for what a person downloads, and its id names the
  platform first.** The five desktop jobs are `macos-pkg`,
  `windows-installer`, `linux-tarball`, `linux-appimage` and `linux-flatpak`,
  each uploading the artefact of the same name with an `oaa-` prefix. They
  were `pkg`, `windows`, `tarball`, `appimage` and `flatpak` — a format, a
  platform, a container and two brand names, five schemes for five jobs that
  do one thing each — and `publish`'s `needs:` list read as an inventory of
  unrelated work. Keep the pattern when a sixth is added: the id is what a
  failure is reported under and the only name anybody greps for.

- **An artefact is named by `runner.os`, never by `matrix.os`.** `matrix.os` is
  a runner *image* and the image is pinned: `oaa-plugin-ubuntu-22.04` was the
  name three installer jobs downloaded by, so the day that pin moves — and the
  glibc rule below is the argument about when, not whether — three
  `download-artifact` steps fail on a name that no longer exists, in jobs
  nobody touched, on the first release after the change. `runner.os` is
  `Linux`, `macOS` or `Windows` and matches the filename inside the archive,
  which is what somebody unpacking it sees.

- **Every installer this repository builds has spaces in its name, so no
  filename may be word-split.** The publish step collects assets NUL-delimited
  into an array; `$(find ...)` unquoted turns
  `Open Audio Analyzer-0.2.0-x86_64.AppImage` into three arguments and the job
  dies on `no matches found for .../Open` with all seven builds green. The
  documentation's shell examples quote the names for the same reason — they did
  not, and neither command worked as printed.

- **A release is titled with the tag alone.** `v0.12.0`, never
  "Open Audio Analyzer v0.12.0". GitHub already prints the repository's name
  above every release — in the page heading, in the breadcrumb and in the
  releases feed — so a title that repeats it says the same words three times
  in one row and pushes the version, which is the only thing anybody is
  scanning the list for, off to the right. `gh release create` is given
  `--title "${GITHUB_REF_NAME}"` for that reason; a release published before
  0.12.0 carries the old form and is left alone, because a released section is
  never rewritten.

- **A release's notes are its own changelog section, found by version.** The
  publish step reads `## [<tag without the v>]` out of `CHANGELOG.md` and fails
  when that section is missing or blank. It used to take the *first* section
  instead, which on a release commit is `## [Unreleased]` — empty by
  construction — so the release would have carried no notes and no step would
  have gone red. Cutting a tag therefore means moving `[Unreleased]`'s contents
  under a numbered heading in the same commit.
- **An installer that cannot be installed is published, and labelled.** Signing
  needs secrets a fork does not have, so every packaging script produces an
  unsigned artefact and says so rather than failing. A release job that quietly
  published something a user cannot install would be worse than one that failed;
  a fork that could not build at all would be worse than both.
- **A secret this workflow reads is not the same as a secret it can use, and
  both failures were silent.** Two of them, found together while chasing a
  user's report that a DAW called the plugin harmful. The `dmg` job — now
  `macos-pkg` — passed `OAA_SIGNING_IDENTITY` to `codesign --sign` on a runner
  whose keychain was empty and where **nothing imported a certificate**: the
  identity was a name with nothing behind it. And `OAA_NOTARY_PROFILE` names a
  profile stored in a *machine's* keychain, which a fresh runner cannot have,
  so the notarisation branch could never be taken. Neither failed a job,
  because the secrets had never been set either and the scripts' no-credential
  branches ran instead: each gap kept the other invisible.
  `packaging/macos/keychain.sh` now runs before anything signs, in both the
  `plugin` and `macos-pkg` jobs, and the notary credentials are passed in the
  runner-shaped form. The third instance of the same shape is
  `OAA_WINDOWS_CERT`, which names a *path* to a `.pfx`; `make_installer.ps1`
  takes `OAA_WINDOWS_CERT_BASE64` as well, which is the form a runner can
  actually be given.
- **The `plugin` job's Linux leg runs on `ubuntu-22.04`, not `ubuntu-latest`.**
  It is the same glibc floor the `linux-appimage` and `linux-tarball` jobs are
  pinned to, and for six releases it was not: the Linux application was built
  against 22.04's glibc and the Linux VST3 beside it against whatever
  `ubuntu-latest` meant that month. Only one of those floors was chosen. The
  failure it produces is worse than the application's, too — a plug-in the
  loader refuses is not a loader error a user sees, it is a plug-in absent from
  the DAW's browser, which is what installing it in the wrong folder also looks
  like.
- **The IPA is built and deliberately not published.** An App Store signature
  provisions no devices, so nobody who downloaded it could install it. The
  publish step excludes `testflight-ipa` by path rather than narrowing its
  download to a name pattern, so a future artefact nobody thought about is
  attached by mistake rather than omitted by mistake — of the two, only the
  second is silent.
- **That policy has fired once, and it is why it is written this way.**
  `download-artifact` with no `name` takes every artefact in the run, not the
  ones `publish` lists in `needs`, so the old documentation-site job's artefact
  arrived even though it was not a dependency — and `upload-pages-artifact`
  always calls its payload `artifact.tar`. Every release from v0.3.0 to v0.6.0
  therefore carried an unlabelled tarball of a website in among the installers,
  and whether it carried one at all was a race that the docs job, being the
  fastest in the workflow, won five times. That job is gone with GitHub Pages;
  the exclusion policy it taught is not.
- **`testflight` is gated on an output of `ipa`, not just on the tag.** An App
  Store IPA has no unsigned form, so with no credentials `make_ipa.sh` produces
  nothing at all — which is the correct outcome and not a failure. But a job
  that produced nothing uploads no artefact, and `download-artifact` errors on a
  name that does not exist: without the gate, a tag in a repository or a fork
  with no iOS secrets turns a release that went out perfectly well into a red
  run, on a step that has nothing to do with the release. `ipa` reports whether
  it built anything and `testflight` skips on `false`. A skipped job says what
  happened; a failed download says something is broken.
- **The Android version code is `github.run_number` too, and Play is less
  forgiving than App Store Connect about it.** App Store Connect refuses a
  build number it has already accepted for a version string; Play refuses a
  version code it has ever accepted, on any track, forever, and refuses any
  number below the highest it has seen. There is no recovering a burnt one.
- **Nothing checks an .aab's signer except `make_aab.sh`, and it must.** An app
  bundle carries no indication of which key signed it, so a debug-signed one is
  indistinguishable from a release build until Play rejects it by fingerprint
  at the end of an upload — which is after the release has been published. The
  check reads the certificate subject with `keytool -printcert -jarfile`, pins
  the locale with `-J-Duser.language=en`, and matches on `CN=Android Debug`
  rather than on the `Owner:` label: keytool is **translated**, so a check
  written against the label passes on a runner and fails on a German laptop.
  The debug key's fingerprint is no use for this — the SDK generates a
  different one on every machine — but its distinguished name is always the
  same.
- **The iOS build number is `github.run_number`, not `pubspec.yaml`'s `+N`.**
  App Store Connect refuses a build number it has already accepted for the same
  version string, and it refuses it during the upload — which is after the
  release has been published. The pubspec's number is maintained by hand, so a
  re-run of a tag collides there and nowhere else in the workflow. The run
  counter only ever increases.
- **The `plugin` job signs at configure time and notarises before it archives.**
  `-DOAA_CODESIGN_IDENTITY` is a cache variable because the target that reads it
  is generated, so it belongs on the `cmake -B` line and not in `env:`; and the
  notarisation ticket is a file inside the bundle, so `Notarise` has to run
  between `Build` and `Archive` or the artefact ships without it and is refused
  exactly as an unnotarised one is.
