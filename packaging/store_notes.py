"""store_notes.py — one release's changelog section, fitted to a store's field.

SPDX-License-Identifier: GPL-3.0-or-later

Usage:  python3 packaging/store_notes.py CHANGELOG.md 0.13.0 500 [more-url]

Prints the notes as a **JSON string**, or nothing at all when the changelog has
no section for that version. JSON because both callers embed the result in a
request body, and a store note is the one piece of text here that arrives from
a file and can contain anything a person typed.

---------------------------------------------------------------------------
Two stores, one text, and why it is generated rather than written

Google Play's "What's new" field holds 500 characters and App Store Connect's
"What to Test" and "What's New" hold 4000. A note written by hand for each of
them is a third and fourth copy of what CHANGELOG.md already says, kept in step
by nobody; the first one to go stale is the one nobody reads, and both of them
are read by people deciding whether to install.

So the notes are the release's own changelog section, fitted. `publish` puts
that same section on the GitHub release unaltered — this is the same text with
a budget.

---------------------------------------------------------------------------
The rules, all of them readings of *this* CHANGELOG.md

**Whole entries first.** With 4000 characters most releases fit entirely, and
an entry as written is better than any summary of it. Only when the whole
section will not fit does anything get shortened, which is every release at
Play's 500 and almost none at Apple's 4000.

**An entry's bold lead is its short form.** This repository writes the point in
bold and the reasoning after it, so the lead is at once the shortest form of an
entry and the author's own summary of it: "**The smallest supported window is
now 960x808**, up from 960x768 (macOS; the only platform that enforces one).
The canvas is a fixed 24x16 cells, so…" gives up 335 characters for nothing. An
entry with no bold lead falls back to its first sentence, which CHANGELOG.md's
rules make a fair summary of one — an entry "describes the effect on the user,
not the diff".

The useful half of that: **bolding an entry's lead is how a change reaches a
store**, with no second place for the text to live and nothing to keep in step.

**Bold entries are taken first, and the sections are filled a turn at a time.**
Straight changelog order is what sent 0.13.0 to Play as four Added bullets with
every fix behind the cut: one long section spends the budget before the next is
reached, and what somebody deciding to install wants is usually what was
*fixed*. An entry too long for what is left is stepped over rather than ending
the pass, so one 140-character bullet costs its own place and nobody else's.

**Nothing is cut mid-sentence.** Whole entries are selected. The one truncation
left is for a single entry longer than the entire budget, where an ellipsis
beats no notes at all; no released version has one.
"""

import json
import re
import sys


def section_of(path, version):
    """The lines between this version's heading and the next one."""
    lines, inside = [], False
    for line in open(path, encoding="utf-8"):
        if line.startswith("## [" + version + "]"):
            inside = True
            continue
        if inside and line.startswith("## ["):
            break
        if inside:
            lines.append(line.rstrip())
    return lines


def parse(lines):
    """`[(label, [entry, ...]), ...]` in changelog order.

    Bullets are unwrapped, because CHANGELOG.md is hard-wrapped at 80 columns
    and both stores render this text exactly as it arrives — the breaks would
    land mid-phrase on a phone.
    """
    sections, entries, label, current = [], None, None, None

    def flush_entry():
        nonlocal current
        if current is not None:
            entries.append(current)
            current = None

    def flush_section():
        nonlocal entries, label
        flush_entry()
        if label is not None and entries:
            sections.append((label, entries))
        entries, label = None, None

    for line in lines:
        # A heading keeps its name and loses its emoji, matched as `\S+` rather
        # than at a fixed width: an emoji is one code point here and two
        # somewhere else, and counting them is how "### <emoji> Measurement"
        # reaches a store as raw markdown.
        heading = re.match(r"^#{3,4}\s+(?:\S+\s+)?(.+)$", line)
        if heading:
            flush_section()
            label, entries = heading.group(1).strip(), []
        elif entries is None:
            continue
        elif line.startswith("- "):
            flush_entry()
            current = line[2:]
        elif line.strip() and current is not None:
            current += " " + line.strip()
        elif not line.strip():
            flush_entry()
    flush_section()

    # The Internal section is refactors, build and CI, and CHANGELOG.md puts it
    # last "because most readers stop before it". A store listing is the one
    # place where that is not a figure of speech: somebody deciding whether to
    # install an app does not want a note about a screenshot script.
    return [s for s in sections if s[0].lower() != "internal"]


def plain(entry):
    """Markdown out, prose in. Emphasis last, so a bold lead can be found."""
    entry = re.sub(r"\s*\(#\d+\)", "", entry)              # issue references
    entry = re.sub(r"\[([^]]+)\]\([^)]+\)", r"\1", entry)  # links to their text
    return entry


def strip(entry):
    entry = re.sub(r"[*`]", "", entry).strip()             # emphasis, code ticks
    if entry and entry[-1] not in ".!?":
        entry += "."
    return entry


def shorten(entry):
    """One line out of an entry written for a changelog, and whether it led in
    bold — which is what decides the order entries are taken in."""
    entry = plain(entry)
    lead = re.match(r"\*\*(.+?)\*\*", entry)
    if lead:
        entry = lead.group(1)
    else:
        # Split on the full stop *and the space after it*, which is what keeps
        # a version number whole: "0.11.0" has a digit after the point rather
        # than a space. Not "a full stop and a capital" — 0.10.1's second
        # sentence opens on a code span, so that rule found no boundary at all
        # and sent 300 characters of build reasoning to a store.
        entry = re.split(r"(?<=[.!?])\s+", entry, maxsplit=1)[0]
    return strip(entry), bool(lead)


def fit(sections, budget):
    """Fill `budget` characters: bold entries first, round-robin by section.

    `kept` holds each entry with its position, so a section renders in
    changelog order however the two sweeps reached it.
    """
    kept = [[] for _ in sections]
    length, dropped = 0, False
    for tier in (True, False):
        depth = 0
        while any(depth < len(entries) for _, entries in sections):
            for index, (label, entries) in enumerate(sections):
                if depth >= len(entries):
                    continue
                entry, bold = entries[depth]
                if bold is not tier:
                    continue
                heading = 0 if kept[index] else len(label) + 2   # "Label:\n"
                cost = heading + len(entry) + 3                  # "- " and "\n"
                if length + cost > budget:
                    dropped = True
                    continue
                kept[index].append((depth, entry))
                length += cost
            depth += 1
    return [sorted(taken) for taken in kept], dropped


def render(sections, kept):
    lines = []
    for (label, _), taken in zip(sections, kept):
        if taken:
            lines.append(label + ":")
            lines += ["- " + entry for _, entry in taken]
    return "\n".join(lines).strip()


def notes(path, version, limit, more=""):
    sections = parse(section_of(path, version))

    # Whole entries, if the budget can hold the lot. Apple's 4000 usually can;
    # Play's 500 never has.
    whole = [(label, [(strip(plain(e)), True) for e in entries])
             for label, entries in sections]
    whole = [s for s in whole if s[1]]
    if whole:
        kept, dropped = fit(whole, limit)
        if not dropped:
            return render(whole, kept)

    sections = [(label, [e for e in map(shorten, entries) if e[0]])
                for label, entries in sections]
    sections = [s for s in sections if s[1]]
    if not sections:
        return ""

    # The link is paid for only when something was left behind: it costs 55 of
    # Play's 500, which is a whole entry. A release whose changelog fits says
    # so by linking nowhere.
    kept, dropped = fit(sections, limit)
    if dropped and more:
        kept, _ = fit(sections, limit - len(more) - 2)
    text = render(sections, kept)

    if not text:
        head = sections[0][1][0][0][: limit - (len(more) + 2 if more else 0)]
        text = head[: head.rfind(" ")].rstrip(" ,;:") + "…"
        dropped = True

    if dropped and more:
        text += "\n\n" + more
    return text


if __name__ == "__main__":
    text = notes(
        sys.argv[1],
        sys.argv[2],
        int(sys.argv[3]),
        sys.argv[4] if len(sys.argv) > 4 else "",
    )
    sys.stdout.write(json.dumps(text) if text else "")
