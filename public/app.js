(function () {
  "use strict";

  function $all(sel, root) {
    return Array.prototype.slice.call((root || document).querySelectorAll(sel));
  }

  /* ---------- Theme: single cycle button light → dark → system ---------- */
  function systemDark() {
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
  }

  function resolveTheme(pref) {
    if (pref === "dark") return "dark";
    if (pref === "light") return "light";
    return systemDark() ? "dark" : "light";
  }

  function applyTheme(pref) {
    pref = pref || "system";
    var resolved = resolveTheme(pref);
    var root = document.documentElement;
    root.setAttribute("data-theme", resolved);
    root.setAttribute("data-theme-pref", pref);
    root.style.colorScheme = resolved;
    try {
      localStorage.setItem("grok-lens-theme", pref);
    } catch (e) {}
    var btn = document.getElementById("theme-toggle");
    if (btn) {
      var label = pref === "system" ? "Auto" : pref === "dark" ? "Dark" : "Light";
      btn.textContent = label;
      btn.setAttribute("aria-label", "Theme: " + label + " (click to cycle)");
      btn.title = "Theme: " + label + " — click to cycle light / dark / system";
    }
  }

  function loadThemePref() {
    try {
      return localStorage.getItem("grok-lens-theme") || "system";
    } catch (e) {
      return "system";
    }
  }

  applyTheme(loadThemePref());

  var themeBtn = document.getElementById("theme-toggle");
  if (themeBtn) {
    themeBtn.addEventListener("click", function () {
      var cur = loadThemePref();
      var next = cur === "light" ? "dark" : cur === "dark" ? "system" : "light";
      applyTheme(next);
    });
  }

  if (window.matchMedia) {
    window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", function () {
      if (loadThemePref() === "system") applyTheme("system");
    });
  }

  /* ---------- Clipboard ---------- */
  function flashCopied(btn, label) {
    var prev = btn.getAttribute("data-label") || btn.textContent;
    btn.setAttribute("data-label", prev);
    btn.textContent = label || "Copied";
    btn.classList.add("copied");
    setTimeout(function () {
      btn.textContent = btn.getAttribute("data-label") || prev;
      btn.classList.remove("copied");
    }, 1200);
  }

  function legacyCopy(text) {
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.left = "-9999px";
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try {
      ok = document.execCommand("copy");
    } catch (e) {
      ok = false;
    }
    document.body.removeChild(ta);
    return ok;
  }

  function copyText(text, btn) {
    if (!text) return;
    function done(ok) {
      if (btn) flashCopied(btn, ok ? "Copied" : "Failed");
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(
        function () { done(true); },
        function () { done(legacyCopy(text)); }
      );
    } else {
      done(legacyCopy(text));
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
        : [input.closest("main") || document];
      roots.forEach(function (root) {
        $all("tr[data-filter]", root).forEach(function (row) {
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
      "Estimates only · auto-refresh " +
        (secs >= 60 ? secs / 60 + "m" : secs + "s")
    );
    pollTimer = setInterval(softRefresh, secs * 1000);
  }

  function softRefresh() {
    var page = body.getAttribute("data-page") || "/";
    var t0 = performance.now();
    fetch("/api/snapshot?refresh=1", { headers: { Accept: "application/json" } })
      .then(function (r) { return r.json(); })
      .then(function (data) {
        if (!data || !data.ok) return;
        var ms = Math.round(performance.now() - t0);
        var meta = document.getElementById("snapshot-meta");
        if (meta && data.scanned_at) {
          var d = new Date(data.scanned_at);
          var stamp = d.toISOString().replace("T", " ").replace(/\.\d+Z$/, " UTC");
          meta.textContent =
            "snapshot · " + stamp +
            (data.scan_ms != null ? " · " + data.scan_ms + "ms" : "") +
            " · net " + ms + "ms";
        }
        var ss = document.getElementById("stat-sessions");
        var sp = document.getElementById("stat-projects");
        var st = document.getElementById("stat-tokens");
        if (ss) ss.textContent = data.primary_sessions;
        if (sp) sp.textContent = data.projects;
        if (st) st.textContent = data.total_est_tokens_label;
        setPollStatus(
          "Last poll " + new Date().toLocaleTimeString() +
            " · scan " + (data.scan_ms != null ? data.scan_ms + "ms" : "?") +
            " · " + data.active + " live"
        );
        if (page === "/") {
          var sig =
            data.primary_sessions + ":" + data.active + ":" +
            data.stale + ":" + data.total_est_tokens;
          var prev = body.getAttribute("data-home-sig");
          if (prev && prev !== sig && prev.indexOf(":init") === -1) {
            body.setAttribute("data-home-sig", sig);
            window.location.reload();
            return;
          }
          body.setAttribute("data-home-sig", sig);
        }
      })
      .catch(function () {
        setPollStatus("Poll failed — will retry.");
      });
  }

  if (pollSelect) {
    var initial = loadPollSeconds();
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

  if ((body.getAttribute("data-page") || "/") === "/") {
    var ss0 = document.getElementById("stat-sessions");
    if (ss0) body.setAttribute("data-home-sig", ss0.textContent.trim() + ":init");
  }
})();
