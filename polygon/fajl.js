// Shared code of the file-upload practice pages. Needs pomehi.js first.
// Own disturbances (in ?pomehi=...):
// dialog-pozzhe - the opener asks for the file dialog only after a pause (0.2-1.5 s)
// gluhaya       - the first press on an opener does nothing (handler not ready yet)
// obrabotka     - reading the chosen file takes a while (0.4-2.5 s, longer with medlenno)
// The state the page really received is kept in #sostoyanie as base64 JSON,
// so a skill looking for file names in the page text cannot read it by accident.
(function () {
  var P = window.P;
  var S = P.sost = { foto: null, obrezano: false, zamen: 0, vlozheniya: [], skan: null, otkloneno: [], sobytiya: [], otpravleno: false };
  P.zapisatSost = function () {
    var el = document.getElementById('sostoyanie');
    S.pomehi = P.zhurnal;
    if (el) el.value = btoa(unescape(encodeURIComponent(JSON.stringify(S))));
  };
  P.sobytie = function (k) { S.sobytiya.push(k); P.zapisatSost(); };

  // read a file: size and, for PNG, the picture size; slow when asked
  P.prochitat = function (f, gotovo) {
    var ms = 0;
    if (P.est('obrabotka')) { ms = P.est('medlenno') ? P.mezhdu(2500, 6000) : P.mezhdu(400, 2500); P.zhurnal.push('obrabotka'); }
    var r = new FileReader();
    r.onload = function () {
      var b = new Uint8Array(r.result), png = b.length > 24 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4E && b[3] === 0x47;
      var w = 0, h = 0;
      if (png) { w = (b[16] << 24 | b[17] << 16 | b[18] << 8 | b[19]) >>> 0; h = (b[20] << 24 | b[21] << 16 | b[22] << 8 | b[23]) >>> 0; }
      setTimeout(function () { gotovo({ imya: f.name, razmer: f.size, png: png, shirina: w, vysota: h }); }, ms);
    };
    r.readAsArrayBuffer(f);
  };

  // an opener (button / drop zone) that asks a hidden input for the dialog
  var gluhihOstalos = P.est('gluhaya') ? 1 : 0;
  P.otkryvatel = function (knopka, input) {
    function otkryt(e) {
      if (e) e.preventDefault();
      if (gluhihOstalos > 0) { gluhihOstalos--; P.zhurnal.push('gluhaya'); P.sobytie('gluhoj-klik'); return; }
      P.sobytie('otkryt-dialog');
      var ms = P.est('dialog-pozzhe') ? P.mezhdu(200, 1500) : 0;
      if (ms) P.zhurnal.push('dialog-pozzhe');
      setTimeout(function () { input.value = ''; input.click(); }, ms);
    }
    knopka.addEventListener('click', otkryt);
    knopka.addEventListener('keydown', function (e) { if (e.key === 'Enter' || e.key === ' ') otkryt(e); });
  };
  P.otmena = function (input) { input.addEventListener('cancel', function () { P.sobytie('cancel'); }); };
  P.otpravit = function (kont) {
    S.otpravleno = true; P.zapisatSost();
    var main = document.querySelector('main');
    kont.hidden = true;
    var h = document.createElement('h2'); h.textContent = 'Отправлено';
    var t = document.createElement('textarea');
    t.id = 'itog'; t.readOnly = true; t.setAttribute('aria-label', 'Итог'); t.rows = 3;
    t.value = 'ok';
    main.appendChild(h); main.appendChild(t);
    document.title = 'Полигон — отправлено';
  };
  document.addEventListener('DOMContentLoaded', P.zapisatSost);
})();
