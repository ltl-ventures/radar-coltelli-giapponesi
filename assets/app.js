/* Radar Coltelli Giapponesi — availability table renderer.
 * Vanilla JS, no dependencies, no build step, no tracking.
 * Loads data/products.json and renders a table (wide screens) or cards (narrow).
 */
(function () {
  "use strict";

  var DATA_URL = "data/products.json";
  var WIDE = window.matchMedia("(min-width: 62rem)");

  var state = {
    rows: [], meta: null, mode: null, retailers: {},
    filters: { rivenditore: "", tipo: "", disponibilita: "", q: "" }
  };

  var els = {};

  function $(id) { return document.getElementById(id); }

  function init() {
    els.status = $("stato-caricamento");
    els.output = $("risultati");
    els.count = $("conteggio");
    els.controls = $("filtri");
    els.fRiv = $("f-rivenditore");
    els.fTipo = $("f-tipo");
    els.fDisp = $("f-disponibilita");
    els.fQ = $("f-ricerca");
    els.updated = $("aggiornato-il");

    if (!els.output) { return; }

    fetch(DATA_URL, { cache: "no-cache" })
      .then(function (r) {
        if (!r.ok) { throw new Error("HTTP " + r.status); }
        return r.json();
      })
      .then(onData)
      .catch(onError);
  }

  function onData(data) {
    state.meta = data.meta || {};
    state.rows = Array.isArray(data.osservazioni) ? data.osservazioni : [];

    // Short regional context per retailer, shown next to the retailer name.
    (state.meta.rivenditori || []).forEach(function (r) { state.retailers[r.id] = r; });

    // Default order is deliberately merchant-independent: grouping by retailer
    // would put one shop at the top of every view.
    state.rows.sort(function (a, b) {
      return a.produttore.localeCompare(b.produttore, "it")
        || a.tipo.localeCompare(b.tipo, "it")
        || (a.lunghezza_lama_mm - b.lunghezza_lama_mm);
    });

    if (els.status) { els.status.hidden = true; }
    if (els.controls) { els.controls.hidden = false; }
    if (els.updated && state.meta.aggiornato_il) {
      els.updated.textContent = formatDateOnly(state.meta.aggiornato_il);
    }

    fillSelect(els.fRiv, unique(state.rows, "rivenditore"));
    fillSelect(els.fTipo, unique(state.rows, "tipo"));
    fillSelect(els.fDisp, unique(state.rows, "disponibilita"));

    bind(els.fRiv, "rivenditore");
    bind(els.fTipo, "tipo");
    bind(els.fDisp, "disponibilita");
    if (els.fQ) {
      els.fQ.addEventListener("input", function () {
        state.filters.q = els.fQ.value.trim().toLowerCase();
        render();
      });
    }

    // Re-render when crossing the layout breakpoint. The MediaQueryList "change"
    // event is not fired in every environment, so a debounced resize listener
    // backs it up; render() itself is a no-op unless the layout mode changed.
    if (WIDE.addEventListener) { WIDE.addEventListener("change", render); }
    else if (WIDE.addListener) { WIDE.addListener(render); }

    var resizeTimer = null;
    window.addEventListener("resize", function () {
      if (resizeTimer) { clearTimeout(resizeTimer); }
      resizeTimer = setTimeout(render, 150);
    });

    render();
  }

  function onError(err) {
    if (els.controls) { els.controls.hidden = true; }
    if (els.status) {
      els.status.hidden = false;
      els.status.innerHTML =
        "<p><strong>Non è stato possibile caricare i dati.</strong></p>" +
        "<p>Se stai aprendo il file direttamente dal disco, il browser blocca la lettura di " +
        "<code>data/products.json</code>. Il sito deve essere servito tramite HTTP.</p>" +
        "<p class=\"meta-line\">Dettaglio tecnico: " + escapeHtml(String(err && err.message ? err.message : err)) + "</p>";
    }
  }

  function bind(el, key) {
    if (!el) { return; }
    el.addEventListener("change", function () {
      state.filters[key] = el.value;
      render();
    });
  }

  function unique(rows, key) {
    var seen = {};
    var out = [];
    rows.forEach(function (r) {
      var v = r[key];
      if (v && !seen[v]) { seen[v] = true; out.push(v); }
    });
    return out.sort(function (a, b) { return a.localeCompare(b, "it"); });
  }

  function fillSelect(el, values) {
    if (!el) { return; }
    values.forEach(function (v) {
      var o = document.createElement("option");
      o.value = v;
      o.textContent = v;
      el.appendChild(o);
    });
  }

  function visibleRows() {
    var f = state.filters;
    return state.rows.filter(function (r) {
      if (f.rivenditore && r.rivenditore !== f.rivenditore) { return false; }
      if (f.tipo && r.tipo !== f.tipo) { return false; }
      if (f.disponibilita && r.disponibilita !== f.disponibilita) { return false; }
      if (f.q) {
        var hay = [r.produttore, r.modello, r.tipo, r.acciaio, r.rivenditore].join(" ").toLowerCase();
        if (hay.indexOf(f.q) === -1) { return false; }
      }
      return true;
    });
  }

  function render() {
    var rows = visibleRows();
    state.mode = WIDE.matches ? "table" : "cards";

    if (els.count) {
      els.count.textContent = rows.length === state.rows.length
        ? rows.length + " osservazioni"
        : rows.length + " di " + state.rows.length + " osservazioni";
    }

    if (!rows.length) {
      els.output.innerHTML = "<p>Nessuna osservazione corrisponde ai filtri selezionati.</p>";
      return;
    }

    els.output.innerHTML = WIDE.matches ? tableHtml(rows) : cardsHtml(rows);
  }

  /* ---------- renderers ---------- */

  function tableHtml(rows) {
    var head =
      "<thead><tr>" +
      "<th scope=\"col\">Marchio / produttore</th>" +
      "<th scope=\"col\">Tipo</th>" +
      "<th scope=\"col\">Acciaio</th>" +
      "<th scope=\"col\">Lama</th>" +
      "<th scope=\"col\">Rivenditore</th>" +
      "<th scope=\"col\">Disponibilità osservata</th>" +
      "<th scope=\"col\">Prezzo osservato</th>" +
      "<th scope=\"col\">Ultimo controllo</th>" +
      "<th scope=\"col\">Scheda</th>" +
      "</tr></thead>";

    var body = rows.map(function (r) {
      return "<tr>" +
        "<td><span class=\"maker\">" + escapeHtml(r.produttore) + "</span>" +
        "<span class=\"model\">" + escapeHtml(r.modello) + "</span></td>" +
        "<td>" + escapeHtml(r.tipo) + "</td>" +
        "<td>" + escapeHtml(r.acciaio) + "</td>" +
        "<td class=\"num\">" + lengthHtml(r) + "</td>" +
        "<td>" + retailerHtml(r) + "</td>" +
        "<td>" + availHtml(r.disponibilita) + "</td>" +
        "<td class=\"num\">" + formatPrice(r.prezzo, r.valuta) + "</td>" +
        "<td>" + formatStamp(r.ultimo_controllo) + "</td>" +
        "<td>" + linkHtml(r) + "</td>" +
        "</tr>";
    }).join("");

    return "<div class=\"table-scroll\"><table class=\"obs\">" +
      "<caption>Disponibilità e prezzo rilevati sul sito del rivenditore alla data indicata in ogni riga.</caption>" +
      head + "<tbody>" + body + "</tbody></table></div>";
  }

  function cardsHtml(rows) {
    var items = rows.map(function (r) {
      // Heading carries brand + line + shape + length, which is unique per row;
      // several rows otherwise share a brand and even a shape and length.
      // Any parenthetical handle detail drops to the line below instead of
      // repeating inside the heading.
      var line = r.modello.split(" (")[0];
      var detail = r.modello.indexOf(" (") > -1
        ? r.modello.slice(r.modello.indexOf(" (") + 2).replace(/\)$/, "")
        : "";
      return "<li class=\"card\">" +
        "<h3>" + escapeHtml(r.produttore) + " " + escapeHtml(line) + " — " +
          escapeHtml(r.tipo) + " " + escapeHtml(String(r.lunghezza_lama_mm)) + " mm</h3>" +
        (detail ? "<p class=\"model\">" + escapeHtml(detail) + "</p>" : "") +
        "<dl>" +
        "<dt>Acciaio</dt><dd>" + escapeHtml(r.acciaio) + "</dd>" +
        "<dt>Lama</dt><dd>" + lengthHtml(r) + "</dd>" +
        "<dt>Rivenditore</dt><dd>" + retailerHtml(r) + "</dd>" +
        "<dt>Disponibilità</dt><dd>" + availHtml(r.disponibilita) + "</dd>" +
        "<dt>Ultimo controllo</dt><dd>" + formatStamp(r.ultimo_controllo) + "</dd>" +
        "</dl>" +
        "<div class=\"card-foot\">" +
        "<span class=\"price\"><span class=\"sr-only\">Prezzo osservato: </span>" +
          formatPrice(r.prezzo, r.valuta) + "</span>" +
        linkHtml(r) +
        "</div>" +
        "</li>";
    }).join("");

    return "<ul class=\"cards\">" + items + "</ul>";
  }

  function linkHtml(r) {
    return "<a href=\"" + escapeHtml(r.url) + "\" rel=\"noopener nofollow external\" target=\"_blank\">" +
      "Vedi sul sito del rivenditore" +
      "<span class=\"sr-only\"> — " + escapeHtml(r.produttore + " " + r.modello) + " (si apre in una nuova scheda)</span>" +
      "</a>";
  }

  // Blade length. Some sources quote a nominal designation and a shorter
  // cutting edge; where they differ the row carries a short qualifier.
  function lengthHtml(r) {
    var s = escapeHtml(String(r.lunghezza_lama_mm)) + " mm";
    if (r.lunghezza_nota) {
      s += " <span class=\"qualifier block\">(" + escapeHtml(r.lunghezza_nota) + ")</span>";
    }
    return s;
  }

  function retailerHtml(r) {
    var meta = state.retailers[r.rivenditore_id];
    var s = escapeHtml(r.rivenditore);
    if (meta && meta.contesto) {
      s += "<span class=\"qualifier block\">" + escapeHtml(meta.contesto) + "</span>";
    }
    return s;
  }

  function availHtml(v) {
    var cls = "avail-unsure";
    if (v === "Disponibile") { cls = "avail-ok"; }
    else if (v === "Esaurito") { cls = "avail-out"; }
    return "<span class=\"avail " + cls + "\">" + escapeHtml(v) + "</span>";
  }

  /* ---------- formatting ---------- */

  function formatPrice(value, currency) {
    if (typeof value !== "number") { return "n.d."; }
    try {
      return new Intl.NumberFormat("it-IT", {
        style: "currency", currency: currency || "EUR", minimumFractionDigits: 2
      }).format(value);
    } catch (e) {
      return value.toFixed(2) + " " + (currency || "");
    }
  }

  function formatStamp(iso) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) { return escapeHtml(String(iso)); }
    var s = new Intl.DateTimeFormat("it-IT", {
      day: "2-digit", month: "2-digit", year: "numeric",
      hour: "2-digit", minute: "2-digit", timeZone: "UTC"
    }).format(d);
    return "<time datetime=\"" + escapeHtml(iso) + "\">" + s + " UTC</time>";
  }

  function formatDateOnly(iso) {
    var d = new Date(iso + "T00:00:00Z");
    if (isNaN(d.getTime())) { return iso; }
    return new Intl.DateTimeFormat("it-IT", {
      day: "numeric", month: "long", year: "numeric", timeZone: "UTC"
    }).format(d);
  }

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
