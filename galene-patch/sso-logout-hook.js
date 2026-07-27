'use strict';
// The room's own "Logout" button (id="disconnectbutton", from galene.js)
// only ever closed the WebSocket connection to the current call — it never
// touched the Authelia session, so re-entering any room instantly
// reconnected the same identity with no real login prompt. Adding an
// extra click listener here (not replacing galene's own handler, which
// still runs first and disconnects the call) also ends the real SSO
// session and sends the browser to the actual unified login page.
(function () {
  var btn = document.getElementById('disconnectbutton');
  if (!btn) return;
  btn.addEventListener('click', function () {
    fetch('/authelia/api/logout', { method: 'POST', credentials: 'include' })
      .catch(function () {})
      .then(function () {
        window.location.href = '/meetings/';
      });
  });
})();
