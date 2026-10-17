(function () {
  const q = new URLSearchParams(location.search);
  const only = q.get('only') || window.__only;
  const all = { K: artK, K2: artK2, L: artL, L2: artL2, L3: artL3, L4: artL4, L5: artL5, L6: artL6, L7: artL7, M: artM, M2: artMLive, N: artN, O: artO, O2: artO2, O3: artLive, P: artP, Q: artQ, R: artR, S: artS, S2: artSLive };
  Object.keys(all).forEach(k => { if (!only || only.split(',').includes(k)) all[k](); });
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => { window.__ready = true; }); else window.__ready = true;
})();
