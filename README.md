# L054 MVP — Radar Coltelli Giapponesi

Static Italian-language site testing the L054 hypothesis. Internal documentation is in English;
all customer-facing copy is Italian.

**Working brand only.** "Radar Coltelli Giapponesi" is a provisional experimental name, not a
committed identity. No logo exists — the wordmark is plain text.

## Purpose

Minimum real-world experiment for **L054 — Japanese kitchen knife availability intelligence for
Italian-speaking buyers**.

The proposition under test: *help Italian-speaking buyers discover where specialist or
harder-to-find Japanese kitchen knives are currently available, without manually checking multiple
retailers.*

The immediate question is behavioural, not technical: **do third-party users show real interest and
outbound purchase intent** before any monitoring automation is built?

## Current Scope

Static, merchant-neutral, Italian-language availability site with a small manually verified sample.

- 14 product observations, 2 independent retailers (SharpEdge, Slovenia/EUR — Hocho Knife, Japan/USD).
- Seven distinct *marchi/produttori* represented. These are a mix of workshops, brands and house
  lines; who forges each blade is **not** verified, so never describe this as "seven verified makers".
  The public column is labelled "Marchio / produttore". See `RESEARCH_NOTES.md` §4.
- Every observation carries a source URL, an observed price, an observed stock state, and a UTC timestamp.
- Rows from different retailers are listed separately and are **not** asserted to be the same product,
  even where the brand matches. No cross-merchant matching exists yet.
- Availability data loaded at runtime from `data/products.json`.
- No affiliate links, no tracking, no cookies, no forms. The site itself collects nothing; the
  contact page says plainly that emailing us means handling an email as correspondence, rather than
  claiming "we collect no personal data" outright.
- No product images (retailer image reuse rights are not documented).

Provenance for every row, plus normalization decisions and known uncertainties, is in
[`RESEARCH_NOTES.md`](RESEARCH_NOTES.md).

## Structure

```
index.html          Home — proposition, scope, limits
disponibilita.html  Core page — filterable observation table
metodologia.html    How data is gathered, normalized, and where it falls short
disclosure.html     Commercial reality: no affiliate relationship at present
contatti.html       mailto contact only
assets/styles.css   Single stylesheet, no webfonts
assets/app.js       Vanilla JS renderer, no dependencies
data/products.json  The observations
```

## Technology

Plain HTML, CSS, and vanilla JavaScript. No build step, no npm dependencies, no framework, no
backend, no database. Works as static files on GitHub Pages as-is.

**Local preview requires HTTP.** `disponibilita.html` reads `data/products.json` with `fetch()`,
which browsers block over `file://`. Serve the directory over HTTP to view it locally:

```bash
python -m http.server 8000
```

The page detects this failure and displays an explanatory message rather than an empty table.
Every other page is fully static and opens fine from disk.

## Explicitly Not Built Yet

- automated crawling
- automated stock monitoring
- database
- price-history automation
- restock alerts
- newsletter
- social automation
- affiliate integration
- analytics
- user accounts

## Product Images — Deliberately Deferred

Not added in this revision, on purpose. Reuse rights for retailer and manufacturer photography have
not been established. Photography may materially improve the later purchase-intent experiment, so the
sequence is:

1. make the site suitable for the affiliate application (current state);
2. after affiliate approval, check whether the merchants supply authorized product images or
   affiliate creatives;
3. only then decide whether to add one thumbnail per observation, before traffic testing.

This rationale is internal and is not stated on the public site.

## Measurement — Not Built Yet

The site as it stands **cannot measure outbound purchase intent**. There is no analytics, no click
tracking, and none was added.

Before any unmoderated traffic is sent to the site, the owner must define the minimum observation
mechanism. First candidate: **outbound click reporting from the affiliate platform**, once an
affiliate account is approved. Do not assume this exists — availability, granularity and reliability
of that reporting must be confirmed against the specific programme before relying on it. If it turns
out to be unavailable or untrustworthy, an alternative must be chosen deliberately rather than by
default, and running traffic without any measurement wastes the experiment.

## Current Experiment Sequence

1. build local MVP ← **current step, complete**
2. independent review
3. owner approval
4. deploy publicly
5. use public site for affiliate application if appropriate
6. verify actual affiliate terms / payout eligibility
7. run limited real-world traffic / click experiment
8. automate only if behavioral signal exists

## Owner Actions Required Before Deployment

These need a human and are deliberately not done:

1. Approve or replace the working brand name.
2. Decide the public domain or the `github.io` path.
3. Create the GitHub repository and enable Pages (account creation and settings are owner actions).
4. Once the domain is known, add absolute `canonical` and `og:url` tags — currently omitted rather
   than guessed, so no page carries a wrong URL.
5. Confirm `ltl.ventures@outlook.com` is monitored.

## Possible Later Work

Recorded, not implemented.

**Data and coverage**
- Add a third retailer, ideally Italy-based. Re-examine Nishikidôri via its French pages (its English
  titles are machine-translated), retry MyGoodKnife and Coltelleria Collini. See `RESEARCH_NOTES.md` §6.
- Introduce a distinct state for Hocho's "Out of Stock (Contact us)", which is not identical to a
  plain sold-out condition.
- Record restock and price history — only once observation is running regularly enough to be meaningful.
- Genuine cross-merchant product identity matching. This is the hard problem and is currently unsolved;
  the present dataset asserts no cross-merchant matches.

**Product**
- Per-model pages showing all retailers carrying that model — the clearest expression of the
  proposition, but only worth building if the flat table generates interest first.
- Restock notification signup — the most likely monetizable behaviour, and the most likely thing to
  over-build too early.
- Structured data (`schema.org/Offer`) for search visibility.

**Operations**
- Semi-automated re-observation script with human review before publishing.
- Convert the manual curl checks in `RESEARCH_NOTES.md` §7 into a repeatable checked-in script.

**Deliberately deferred:** scrapers, scheduled monitoring, backend, admin panel, alerting service,
recommendation engine. Nothing here should be built before step 8 of the experiment sequence.

## Guardrails Observed In This Build

- No external publication, no GitHub remote, no affiliate signup, no accounts created.
- No fabricated testimonials, users, traffic, partnerships, or certifications — the site makes no
  social-proof claims of any kind.
- No claim of real-time monitoring, complete coverage, best prices, official status, or exclusivity.
- No claim that buying direct from Japan is cheaper. Cost wording is merchant-dependent: final cost
  depends on retailer and destination, and EU vs non-EU purchases can differ on tax, shipping,
  customs and returns — stated without recommending either direction, and without asserting that
  every listed price uniformly excludes import VAT or duty.
