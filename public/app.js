(function () {
  var input = document.getElementById("filter");
  var table = document.getElementById("recent-sessions");
  if (input && table) {
    input.addEventListener("input", function () {
      var q = input.value.trim().toLowerCase();
      var rows = table.querySelectorAll("tbody tr");
      rows.forEach(function (row) {
        var hay = (row.getAttribute("data-filter") || row.textContent || "").toLowerCase();
        row.style.display = !q || hay.indexOf(q) !== -1 ? "" : "none";
      });
    });
  }

  document.querySelectorAll("[data-copy]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var sel = btn.getAttribute("data-copy");
      var el = document.querySelector(sel);
      if (!el) return;
      var text = el.textContent.trim();
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () {
          btn.textContent = "Copied";
          setTimeout(function () { btn.textContent = "Copy"; }, 1200);
        });
      }
    });
  });
})();
