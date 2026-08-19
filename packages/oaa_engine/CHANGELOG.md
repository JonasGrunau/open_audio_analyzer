# Changelog — oaa_engine

This package is a workspace package and is never published, so it has no release
history of its own. **Its changes are recorded in the repository's
[`CHANGELOG.md`](../../CHANGELOG.md)**, together with the engine change that
caused them — an ABI bump and the C it describes are one change, and splitting
them across two files is how they come apart.

The one thing worth knowing here: **`OAA_ABI_VERSION` in
`engine/include/oaa/oaa.h` and `OaaEngine.expectedAbiVersion` in
`lib/oaa_engine.dart` move in the same commit, always.** The Dart constant is an
assertion about the header, not an independent value.
