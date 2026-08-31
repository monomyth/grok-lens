(function () {
  "use strict";

  function $all(sel, root) {
    return Array.prototype.slice.call((root || document).querySelectorAll(sel));
  }

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  /* ---------- Theme ---------- */
  function systemDark() {
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
  }
  function resolveTheme(pref) {
    if (pref === "dark") return "dark";
    if (pref === "light") return "light";
    return systemDark() ? "dark" : "light";
  }
  function loadThemePref() {
    try { return localStorage.getItem("grok-lens-theme") || "system"; }
    catch (e) { return "system"; }
  }
  function applyTheme(pref) {
    pref = pref || "system";
    var resolved = resolveTheme(pref);
    var root = document.documentElement;
    root.setAttribute("data-theme", resolved);
    root.setAttribute("data-theme-pref", pref);
    root.style.colorScheme = resolved;
    try { localStorage.setItem("grok-lens-theme", pref); } catch (e) {}
    var btn = document.getElementById("theme-toggle");
    if (btn) {
      var label = pref === "system" ? "Auto" : pref === "dark" ? "Dark" : "Light";
      btn.textContent = label;
      btn.title = "Theme: " + label + " — click to cycle";
    }
  }
  applyTheme(loadThemePref());
  var themeBtn = document.getElementById("theme-toggle");
  if (themeBtn) {
    themeBtn.addEventListener("click", function () {
      var cur = loadThemePref();
      applyTheme(cur === "light" ? "dark" : cur === "dark" ? "system" : "light");
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
    try { ok = document.execCommand("copy"); } catch (e) {}
    document.body.removeChild(ta);
    return ok;
  }
  function copyText(text, btn) {
    if (!text) return;
    function done(ok) { if (btn) flashCopied(btn, ok ? "Copied" : "Failed"); }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () { done(true); }, function () { done(legacyCopy(text)); });
    } else {
      done(legacyCopy(text));
    }
  }
  document.addEventListener("click", function (ev) {
    var btn = ev.target.closest("[data-copy-text]");
    if (!btn) return;
    copyText(btn.getAttribute("data-copy-text"), btn);
  });

  /* ---------- Filters ---------- */
  function applyTextFilter() {
    var input = document.getElementById("filter");
    var q = input ? input.value.trim().toLowerCase() : "";
    $all("#recent-tbody tr[data-filter]").forEach(function (row) {
      var hay = (row.getAttribute("data-filter") || "").toLowerCase();
      row.style.display = !q || hay.indexOf(q) !== -1 ? "" : "none";
    });
  }

  function bindFilter(inputId) {
    var input = document.getElementById(inputId);
    if (!input) return;
    input.addEventListener("input", function () {
      if (inputId === "filter") {
        applyTextFilter();
        return;
      }
      var q = input.value.trim().toLowerCase();
      $all("tr[data-filter]").forEach(function (row) {
        var hay = (row.getAttribute("data-filter") || "").toLowerCase();
        row.style.display = !q || hay.indexOf(q) !== -1 ? "" : "none";
      });
    });
  }
  bindFilter("filter");
  bindFilter("glossary-filter");
  bindFilter("ext-filter");
  bindFilter("mcp-filter");

  /* ---------- Partial poll (home) ---------- */
  var body = document.body;
  var page = body.getAttribute("data-page") || "/";
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
    try { localStorage.setItem("grok-lens-poll-seconds", String(n)); } catch (e) {}
  }
  function setPollStatus(msg) {
    if (pollStatus) pollStatus.textContent = msg;
  }

  function renderActiveRow(s) {
    var sub = s.children > 0
      ? '<span class="badge">+' + s.children + ' sub' +
        (s.live_children > 0 ? ' · ' + s.live_children + ' live' : '') + '</span>'
      : '';
    var runBadge = s.running_count > 0
      ? '<span class="badge live-tasks">' + s.running_count + ' running</span>'
      : '';
    return (
      '<tr data-id="' + esc(s.id) + '">' +
      '<td><span class="dot ' + esc(s.status) + '"></span>' + esc(s.status === "active" ? "live" : s.status) +
      (s.pid ? ' <span class="muted">pid ' + esc(s.pid) + '</span>' : '') + '</td>' +
      '<td class="mono">' + esc(s.project) + '</td>' +
      '<td><a href="/sessions/' + esc(s.id) + '">' + esc(s.title) + '</a> ' +
      (s.source_label ? '<span class="badge src">' + esc(s.source_label) + '</span> ' : '') +
      sub + runBadge +
      '<div class="row actions">' +
      '<button type="button" class="btn small" data-copy-text="' + esc(s.id) + '">Id</button> ' +
      '<button type="button" class="btn small" data-copy-text="' + esc(s.resume_command) + '">Resume</button>' +
      '</div></td>' +
      '<td>' + esc(s.model) + '</td>' +
      '<td class="r num running-cell">' + (s.running_count > 0 ? s.running_count : '—') + '</td>' +
      '<td class="r num">' + esc(s.num_turns) + '</td>' +
      '<td class="r num">' + esc(s.est_tokens_label) + '</td></tr>'
    );
  }

  function renderRecentRow(s) {
    var sub = s.children > 0
      ? '<span class="badge">+' + s.children + ' sub' +
        (s.live_children > 0 ? ' · ' + s.live_children + ' live' : '') + '</span>'
      : '';
    var runBadge = s.running_count > 0
      ? '<span class="badge live-tasks">' + s.running_count + ' running</span>'
      : '';
    var ctx = s.context_tokens && s.context_label ? ' · ctx ' + esc(s.context_label) : '';
    var filter = [s.title, s.cwd, s.model, s.id, s.source_label].join(' ');
    var src = (s.source && s.source !== "grok" && s.source_label)
      ? '<span class="badge src">' + esc(s.source_label) + '</span> '
      : '';
    return (
      '<tr data-id="' + esc(s.id) + '" data-filter="' + esc(filter) + '" data-running="' + esc(s.running_count) + '" data-source="' + esc(s.source || '') + '">' +
      '<td class="age muted num">' + esc(s.last_active_rel || '—') + '</td>' +
      '<td><a href="/sessions/' + esc(s.id) + '">' + esc(s.title) + '</a> ' + src + sub + runBadge +
      '<div class="subline muted">' + esc(s.project) + ' · ' + esc(s.model) + ' · ' + esc(s.num_turns) + ' turns' + ctx + '</div>' +
      '<div class="row actions">' +
      '<button type="button" class="btn small" data-copy-text="' + esc(s.id) + '">Id</button> ' +
      '<button type="button" class="btn small" data-copy-text="' + esc(s.resume_command) + '">Resume</button> ' +
      '<a class="btn small" href="/compare?a=' + esc(s.id) + '">Compare</a>' +
      '</div></td>' +
      '<td class="r num running-cell">' + (s.running_count > 0 ? s.running_count : '—') + '</td>' +
      '<td class="r num">' + esc(s.est_tokens_label) + '</td></tr>'
    );
  }

  function setText(id, value) {
    var el = document.getElementById(id);
    if (el) el.textContent = value;
  }

  function queryFlag(name) {
    return new URLSearchParams(window.location.search).get(name);
  }

  function currentSort() {
    return queryFlag("sort") || "last_active";
  }

  function runningOnly() {
    return queryFlag("running") === "1";
  }

  function sourceFilter() {
    return queryFlag("src") || "";
  }

  function sortSessionList(list) {
    var key = currentSort();
    var copy = list.slice();
    copy.sort(function (a, b) {
      if (key === "running") {
        return (b.running_count || 0) - (a.running_count || 0);
      }
      if (key === "tokens") {
        return (b.est_tokens || 0) - (a.est_tokens || 0);
      }
      if (key === "title") {
        return String(a.title || "").localeCompare(String(b.title || ""), undefined, { sensitivity: "base" });
      }
      return String(b.last_active_at || "").localeCompare(String(a.last_active_at || ""));
    });
    return copy;
  }

  function applySnapshot(data) {
    var meta = document.getElementById("snapshot-meta");
    if (meta && data.scanned_at) {
      var d = new Date(data.scanned_at);
      var stamp = d.toISOString().replace("T", " ").replace(/\.\d+Z$/, " UTC");
      meta.textContent =
        "snapshot · " + stamp +
        (data.scan_ms != null ? " · " + data.scan_ms + "ms" : "");
    }
    setText("stat-live", data.active);
    setText("stat-stale", data.stale);
    setText("stat-running-total", data.total_running != null ? data.total_running : "—");
    setText("stat-sessions", data.primary_sessions);
    setText("stat-header-sessions", data.primary_sessions);
    setText("stat-tokens", data.total_est_tokens_label);
    setText("stat-header-tokens", data.total_est_tokens_label);
    if (data.billed_count > 0) {
      setText("stat-tokens-label", "Tokens");
      setText("stat-header-tokens-unit", "tokens");
      setText("stat-billed-count", data.billed_count);
    } else {
      setText("stat-tokens-label", "Est. tokens");
      setText("stat-header-tokens-unit", "est. tokens");
    }
    if (data.total_cost_label) setText("stat-cost", data.total_cost_label);
    if (data.bot) {
      var hasBot = (data.bot.total || 0) > 0;
      var navBot = document.getElementById("nav-bot");
      if (navBot) navBot.hidden = !hasBot;
      var botHome = document.getElementById("bot-home-block");
      if (botHome) botHome.hidden = !hasBot;
      setText("bot-home-working", data.bot.working);
      setText("bot-home-idle", data.bot.idle);
      setText("bot-home-total", data.bot.total);
      setText("bot-working-count", data.bot.working);
      setText("bot-idle-count", data.bot.idle);
    }

    var activeBlock = document.getElementById("active-block");
    var activeBody = document.getElementById("active-tbody");
    var activeList = data.active_sessions || [];
    if (activeBody) {
      activeBody.innerHTML = activeList.map(renderActiveRow).join("");
    }
    if (activeBlock) {
      activeBlock.hidden = activeList.length === 0;
    }

    var recentBody = document.getElementById("recent-tbody");
    if (recentBody && data.recent_sessions) {
      var list = data.recent_sessions.slice();
      var src = sourceFilter();
      if (src) list = list.filter(function (s) { return s.source === src; });
      if (runningOnly()) {
        list = list.filter(function (s) {
          return s.status === "active" || (s.running_count || 0) > 0;
        });
      }
      recentBody.innerHTML = sortSessionList(list).map(renderRecentRow).join("");
      applyTextFilter();
    }
  }

  function softRefresh() {
    var t0 = performance.now();
    fetch("/api/snapshot?refresh=1", { headers: { Accept: "application/json" } })
      .then(function (r) { return r.json(); })
      .then(function (data) {
        if (!data || !data.ok) return;
        var ms = Math.round(performance.now() - t0);
        if (page === "/" || page === "") applySnapshot(data);
        else {
          var meta = document.getElementById("snapshot-meta");
          if (meta && data.scanned_at) {
            var d = new Date(data.scanned_at);
            meta.textContent =
              "snapshot · " + d.toISOString().replace("T", " ").replace(/\.\d+Z$/, " UTC") +
              (data.scan_ms != null ? " · " + data.scan_ms + "ms" : "");
          }
        }
        setPollStatus(
          "Last poll " + new Date().toLocaleTimeString() +
            " · scan " + (data.scan_ms != null ? data.scan_ms + "ms" : "?") +
            " · net " + ms + "ms · " + data.active + " live · " +
            (data.total_running != null ? data.total_running + " tasks" : "")
        );
      })
      .catch(function () {
        setPollStatus("Poll failed — will retry.");
      });
  }

  function startPolling() {
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
    var secs = loadPollSeconds();
    if (pollSelect) pollSelect.value = String(secs);
    if (!secs || secs <= 0) {
      setPollStatus("usage.json when present; otherwise estimates. Polling off.");
      return;
    }
    setPollStatus("usage.json when present · auto-refresh " + (secs >= 60 ? secs / 60 + "m" : secs + "s"));
    pollTimer = setInterval(softRefresh, secs * 1000);
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
})();
