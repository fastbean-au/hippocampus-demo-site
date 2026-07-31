/* Theme handling: honour a saved choice, else the OS preference.
   This script is loaded in <head> (not deferred) so the theme is applied
   before first paint, avoiding a flash of the wrong palette. */
(function () {
  "use strict";

  var STORAGE_KEY = "hc-theme";
  var root = document.documentElement;

  function preferred() {
    try {
      var saved = localStorage.getItem(STORAGE_KEY);

      if (saved === "light" || saved === "dark") {
        return saved;
      }
    } catch (e) {
      /* storage unavailable — fall through to the OS preference */
    }

    return window.matchMedia("(prefers-color-scheme: light)").matches
      ? "light"
      : "dark";
  }

  function apply(theme) {
    root.setAttribute("data-theme", theme);
  }

  // Apply immediately so there is no flash before the body renders.
  apply(preferred());

  document.addEventListener("DOMContentLoaded", function () {
    var toggle = document.getElementById("theme-toggle");

    if (!toggle) {
      return;
    }

    toggle.addEventListener("click", function () {
      var next = root.getAttribute("data-theme") === "dark" ? "light" : "dark";

      apply(next);

      try {
        localStorage.setItem(STORAGE_KEY, next);
      } catch (e) {
        /* storage unavailable — the choice simply will not persist */
      }
    });
  });

  // Track OS changes only while the user has made no explicit choice.
  window
    .matchMedia("(prefers-color-scheme: light)")
    .addEventListener("change", function (event) {
      try {
        if (localStorage.getItem(STORAGE_KEY)) {
          return;
        }
      } catch (e) {
        /* storage unavailable — assume no saved choice */
      }

      apply(event.matches ? "light" : "dark");
    });
})();
