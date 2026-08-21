#!/bin/sh
#
# sources_match.sh — assert the engine's two build descriptions list the same
# files.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# ---------------------------------------------------------------------------
# What this is defending against
#
# `packages/oaa_engine/hook/build.dart` compiles the engine for the Flutter app.
# `engine/CMakeLists.txt` compiles it for the plugin. They exist separately
# because a plugin CI runner has no Flutter SDK and a build hook cannot be
# handed to JUCE — but they describe the same compile, and somebody adding a
# file to `engine/src` will eventually add it to only one.
#
# The failure that produces is an undefined symbol at link time in whichever
# consumer was forgotten, usually on a platform the author was not building,
# reported as a wall of mangled names. It is perfectly diagnosable and it costs
# an hour the first time. This turns it into a one-line diff.
#
# Both lists are deliberately hand-maintained rather than globbed: adding a file
# to the engine should be a decision somebody made, not a side effect of
# creating it. A glob would keep the two lists trivially in step while hiding
# whether anyone meant it — which is to say it would defeat this check by
# removing the thing being checked.
#
# Run from anywhere:  sh plugin/test/sources_match.sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cmake_file="$root/engine/CMakeLists.txt"
hook_file="$root/packages/oaa_engine/hook/build.dart"

for f in "$cmake_file" "$hook_file"; do
  if [ ! -f "$f" ]; then
    echo "sources_match: missing $f" >&2
    exit 1
  fi
done

# Paths are normalised to be relative to engine/, so that CMake's `src/x.c` and
# build.dart's `../../engine/src/x.c` compare as the same file.
#
# `.m` as well as `.c`, and that is not a formality. `oaa_tap_macos.m` is
# conditional in both descriptions — `if(APPLE AND NOT IOS)` here,
# `_platformSources` there — so it is exactly the kind of source that reaches
# one list and not the other. Matching only `.c` would have let it, and this
# check would have gone on reporting OK while the plugin failed to link on
# macOS.
cmake_sources=$(
  sed -n 's|^[[:space:]]*\(src/[A-Za-z0-9_/]*\.[cm]\)[[:space:]]*$|\1|p;
          s|^[[:space:]]*\(third_party/[A-Za-z0-9_/]*\.[cm]\)[[:space:]]*$|\1|p;
          s|^.*list(APPEND OAA_SOURCES \(src/[A-Za-z0-9_/]*\.[cm]\)).*$|\1|p' \
    "$cmake_file" | sort -u
)

hook_sources=$(
  sed -n "s|^[[:space:]]*'\.\./\.\./engine/\([A-Za-z0-9_/]*\.[cm]\)',[[:space:]]*$|\1|p" \
    "$hook_file" | sort -u
)

if [ "$cmake_sources" = "$hook_sources" ]; then
  count=$(printf '%s\n' "$cmake_sources" | grep -c .)
  echo "sources_match: OK — $count sources listed identically in both builds."
  exit 0
fi

echo "sources_match: FAILED — the two engine build descriptions disagree." >&2
echo >&2
echo "  engine/CMakeLists.txt              (the plugin's build)" >&2
echo "  packages/oaa_engine/hook/build.dart (the app's build)" >&2
echo >&2
echo "'<' is in CMakeLists only, '>' is in build.dart only:" >&2
echo >&2

# `diff` on process substitution is a bashism; keep to POSIX so this runs under
# dash on a Linux CI runner as well as under zsh here.
tmp_cmake=$(mktemp)
tmp_hook=$(mktemp)
trap 'rm -f "$tmp_cmake" "$tmp_hook"' EXIT
printf '%s\n' "$cmake_sources" > "$tmp_cmake"
printf '%s\n' "$hook_sources" > "$tmp_hook"
diff "$tmp_cmake" "$tmp_hook" >&2 || true

echo >&2
echo "Add the file to both, then run this again." >&2
exit 1
