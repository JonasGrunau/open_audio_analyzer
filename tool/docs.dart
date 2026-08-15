// SPDX-License-Identifier: GPL-3.0-or-later
//
// Builds the documentation site from the Markdown already in this repository.
//
//   dart run tool/docs.dart            -> build/docs
//   dart run tool/docs.dart --out DIR
//
// ---------------------------------------------------------------------------
// Why a generator here rather than MkDocs or Docusaurus
//
// Both are good and both are a second toolchain. This repository builds with
// Dart and a C compiler, and the documents the site publishes are not marketing
// copy — `docs/METRICS.md` and `docs/WIRE.md` are normative, held by tests, and
// read by somebody implementing against them. Publishing them through a Python
// or Node pipeline means the site can break on a machine where the code is
// fine, and it means the one thing worth having — that the pages and the code
// are the same repository — is expressed as a CI step rather than as a
// `dart run`.
//
// What is given up is search. That is a real loss and an honest one: the site
// is a dozen pages, every page has a table of contents, and the browser's own
// find works on all of it.
//
// ---------------------------------------------------------------------------
// The Markdown is deliberately narrow
//
// Headings, paragraphs, lists, tables, fenced and inline code, links, images,
// bold, italic, blockquotes, rules. That is everything the eleven source
// documents use, and adding a construct here without a document that needs it
// is how a renderer acquires a footnote parser nobody asked for. Anything
// unrecognised passes through as text rather than being silently dropped —
// a document that renders wrong is fixable; one that renders *short* is not
// noticed.
//
// `package:markdown` would do this. It is not a dependency of anything else in
// the repository and would be the only one that exists for a build step; the
// subset above is roughly two hundred lines and has no version to bump.

import 'dart:convert';
import 'dart:io';

// ---------------------------------------------------------------------------
// What the site is

/// One page: where its Markdown comes from, and what it is called.
class Page {
  const Page({
    required this.source,
    required this.slug,
    required this.title,
    required this.blurb,
    this.section = '',
  });

  /// Path from the repository root.
  final String source;

  /// The output filename, without `.html`.
  final String slug;

  final String title;

  /// One line, for the index and for the page's own header.
  final String blurb;

  /// The nav heading this page sits under. Empty means top level.
  final String section;
}

/// Every page, in navigation order.
///
/// Nothing is generated from a directory listing. A site whose contents are
/// whatever happens to be in `docs/` publishes `PLAN.md` to users the day
/// somebody moves it, and a plan is not documentation — it is a record of what
/// was intended, which reads as a promise when a stranger finds it.
const List<Page> pages = [
  Page(
    source: 'docs/site/index.md',
    slug: 'index',
    title: 'Bel',
    blurb: 'A free loudness and spectrum analyzer.',
  ),
  Page(
    source: 'docs/site/install.md',
    slug: 'install',
    title: 'Install',
    blurb:
        'dmg, msix, AppImage and flatpak — and what each one will and will '
        'not do.',
    section: 'Using Bel',
  ),
  Page(
    source: 'docs/site/keyboard.md',
    slug: 'keyboard',
    title: 'Keyboard',
    blurb: 'Every shortcut, generated from the table the application binds.',
    section: 'Using Bel',
  ),
  Page(
    source: 'docs/site/analysing-files.md',
    slug: 'analysing-files',
    title: 'Analysing files',
    blurb: 'The report panel and the `bel` command-line analyser.',
    section: 'Using Bel',
  ),
  Page(
    source: 'docs/METRICS.md',
    slug: 'metrics',
    title: 'Metrics',
    blurb:
        'What every number means, how it is computed, and whether this '
        'build measures it.',
    section: 'Reference',
  ),
  Page(
    source: 'docs/WIRE.md',
    slug: 'wire',
    title: 'Wire protocol',
    blurb: 'The remote display protocol, normatively.',
    section: 'Reference',
  ),
  Page(
    source: 'CHANGELOG.md',
    slug: 'changelog',
    title: 'Changelog',
    blurb: 'What changed, and which numbers moved.',
    section: 'Reference',
  ),
  Page(
    source: 'docs/site/building.md',
    slug: 'building',
    title: 'Building',
    blurb: 'Building from source, the test gates, and making the installers.',
    section: 'Contributing',
  ),
];

// ---------------------------------------------------------------------------

void main(List<String> arguments) {
  var out = 'build/docs';
  for (var i = 0; i < arguments.length; i++) {
    if (arguments[i] == '--out' && i + 1 < arguments.length) {
      out = arguments[i + 1];
    }
    if (arguments[i].startsWith('--out=')) out = arguments[i].substring(6);
  }

  final directory = Directory(out)..createSync(recursive: true);
  stdout.writeln('Bel documentation -> ${directory.path}');

  var failed = false;
  for (final page in pages) {
    final source = File(page.source);
    if (!source.existsSync()) {
      stderr.writeln('  MISSING  ${page.source}');
      failed = true;
      continue;
    }

    final html = _shell(page, _render(source.readAsStringSync(), page));
    File('$out/${page.slug}.html').writeAsStringSync(html);
    stdout.writeln('  ${page.slug}.html'.padRight(28) + page.source);
  }

  File('$out/style.css').writeAsStringSync(_css);
  stdout.writeln('  style.css');

  // GitHub Pages serves a repository's `docs` through Jekyll unless told not
  // to, and Jekyll silently drops any file or directory beginning with an
  // underscore. Nothing here starts with one today; this costs a line and
  // removes the class of failure entirely.
  File('$out/.nojekyll').writeAsStringSync('');

  if (failed) exitCode = 1;
}

// ---------------------------------------------------------------------------
// Markdown

/// One rendered page: its HTML body and the headings to build a contents list.
class _Rendered {
  _Rendered(this.body, this.headings);
  final String body;
  final List<({int level, String id, String text})> headings;
}

_Rendered _render(String markdown, Page page) {
  final out = StringBuffer();
  final headings = <({int level, String id, String text})>[];
  final lines = const LineSplitter().convert(markdown);
  final usedIds = <String, int>{};

  var i = 0;
  // Every page prints its own H1 from the manifest, so the source document's
  // leading H1 would be a duplicate title. Skipped rather than styled away:
  // two <h1>s is wrong in the outline as well as on screen.
  var skippedTitle = false;

  while (i < lines.length) {
    final line = lines[i];

    // Fenced code.
    if (line.trimLeft().startsWith('```')) {
      final language = line.trim().substring(3).trim();
      final body = <String>[];
      i++;
      while (i < lines.length && !lines[i].trimLeft().startsWith('```')) {
        body.add(lines[i]);
        i++;
      }
      i++; // the closing fence
      out.writeln(
        '<pre class="code"${language.isEmpty ? '' : ' data-lang="$language"'}>'
        '<code>${_escape(body.join('\n'))}</code></pre>',
      );
      continue;
    }

    // An HTML comment block. Passed through as nothing: the generated pages
    // carry "do not edit by hand" notices meant for the repository.
    if (line.trimLeft().startsWith('<!--')) {
      while (i < lines.length && !lines[i].contains('-->')) {
        i++;
      }
      i++;
      continue;
    }

    if (line.trim().isEmpty) {
      i++;
      continue;
    }

    // Headings.
    final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
    if (heading != null) {
      final level = heading.group(1)!.length;
      final text = heading.group(2)!.trim();

      if (level == 1 && !skippedTitle) {
        skippedTitle = true;
        i++;
        continue;
      }

      final id = _uniqueId(_slug(text), usedIds);
      if (level <= 3) headings.add((level: level, id: id, text: _plain(text)));
      out.writeln(
        '<h$level id="$id">'
        '<a class="anchor" href="#$id" aria-label="Link to this section">#</a>'
        '${_inline(text)}</h$level>',
      );
      i++;
      continue;
    }

    // Horizontal rule.
    if (RegExp(r'^\s*([-*_])\s*\1\s*\1[\s\-*_]*$').hasMatch(line)) {
      out.writeln('<hr>');
      i++;
      continue;
    }

    // Tables. A header row, a delimiter row, then body rows until a blank.
    if (line.contains('|') &&
        i + 1 < lines.length &&
        RegExp(r'^\s*\|?[\s:|-]+\|[\s:|-]*$').hasMatch(lines[i + 1])) {
      final header = _cells(line);
      final aligns = _aligns(lines[i + 1]);
      i += 2;

      // Wrapped so a wide table scrolls inside itself rather than making the
      // whole page scroll sideways. docs/WIRE.md has byte tables that are wider
      // than a phone by a factor of three.
      out.writeln('<div class="scroll"><table><thead><tr>');
      for (var c = 0; c < header.length; c++) {
        out.writeln('<th${_alignAttr(aligns, c)}>${_inline(header[c])}</th>');
      }
      out.writeln('</tr></thead><tbody>');

      while (i < lines.length &&
          lines[i].contains('|') &&
          lines[i].trim().isNotEmpty) {
        final row = _cells(lines[i]);
        out.writeln('<tr>');
        for (var c = 0; c < row.length; c++) {
          out.writeln('<td${_alignAttr(aligns, c)}>${_inline(row[c])}</td>');
        }
        out.writeln('</tr>');
        i++;
      }
      out.writeln('</tbody></table></div>');
      continue;
    }

    // Blockquote.
    if (line.trimLeft().startsWith('>')) {
      final body = <String>[];
      while (i < lines.length && lines[i].trimLeft().startsWith('>')) {
        body.add(lines[i].trimLeft().substring(1).trimLeft());
        i++;
      }
      out.writeln('<blockquote><p>${_inline(body.join(' '))}</p></blockquote>');
      continue;
    }

    // Lists. Nesting is by indentation, two levels deep, which is all the
    // sources use.
    final bullet = RegExp(r'^(\s*)([-*+]|\d+\.)\s+(.*)$');
    if (bullet.hasMatch(line)) {
      i = _list(lines, i, out, bullet, 0);
      continue;
    }

    // Paragraph: everything up to a blank line or the start of another block.
    final paragraph = <String>[];
    while (i < lines.length &&
        lines[i].trim().isNotEmpty &&
        !bullet.hasMatch(lines[i]) &&
        !lines[i].trimLeft().startsWith('```') &&
        !lines[i].trimLeft().startsWith('>') &&
        !RegExp(r'^#{1,6}\s').hasMatch(lines[i])) {
      paragraph.add(lines[i].trim());
      i++;
    }
    if (paragraph.isNotEmpty) {
      out.writeln('<p>${_inline(paragraph.join(' '))}</p>');
    }
  }

  return _Rendered(out.toString(), headings);
}

/// Emits one list and returns the index after it.
int _list(
  List<String> lines,
  int start,
  StringBuffer out,
  RegExp bullet,
  int depth,
) {
  final first = bullet.firstMatch(lines[start])!;
  final indent = first.group(1)!.length;
  final ordered = first.group(2)!.endsWith('.');

  out.writeln(ordered ? '<ol>' : '<ul>');
  var i = start;

  while (i < lines.length) {
    final match = bullet.firstMatch(lines[i]);
    if (match == null) {
      // A blank line inside a list is a paragraph break, not the end of it, as
      // long as the next non-blank line is still an item.
      if (lines[i].trim().isEmpty &&
          i + 1 < lines.length &&
          bullet.hasMatch(lines[i + 1])) {
        i++;
        continue;
      }
      break;
    }

    final itemIndent = match.group(1)!.length;
    if (itemIndent < indent) break;

    if (itemIndent > indent) {
      i = _list(lines, i, out, bullet, depth + 1);
      continue;
    }

    // Continuation lines: a wrapped item, indented under its own bullet.
    final text = <String>[match.group(3)!];
    i++;
    while (i < lines.length &&
        lines[i].trim().isNotEmpty &&
        !bullet.hasMatch(lines[i]) &&
        lines[i].startsWith(' ')) {
      text.add(lines[i].trim());
      i++;
    }

    out.writeln('<li>${_inline(text.join(' '))}</li>');
  }

  out.writeln(ordered ? '</ol>' : '</ul>');
  return i;
}

List<String> _cells(String row) {
  var line = row.trim();
  if (line.startsWith('|')) line = line.substring(1);
  if (line.endsWith('|')) line = line.substring(0, line.length - 1);
  return [for (final cell in line.split('|')) cell.trim()];
}

List<String> _aligns(String delimiter) => [
  for (final cell in _cells(delimiter))
    if (cell.startsWith(':') && cell.endsWith(':'))
      'center'
    else if (cell.endsWith(':'))
      'right'
    else
      '',
];

String _alignAttr(List<String> aligns, int column) {
  if (column >= aligns.length || aligns[column].isEmpty) return '';
  return ' style="text-align:${aligns[column]}"';
}

/// Inline spans: code, links, images, bold, italic.
///
/// Code is extracted first and put back last, so that a backticked `**` is not
/// read as emphasis. Getting that the other way round turns every byte table in
/// `docs/WIRE.md` into italics.
String _inline(String text) {
  final code = <String>[];
  // The placeholder is wrapped in NULs rather than spaces. A ` 3 ` sentinel
  // matches inside any sentence containing a bare number — "the version at
  // offset 0 is repeated" would come back carrying a code span nobody wrote —
  // and docs/WIRE.md is almost entirely sentences containing bare numbers. NUL
  // cannot occur in the source and passes through _escape untouched.
  var work = text.replaceAllMapped(RegExp(r'`([^`]+)`'), (match) {
    code.add(match.group(1)!);
    return ' ${code.length - 1} ';
  });

  work = _escape(work);

  work = work.replaceAllMapped(
    RegExp(r'!\[([^\]]*)\]\(([^)\s]+)\)'),
    (m) => '<img src="${m.group(2)}" alt="${m.group(1)}">',
  );
  work = work.replaceAllMapped(
    RegExp(r'\[([^\]]+)\]\(([^)\s]+)\)'),
    (m) => '<a href="${_link(m.group(2)!)}">${m.group(1)}</a>',
  );
  work = work.replaceAllMapped(
    RegExp(r'\*\*([^*]+)\*\*'),
    (m) => '<strong>${m.group(1)}</strong>',
  );
  work = work.replaceAllMapped(
    RegExp(r'(?<![*\w])\*([^*]+)\*(?!\w)'),
    (m) => '<em>${m.group(1)}</em>',
  );

  for (var i = 0; i < code.length; i++) {
    work = work.replaceAll(' $i ', '<code>${_escape(code[i])}</code>');
  }
  return work;
}

/// Rewrites a repository-relative Markdown link to its published page.
///
/// A link to `docs/METRICS.md` has to become `metrics.html` or the site is a
/// set of pages that link to raw files on GitHub. One that points at something
/// the site does not publish is left alone and resolves on GitHub, which is
/// where a link to `engine/src/bel_spectrum.h` should go anyway.
String _link(String target) {
  if (target.startsWith('#') ||
      target.startsWith('http://') ||
      target.startsWith('https://') ||
      target.startsWith('mailto:')) {
    return target;
  }

  final anchor = target.contains('#')
      ? target.substring(target.indexOf('#'))
      : '';
  final path = anchor.isEmpty
      ? target
      : target.substring(0, target.indexOf('#'));
  final normalised = path.replaceFirst(RegExp(r'^\./'), '');

  for (final page in pages) {
    if (page.source == normalised || page.source.endsWith('/$normalised')) {
      return '${page.slug}.html$anchor';
    }
  }

  if (!path.endsWith('.md')) return target;
  return 'https://github.com/JonasGrunau/open_music_analyzer/blob/main/$path$anchor';
}

String _escape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// Markdown stripped out, for a table of contents entry.
String _plain(String text) => text
    .replaceAll(RegExp(r'[`*_]'), '')
    .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m.group(1)!);

String _slug(String text) {
  final buffer = StringBuffer();
  var dash = false;
  for (final rune in _plain(text).toLowerCase().runes) {
    final safe =
        (rune >= 0x61 && rune <= 0x7A) || (rune >= 0x30 && rune <= 0x39);
    if (safe) {
      buffer.writeCharCode(rune);
      dash = false;
    } else if (!dash && buffer.isNotEmpty) {
      buffer.write('-');
      dash = true;
    }
  }
  var slug = buffer.toString();
  while (slug.endsWith('-')) {
    slug = slug.substring(0, slug.length - 1);
  }
  return slug.isEmpty ? 'section' : slug;
}

String _uniqueId(String base, Map<String, int> used) {
  final seen = used.update(base, (n) => n + 1, ifAbsent: () => 0);
  return seen == 0 ? base : '$base-$seen';
}

// ---------------------------------------------------------------------------
// The page

String _shell(Page page, _Rendered rendered) {
  // One <ul> per section, opened when the section changes and closed when the
  // next one starts. Sectionless pages sit in an unlabelled list of their own
  // rather than being special-cased into a bare <a>, so the markup has one
  // shape and the stylesheet has one selector.
  final nav = StringBuffer();
  String? open;
  for (final other in pages) {
    if (other.section != open) {
      if (open != null) nav.writeln('</ul>');
      if (other.section.isNotEmpty) {
        nav.writeln('<h2 class="nav-section">${_escape(other.section)}</h2>');
      }
      nav.writeln('<ul>');
      open = other.section;
    }
    nav.writeln(
      '<li><a href="${other.slug}.html"'
      '${other.slug == page.slug ? ' class="here"' : ''}>'
      '${_escape(other.title)}</a></li>',
    );
  }
  if (open != null) nav.writeln('</ul>');

  final contents = StringBuffer();
  if (rendered.headings.length > 2) {
    contents.writeln('<nav class="toc"><h2>On this page</h2><ul>');
    for (final heading in rendered.headings) {
      contents.writeln(
        '<li class="l${heading.level}">'
        '<a href="#${heading.id}">${_escape(heading.text)}</a></li>',
      );
    }
    contents.writeln('</ul></nav>');
  }

  return '''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${_escape(page.title)} — Bel</title>
<meta name="description" content="${_escape(_plain(page.blurb))}">
<link rel="icon" href="data:image/svg+xml,${Uri.encodeComponent(_favicon)}">
<link rel="stylesheet" href="style.css">
</head>
<body>
<a class="skip" href="#content">Skip to content</a>
<div class="layout">
<header class="side">
  <a class="brand" href="index.html">
    $_brandMark
    <span>Bel</span>
  </a>
  <nav>$nav</nav>
  <a class="repo" href="https://github.com/JonasGrunau/open_music_analyzer">Source on GitHub</a>
</header>
<main id="content">
  <h1>${_escape(page.title)}</h1>
  <p class="blurb">${_inline(page.blurb)}</p>
  $contents
  ${rendered.body}
  <footer>
    Bel is free software. The application is GPL-3.0-or-later, the engine and
    domain model are MIT, and the plugin is AGPL-3.0-or-later —
    <a href="https://github.com/JonasGrunau/open_music_analyzer#licensing">the
    split is explained in the README</a>.
  </footer>
</main>
</div>
</body>
</html>
''';
}

/// The mark from `packaging/icon/bel.svg`, small enough to inline twice.
const String _brandMark =
    '<svg viewBox="0 0 1024 1024" width="24" height="24" aria-hidden="true">'
    '<rect x="6" y="6" width="1012" height="1012" rx="199" fill="#0B0C0E" '
    'stroke="#2E343C" stroke-width="12"/>'
    '<g fill="#35E0C4">'
    '<rect x="204.8" y="610.3" width="111.7" height="208.9"/>'
    '<rect x="372.4" y="481.3" width="111.7" height="337.9"/>'
    '<rect x="539.9" y="364.5" width="111.7" height="454.7"/>'
    '<rect x="707.5" y="204.8" width="111.7" height="614.4"/></g>'
    '<rect x="707.5" y="204.8" width="111.7" height="135.2" fill="#FF4D4D"/>'
    '</svg>';

const String _favicon =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
    '<rect width="1024" height="1024" rx="205" fill="#0B0C0E"/>'
    '<g fill="#35E0C4">'
    '<rect x="204.8" y="610.3" width="111.7" height="208.9"/>'
    '<rect x="372.4" y="481.3" width="111.7" height="337.9"/>'
    '<rect x="539.9" y="364.5" width="111.7" height="454.7"/>'
    '<rect x="707.5" y="204.8" width="111.7" height="614.4"/></g>'
    '<rect x="707.5" y="204.8" width="111.7" height="135.2" fill="#FF4D4D"/>'
    '</svg>';

/// The site's stylesheet.
///
/// The application's palette, because a documentation site that looks nothing
/// like the product is a documentation site people are not sure they are in the
/// right place on. System fonts rather than the bundled Inter and JetBrains
/// Mono: shipping two webfonts costs a quarter of a megabyte and a flash of
/// unstyled text to make a page look marginally more like an application it is
/// describing rather than being.
const String _css = r'''
:root {
  --bg: #0B0C0E;
  --panel: #121417;
  --raised: #171A1E;
  --hairline: #1F2328;
  --hairline-strong: #2E343C;
  --text: #E6E8EB;
  --muted: #8A9199;
  --faint: #565E67;
  --accent: #35E0C4;
  --over: #FF4D4D;
  --ui: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
  --mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "DejaVu Sans Mono", monospace;
}

* { box-sizing: border-box; }

html { -webkit-text-size-adjust: 100%; }

body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font-family: var(--ui);
  font-size: 16px;
  line-height: 1.65;
}

.skip {
  position: absolute;
  left: -9999px;
}
.skip:focus {
  left: 8px;
  top: 8px;
  z-index: 10;
  background: var(--accent);
  color: var(--bg);
  padding: 8px 12px;
  border-radius: 4px;
}

.layout {
  display: grid;
  grid-template-columns: 260px minmax(0, 1fr);
  gap: 48px;
  max-width: 1180px;
  margin: 0 auto;
  padding: 0 24px;
}

/* --- Sidebar --- */

.side {
  position: sticky;
  top: 0;
  align-self: start;
  height: 100vh;
  padding: 32px 0;
  display: flex;
  flex-direction: column;
  gap: 24px;
  border-right: 1px solid var(--hairline);
}

.brand {
  display: flex;
  align-items: center;
  gap: 10px;
  color: var(--text);
  text-decoration: none;
  font-weight: 600;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  font-size: 14px;
}

.side nav { flex: 1; overflow-y: auto; }

.nav-section {
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  color: var(--faint);
  margin: 20px 0 6px;
  font-weight: 600;
}

.side ul { list-style: none; margin: 0; padding: 0; }

.side li a {
  display: block;
  padding: 5px 12px 5px 0;
  color: var(--muted);
  text-decoration: none;
  font-size: 15px;
  border-left: 2px solid transparent;
  padding-left: 10px;
  margin-left: -12px;
}

.side a:hover { color: var(--text); }

.side a.here {
  color: var(--accent);
  border-left-color: var(--accent);
}

.repo {
  color: var(--faint);
  text-decoration: none;
  font-size: 13px;
  padding-top: 16px;
  border-top: 1px solid var(--hairline);
}
.repo:hover { color: var(--muted); }

/* --- Content --- */

main {
  padding: 48px 0 96px;
  min-width: 0;
}

h1 {
  font-size: 40px;
  line-height: 1.15;
  letter-spacing: -0.02em;
  margin: 0 0 8px;
}

.blurb {
  color: var(--muted);
  font-size: 18px;
  margin: 0 0 32px;
}

h2, h3, h4, h5, h6 {
  line-height: 1.3;
  letter-spacing: -0.01em;
  margin: 40px 0 12px;
  scroll-margin-top: 24px;
}
h2 {
  font-size: 26px;
  padding-bottom: 8px;
  border-bottom: 1px solid var(--hairline);
}
h3 { font-size: 20px; }
h4 { font-size: 17px; color: var(--muted); }

.anchor {
  float: left;
  margin-left: -22px;
  width: 22px;
  color: var(--faint);
  text-decoration: none;
  opacity: 0;
  transition: opacity 0.1s;
}
h2:hover .anchor, h3:hover .anchor, h4:hover .anchor { opacity: 1; }

p { margin: 0 0 16px; }

a { color: var(--accent); text-decoration-color: rgba(53, 224, 196, 0.35); }
a:hover { text-decoration-color: currentColor; }

strong { color: #fff; font-weight: 600; }

ul, ol { margin: 0 0 16px; padding-left: 24px; }
li { margin: 4px 0; }
li > ul, li > ol { margin: 4px 0; }

blockquote {
  margin: 0 0 16px;
  padding: 2px 0 2px 16px;
  border-left: 2px solid var(--hairline-strong);
  color: var(--muted);
}

hr {
  border: 0;
  border-top: 1px solid var(--hairline);
  margin: 40px 0;
}

/* Numbers are monospaced with tabular figures everywhere in Bel, and a
   documentation page full of dB values is no exception. */
code {
  font-family: var(--mono);
  font-size: 0.88em;
  font-variant-numeric: tabular-nums;
  background: var(--raised);
  border: 1px solid var(--hairline);
  border-radius: 3px;
  padding: 1px 5px;
  color: var(--text);
}

pre.code {
  background: var(--panel);
  border: 1px solid var(--hairline);
  border-radius: 6px;
  padding: 16px;
  overflow-x: auto;
  margin: 0 0 20px;
  position: relative;
}
pre.code code {
  background: none;
  border: 0;
  padding: 0;
  font-size: 13.5px;
  line-height: 1.6;
}
pre.code[data-lang]::before {
  content: attr(data-lang);
  position: absolute;
  top: 6px;
  right: 10px;
  font-size: 10px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--faint);
}

/* A wide table scrolls inside itself. The wire protocol's byte tables are
   several times wider than a phone, and a page that scrolls sideways as a
   whole is a page whose prose you cannot read. */
.scroll {
  overflow-x: auto;
  margin: 0 0 20px;
  border: 1px solid var(--hairline);
  border-radius: 6px;
}

table {
  border-collapse: collapse;
  width: 100%;
  font-size: 14.5px;
  font-variant-numeric: tabular-nums;
}
th, td {
  text-align: left;
  padding: 9px 14px;
  border-bottom: 1px solid var(--hairline);
  vertical-align: top;
}
thead th {
  background: var(--panel);
  color: var(--muted);
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  white-space: nowrap;
}
tbody tr:last-child td { border-bottom: 0; }
tbody tr:hover { background: rgba(255, 255, 255, 0.02); }

/* --- On this page --- */

.toc {
  border: 1px solid var(--hairline);
  border-radius: 6px;
  padding: 14px 18px;
  margin: 0 0 36px;
  background: var(--panel);
}
.toc h2 {
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  color: var(--faint);
  margin: 0 0 8px;
  padding: 0;
  border: 0;
}
.toc ul { list-style: none; padding: 0; margin: 0; }
.toc li { margin: 2px 0; }
.toc li.l3 { padding-left: 16px; font-size: 14px; }
.toc a { color: var(--muted); text-decoration: none; }
.toc a:hover { color: var(--accent); }

footer {
  margin-top: 64px;
  padding-top: 20px;
  border-top: 1px solid var(--hairline);
  color: var(--faint);
  font-size: 13.5px;
}

img { max-width: 100%; height: auto; }

/* --- Narrow --- */

@media (max-width: 900px) {
  .layout {
    grid-template-columns: minmax(0, 1fr);
    gap: 0;
  }
  .side {
    position: static;
    height: auto;
    border-right: 0;
    border-bottom: 1px solid var(--hairline);
    padding: 20px 0;
  }
  .side nav { overflow: visible; }
  main { padding-top: 32px; }
  h1 { font-size: 32px; }
  .anchor { display: none; }
}

@media (prefers-reduced-motion: reduce) {
  * { transition: none !important; }
}
''';
