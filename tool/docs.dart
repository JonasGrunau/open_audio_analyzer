// SPDX-License-Identifier: GPL-3.0-or-later
//
// Keeps the old documentation URLs working, now that the documentation is part
// of the website.
//
//   dart run tool/docs.dart            -> build/docs
//   dart run tool/docs.dart --out DIR
//
// ---------------------------------------------------------------------------
// What this used to be, and why it is not that any more
//
// This was a Markdown renderer: eight documents in, a small static site out,
// published to GitHub Pages by the `docs` job in `.github/workflows/ci.yml`.
// It worked, and the argument for it was sound — the pages it published are
// normative and held by tests, and building them with a Dart SDK and nothing
// else meant the site could not break on a machine where the code was fine.
//
// What it could not fix was that the project then had two websites. They had
// different type, different colour and different navigation; the marketing site
// linked away to the documentation and the documentation linked back; and a
// change to the shared visual language had to be made twice, in two languages,
// or else the two drifted. The documentation is now rendered by the website
// from the same files, which are still in this repository and still normative:
// see `website/src/lib/docs.mjs` for the manifest and
// `website/src/content.config.ts` for how they are read in place.
//
// ---------------------------------------------------------------------------
// So why is there anything here at all
//
// Because `jonasgrunau.github.io/open_audio_analyzer/install.html` is in
// released READMEs, in issue threads and in whatever anybody bookmarked, and
// none of that can be edited now. Those addresses keep working: this writes one
// redirect per page, and GitHub Pages goes on serving them.
//
// A redirect is a `<meta http-equiv="refresh">` and a link, because Pages
// cannot send a 301 — it serves files. The canonical link is what search
// engines follow, the meta refresh is what a browser follows, and the visible
// link is what somebody with a blocked refresh follows. The fragment is
// preserved by the small script: `install.html#in-a-daw` and
// `/docs/install#in-a-daw` name the same section, and dropping the fragment
// would land every deep link at the top of a four-hundred-line page.
//
// This has no dependency but `dart:io`, as the renderer had, so the CI job that
// runs it is still a Dart SDK and a few seconds.

import 'dart:io';

/// Where the documentation lives now.
const String _site = 'https://open-audio-analyzer.com/docs';

/// Every address the old site published, and the page that replaced it.
///
/// The slugs match on both sides — `install.html` became `/docs/install` —
/// which is not luck: the website's manifest kept them so that this file is a
/// list of names rather than a mapping anybody has to maintain.
const Map<String, String> _pages = {
  'index': '',
  'install': '/install',
  'keyboard': '/keyboard',
  'analysing-files': '/analysing-files',
  'metrics': '/metrics',
  'wire': '/wire',
  'changelog': '/changelog',
  'building': '/building',
};

void main(List<String> arguments) {
  var out = 'build/docs';
  for (var i = 0; i < arguments.length; i++) {
    if (arguments[i] == '--out' && i + 1 < arguments.length) {
      out = arguments[i + 1];
    }
    if (arguments[i].startsWith('--out=')) out = arguments[i].substring(6);
  }

  Directory(out).createSync(recursive: true);
  stdout.writeln('Open Audio Analyzer documentation -> $_site');

  for (final entry in _pages.entries) {
    final target = '$_site${entry.value}';
    File('$out/${entry.key}.html').writeAsStringSync(_redirect(target));
    stdout.writeln('  ${entry.key}.html'.padRight(24) + target);
  }

  // The old site had a stylesheet, and the `docs` job checks it was written.
  // Kept as an empty file rather than dropped, so that a stale cache asking for
  // it gets a 200 and not a 404 in somebody's console.
  File(
    '$out/style.css',
  ).writeAsStringSync('/* The documentation moved to $_site */\n');

  // GitHub Pages runs Jekyll unless told not to, and Jekyll drops anything
  // beginning with an underscore. Nothing here starts with one; this costs a
  // line and removes the class of failure entirely.
  File('$out/.nojekyll').writeAsStringSync('');
}

String _redirect(String target) =>
    '''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Moved to open-audio-analyzer.com</title>
<link rel="canonical" href="$target">
<meta http-equiv="refresh" content="0; url=$target">
<meta name="robots" content="noindex, follow">
<style>
  html { background: #0b0c0e; color: #e6e8eb; font: 16px/1.5 system-ui, sans-serif; }
  body { margin: 0; display: grid; place-items: center; min-height: 100vh; padding: 24px; }
  main { max-width: 34rem; }
  p { margin: 0 0 16px; color: #8a9199; }
  a { color: #35e0c4; }
</style>
</head>
<body>
<main>
<p>The Open Audio Analyzer documentation is now part of the website.</p>
<p><a id="go" href="$target">$target</a></p>
</main>
<script>
  // Carry the fragment across, so a link to a section lands on that section.
  // The refresh above has already been given a URL without one; rewriting the
  // link and replacing the location covers both the browser that honours the
  // refresh and the reader who clicks.
  (function () {
    var hash = location.hash;
    if (!hash) return;
    var to = '$target' + hash;
    document.getElementById('go').href = to;
    location.replace(to);
  })();
</script>
</body>
</html>
''';
