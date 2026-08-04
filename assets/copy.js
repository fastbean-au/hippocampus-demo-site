// Copy-to-clipboard for the command boxes. Loaded deferred so the DOM is ready.
// Each button lives inside a .codeblock-wrap next to a <pre><code>; clicking it
// copies that code's text and briefly flips the icon to a checkmark.
(function () {
  "use strict";

  var RESET_MS = 1600;

  function wire(btn) {
    btn.addEventListener("click", function () {
      var wrap = btn.closest(".codeblock-wrap");
      var code = wrap && wrap.querySelector("code");

      if (!code) {
        return;
      }

      var text = code.textContent;

      if (!navigator.clipboard || !navigator.clipboard.writeText) {
        return;
      }

      navigator.clipboard.writeText(text).then(function () {
        btn.classList.add("copied");
        btn.setAttribute("aria-label", "Copied");

        window.setTimeout(function () {
          btn.classList.remove("copied");
          btn.setAttribute("aria-label", "Copy command");
        }, RESET_MS);
      });
    });
  }

  var btns = document.querySelectorAll(".copy-btn");

  for (var i = 0; i < btns.length; i++) {
    wire(btns[i]);
  }
})();
