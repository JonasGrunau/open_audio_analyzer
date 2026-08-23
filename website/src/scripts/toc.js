/* Marking the section you are in, in the list on the right.
 *
 * This was an IntersectionObserver, and it could not be one. The rule the list
 * wants is "the last heading to have passed under the sticky bar", and an
 * observer reports only crossings of a band. Writing "everything above a line"
 * as a band means insetting the root's bottom by 100% of its height and its top
 * by the height of the bar — which is a rectangle of *negative* height, and
 * nothing ever intersects one of those. So the callback ran once as the
 * observations were registered and never again: every page marked its first
 * heading and held that mark to the end of the document. It read as working
 * because at the top of a page the first heading is the right answer, and the
 * pages are usually opened at the top.
 *
 * What replaces it is the arithmetic itself, on `scroll`, coalesced into one
 * frame: a few dozen `getBoundingClientRect` reads with no write between them,
 * which is one layout flush during a gesture the browser is already laying out
 * for. That is the whole cost of the feature, and unlike the observer it is the
 * same cost, and the same answer, in every browser.
 */

const links = new Map(
  [...document.querySelectorAll('[data-toc]')].map((a) => [a.dataset.toc, a]),
);

const headings = [...links.keys()]
  .map((id) => document.getElementById(id))
  .filter(Boolean);

if (headings.length > 0) {
  /* The line a heading counts as reached at is the one an anchor jump leaves it
     on, so clicking an entry marks that entry and not the one above it.
     `scroll-padding-top` in global.css is where that offset is declared; the
     extra pixel is for a fractional layout, where a heading parked exactly on
     the line rounds to just under it. */
  const line = () => {
    const declared = parseFloat(
      getComputedStyle(document.documentElement).scrollPaddingTop,
    );
    return (Number.isFinite(declared) ? declared : 64) + 1;
  };

  /* Keep the mark in sight when the list is longer than the rail — only then,
     and only once it has gone out of sight, because a rail that re-centres
     itself under a reader who has just scrolled it is a rail fighting them. */
  const reveal = (link) => {
    const rail = link?.closest('.doc-rail');
    if (!rail || rail.scrollHeight <= rail.clientHeight) return;
    const top = link.offsetTop - rail.scrollTop;
    if (top >= 0 && top + link.offsetHeight <= rail.clientHeight) return;
    rail.scrollTop = link.offsetTop - rail.clientHeight / 2;
  };

  const rail = document.querySelector('.doc-toc');
  let marked = null;

  const mark = () => {
    /* Under 1240 px the list is `display: none` and there is nothing to mark,
       which is most of the scrolling this site sees. The listeners stay
       attached, because a window can be widened. Read as a height and not as
       `offsetParent`, which is null for a handful of reasons that differ by
       engine — and a wrong answer here is silence, the exact symptom this file
       was rewritten to stop producing. */
    if (!rail || rail.offsetHeight === 0) return;

    const y = line();

    /* Nothing has passed the line yet, so the reader is in the preamble; the
       first section is the honest answer, and no mark at all reads as broken. */
    let current = headings[0];
    for (const heading of headings) {
      if (heading.getBoundingClientRect().top > y) break;
      current = heading;
    }

    /* The bottom of the document, where the last heading can sit below the line
       with no scroll left to bring it up to it. Without this the entry above it
       stays marked while its section is off the top of the screen. */
    const room = document.documentElement.scrollHeight - window.innerHeight;
    if (room > 0 && room - window.scrollY < 2) {
      current = headings[headings.length - 1];
    }

    if (current === marked) return;
    marked = current;

    for (const [id, link] of links) {
      if (id === current.id) link.setAttribute('aria-current', 'location');
      else link.removeAttribute('aria-current');
    }
    reveal(links.get(current.id));
  };

  let frame = 0;
  const schedule = () => {
    if (frame) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      mark();
    });
  };

  addEventListener('scroll', schedule, { passive: true });
  addEventListener('resize', schedule);
  /* The web fonts land after this file has run and move every heading on the
     page; without these the first mark is computed against a layout that no
     longer exists, which matters for a page opened at an anchor. */
  addEventListener('load', schedule);
  document.fonts?.ready.then(schedule);

  mark();
}
