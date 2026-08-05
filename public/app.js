(function () {
  "use strict";

  function $(sel, root) {
    return (root || document).querySelector(sel);
  }

  function $all(sel, root) {
    return Array.prototype.slice.call((root || document).querySelectorAll(sel));
  }

  /* ---------- Theme: light / dark / system ---------- */
  function systemDark() {
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
  }

  function applyTheme(pref) {
    pref = pref || "system";
    var dark = pref === "dark" || (pref === "system" && systemDark());
    document.documentElement.setAttribute("data-theme", dark ? "dark" : "light");
    document.documentElement.setAttribute("data-theme-pref", pref);
    try {
      localStorage.setItem("grok-lens-theme", pref);
    } catch (e) {}
    $all(".theme-btn").forEach(function (btn) {
      btn.classList.toggle("active", btn.getAttribute("data-theme-set") === pref);
    });
  }

  applyTheme(
    (function () {
      try {
        return localStorage.getItem("grok-lens-theme") || "system";
      } catch (e) {
        return "system";
      }
    })()
  );

  $all("[data-theme-set]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      applyTheme(btn.getAttribute("data-theme-set"));
    });
  });

  if (window.matchMedia) {
    window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", function () {
      var pref =
        document.documentElement.getAttribute("data-theme-pref") || "system";
      if (pref === "system") applyTheme("system");
    });
  }

  /* ---------- Clipboard ---------- */
  function flashCopied(btn, label) {
    var prev = btn.textContent;
    btn.textContent = label || "Copied";
    btn.classList.add("copied");
    setTimeout(function () {
      btn.textContent = prev;
      btn.classList.remove("copied");
    }, 1200);
  }

  function copyText(text, btn) {
    if (!text) return;
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () {
        if (btn) flashCopied(btn);
      });
    } else {
      var ta = document.createElement("textarea");
      ta.value = text;
      document.body.appendChild(ta);
      ta.select();
      try {
        document.execCommand("copy");
        if (btn) flashCopied(btn);
      } catch (e) {}
      document.body.removeChild(ta);
    }
  }

  document.addEventListener("click", function (ev) {
    var btn = ev.target.closest("[data-copy-text], [data-copy]");
    if (!btn) return;
    if (btn.hasAttribute("data-copy-text")) {
      copyText(btn.getAttribute("data-copy-text"), btn);
      return;
    }
    var sel = btn.getAttribute("data-copy");
    var el = sel ? document.querySelector(sel) : null;
    if (el) copyText(el.textContent.trim(), btn);
  });

  /* ---------- Table filters ---------- */
  function bindFilter(inputId, tableSelector) {
    var input = document.getElementById(inputId);
    if (!input) return;
    input.addEventListener("input", function () {
      var q = input.value.trim().toLowerCase();
      var roots = tableSelector
        ? $all(tableSelector)
        : [input.closest("section") || document];
      roots.forEach(function (root) {
        $all("tbody tr[data-filter], tr[data-filter]", root).forEach(function (row) {
          var hay = (row.getAttribute("data-filter") || "").toLowerCase();
          row.style.display = !q || hay.indexOf(q) !== -1 ? "" : "none";
        });
      });
    });
  }

  bindFilter("filter", "#recent-sessions");
  bindFilter("glossary-filter", ".glossary-table");
  bindFilter("ext-filter", null);

  /* ---------- Live polling ---------- */
  var body = document.body;
  var defaultPoll = parseInt(body.getAttribute("data-poll-default") || "300", 10);
  var pollSelect = document.getElementById("poll-interval");
  var pollTimer = null;
  var pollStatus = document.getElementById("poll-status");

  function loadPollSeconds() {
    try {
      var stored = localStorage.getItem("grok-lens-poll-seconds");
      if (stored !== null && stored !== "") return parseInt(stored, 10);
    } catch (e) {}
    return defaultPoll;
  }

  function savePollSeconds(n) {
    try {
      localStorage.setItem("grok-lens-poll-seconds", String(n));
    } catch (e) {}
  }

  function setPollStatus(msg) {
    if (pollStatus) pollStatus.textContent = msg;
  }

  function startPolling() {
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
    var secs = loadPollSeconds();
    if (pollSelect) pollSelect.value = String(secs);
    if (!secs || secs <= 0) {
      setPollStatus("Token figures are estimates (not API usage). Polling off.");
      return;
    }
    setPollStatus(
      "Token figures are estimates. Auto-refresh every " +
        (secs >= 60 ? secs / 60 + "m" : secs + "s") +
        "."
    );
    pollTimer = setInterval(function () {
      softRefresh();
    }, secs * 1000);
  }

  function softRefresh() {
    // Only auto-refresh home page content via API; other pages just update meta if needed
    var page = body.getAttribute("data-page") || "/";
    var url = "/api/snapshot?refresh=1";
    var t0 = performance.now();
    fetch(url, { headers: { Accept: "application/json" } })
      .then(function (r) {
        return r.json();
      })
      .then(function (data) {
        if (!data || !data.ok) return;
        var ms = Math.round(performance.now() - t0);
        var meta = document.getElementById("snapshot-meta");
        if (meta && data.scanned_at) {
          var d = new Date(data.scanned_at);
          var stamp =
            d.toISOString().replace("T", " ").replace(/\.\d+Z$/, " UTC");
          meta.textContent =
            "snapshot · " +
            stamp +
            (data.scan_ms != null ? " · " + data.scan_ms + "ms" : "") +
            " · net " +
            ms +
            "ms";
        }
        var ss = document.getElementById("stat-sessions");
        var sp = document.getElementById("stat-projects");
        var st = document.getElementById("stat-tokens");
        if (ss) ss.textContent = data.primary_sessions;
        if (sp) sp.textContent = data.projects;
        if (st) st.textContent = data.total_est_tokens_label;
        setPollStatus(
          "Last poll " +
            new Date().toLocaleTimeString() +
            " · scan " +
            (data.scan_ms != null ? data.scan_ms + "ms" : "?") +
            " · round-trip " +
            ms +
            "ms. Estimates only."
        );
        // Full home re-render is complex; reload when counts change on home
        if (page === "/" && body.getAttribute("data-home-sig")) {
          var sig =
            data.primary_sessions +
            ":" +
            data.active +
            ":" +
            data.stale +
            ":" +
            data.total_est_tokens;
          if (sig !== body.getAttribute("data-home-sig")) {
            body.setAttribute("data-home-sig", sig);
            window.location.reload();
          }
        } else if (page === "/") {
          body.setAttribute(
            "data-home-sig",
            data.primary_sessions +
              ":" +
              data.active +
              ":" +
              data.stale +
              ":" +
              data.total_est_tokens
          );
        }
      })
      .catch(function () {
        setPollStatus("Poll failed — will retry on next interval.");
      });
  }

  if (pollSelect) {
    var initial = loadPollSeconds();
    // ensure option exists
    if (![].some.call(pollSelect.options, function (o) { return o.value === String(initial); })) {
      var opt = document.createElement("option");
      opt.value = String(initial);
      opt.textContent = initial + "s";
      pollSelect.appendChild(opt);
    }
    pollSelect.value = String(initial);
    pollSelect.addEventListener("change", function () {
      var n = parseInt(pollSelect.value, 10);
      savePollSeconds(n);
      startPolling();
      if (n > 0) softRefresh();
    });
  }

  startPolling();

  // Seed home signature without forcing reload
  if ((body.getAttribute("data-page") || "/") === "/") {
    softRefresh();
  }
})();
