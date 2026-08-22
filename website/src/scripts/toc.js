/* Marking the section you are in, in the list on the right.
 *
 * An IntersectionObserver rather than a scroll listener: the browser reports a
 * heading crossing the top of the window without this file running on every
 * frame, and on a document as long as the metrics reference that difference is
 * the whole cost of the feature.
 *
 * The rule is "the last heading to have passed the top", which is not what an
 * observer reports directly — it reports headings entering and leaving a band.
 * So the band is the top of the window, headings above it are remembered in
 * document order, and the current one is the last of them.
 */

const links = new Map(
  [...document.querySelectorAll('[data-toc]')].map((a) => [a.dataset.toc, a]),
);

if (links.size > 0) {
  const headings = [...links.keys()]
    .map((id) => document.getElementById(id))
    .filter(Boolean);

  const above = new Set();

  const mark = () => {
    let current = null;
    for (const heading of headings) {
      if (above.has(heading.id)) current = heading.id;
    }
    /* Nothing has passed the top yet, so the reader is in the preamble; the
       first section is the honest answer, and no mark at all reads as broken. */
    current ??= headings[0]?.id;

    for (const [id, link] of links) {
      if (id === current) link.setAttribute('data-current', '');
      else link.removeAttribute('data-current');

      if (id === current) {
        /* Keep the mark visible when the list is longer than the rail. */
        const rail = link.closest('.doc-rail');
        if (rail && rail.scrollHeight > rail.clientHeight) {
          const top = link.offsetTop - rail.clientHeight / 2;
          rail.scrollTo({ top, behavior: 'instant' });
        }
      }
    }
  };

  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        /* `boundingClientRect.top < 0` distinguishes a heading that has
           scrolled off the top from one that has not arrived from the bottom;
           both are "not intersecting". */
        if (entry.isIntersecting || entry.boundingClientRect.top < 0) {
          above.add(entry.target.id);
        } else {
          above.delete(entry.target.id);
        }
      }
      mark();
    },
    /* A band from the header's edge to the top of the window: a heading counts
       as reached the moment it clears the sticky bar. */
    { rootMargin: '-56px 0px -100% 0px', threshold: 0 },
  );

  for (const heading of headings) observer.observe(heading);
  mark();
}
