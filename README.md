# Radar Coltelli Giapponesi

A small, independent, Italian-language index of Japanese kitchen knife availability across
several retailers.

Each entry records what a retailer showed on its own public product page at a given moment:
whether the knife was available, the price shown, and the date and time of the check, with a
link back to the original listing.

**Availability and prices are point-in-time observations.** They are not live data and can
change without notice. Anything found here should be re-checked on the retailer's own site
before buying.

The project is independent and is not affiliated with any brand or retailer.

## Pages

| File | Contents |
|---|---|
| `index.html` | What the site is and how to read it |
| `disponibilita.html` | The availability index (filterable) |
| `metodologia.html` | How observations are collected, and the known limits |
| `disclosure.html` | Independence and commercial relationships |
| `contatti.html` | Contact address |

## Structure

```
assets/styles.css   single stylesheet, no webfonts
assets/app.js       vanilla JS renderer, no dependencies
data/products.json  the observations
```

Static HTML, CSS and vanilla JavaScript. No build step, no framework, no backend, no database,
no cookies and no analytics.

`disponibilita.html` loads `data/products.json` at runtime, so a browser will block it over
`file://`. To view the site locally, serve the directory over HTTP:

```bash
python -m http.server 8000
```

The other pages are fully static and open directly from disk.
