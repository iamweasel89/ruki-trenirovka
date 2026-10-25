// Pomehi (disturbances) for the practice pages. Driven by ?seed=N&pomehi=a,b,c
// zaderzhka   - delayed render of the form and of step transitions
// modal       - a modal dialog pops up while typing and traps focus
// fokus       - focus is moved away to another field while typing
// pererisovka - a field is re-rendered (replaced by an empty node) after input
// obnovlenie  - the page reloads itself once mid-run (all state lost)   [off by default]
// medlenno    - slow render: delays several times longer                [off by default]
(function () {
  var q = new URLSearchParams(location.search);
  var seed = parseInt(q.get('seed') || '1', 10) >>> 0 || 1;
  var vkl = (q.get('pomehi') || 'zaderzhka,modal,fokus,pererisovka').split(',');
  var s = seed;
  function rnd() {
    s |= 0; s = (s + 0x6D2B79F5) | 0;
    var t = Math.imul(s ^ (s >>> 15), 1 | s);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }
  function mezhdu(a, b) { return a + Math.floor(rnd() * (b - a + 1)); }
  var P = window.P = {
    rnd: rnd, mezhdu: mezhdu,
    est: function (k) { return vkl.indexOf(k) >= 0; },
    zhurnal: [], vyklyucheno: false, kudaFokus: null
  };
  function zapis(k) { P.zhurnal.push(k); }
  if (q.get('obn')) zapis('obnovlenie');
  // delay in ms for a delayed render, honouring zaderzhka / medlenno
  P.zaderzhkaMs = function (a, b) {
    if (P.est('medlenno')) return mezhdu(a * 3 + 1500, b * 3 + 1500);
    return P.est('zaderzhka') ? mezhdu(a, b) : 0;
  };

  // thresholds on the count of input events
  var modalNa = [mezhdu(3, 20), mezhdu(25, 60)];
  var fokusNa = [mezhdu(4, 25), mezhdu(30, 70)];
  var pererisNa = [mezhdu(6, 30), mezhdu(35, 80)];
  var obnNa = mezhdu(5, 70);
  var n = 0;

  document.addEventListener('input', function (e) {
    if (P.vyklyucheno) return;
    n++;
    if (P.est('modal') && modalNa.indexOf(n) >= 0) setTimeout(pokazatModal, mezhdu(30, 400));
    if (P.est('fokus') && fokusNa.indexOf(n) >= 0) setTimeout(uvestiFokus, mezhdu(0, 300));
    if (P.est('pererisovka') && pererisNa.indexOf(n) >= 0) {
      var t = e.target;
      setTimeout(function () { pererisovat(t); }, mezhdu(150, 1400));
    }
    if (P.est('obnovlenie') && !q.get('obn') && n === obnNa) {
      setTimeout(function () {
        if (P.vyklyucheno) return;
        location.replace(location.href.replace(/#.*$/, '') + '&obn=1');
      }, mezhdu(50, 600));
    }
  }, true);

  var modal = null;
  function pokazatModal() {
    if (P.vyklyucheno || modal) return;
    zapis('modal');
    var fon = document.createElement('div');
    fon.className = 'modal-fon';
    fon.innerHTML = '<div class="modal" role="dialog" aria-modal="true" aria-label="Подсказка" id="podskazka">' +
      '<p>Подсказка: проверьте введённые данные.</p>' +
      '<button type="button" id="podskazka-ok">Понятно</button></div>';
    document.body.appendChild(fon);
    modal = fon;
    var ok = fon.querySelector('button');
    ok.addEventListener('click', zakrytModal);
    ok.focus();
  }
  function zakrytModal() {
    if (!modal) return;
    modal.remove(); modal = null;
  }
  P.zakrytModal = zakrytModal;
  document.addEventListener('keydown', function (e) {
    if (modal && e.key === 'Escape') { e.preventDefault(); zakrytModal(); }
  }, true);
  // focus trap while the modal is open
  document.addEventListener('focusin', function (e) {
    if (modal && !modal.contains(e.target)) {
      var ok = modal.querySelector('button');
      setTimeout(function () { if (modal) ok.focus(); }, 0);
    }
  }, true);

  function uvestiFokus() {
    if (P.vyklyucheno || modal) return;
    var kuda = (P.kudaFokus && P.kudaFokus()) || document.getElementById('poisk');
    if (kuda && document.activeElement !== kuda) { zapis('fokus'); kuda.focus(); }
  }

  function pererisovat(el) {
    if (P.vyklyucheno || !el || !el.parentNode) return;
    if (!(el.tagName === 'INPUT' || el.tagName === 'TEXTAREA')) return;
    if (el.type === 'password' || el.id === 'poisk') return;
    zapis('pererisovka');
    var nov = el.cloneNode(false);
    // a re-rendered checkbox or radio loses its selection but keeps its value (as a real re-render would)
    if (el.type === 'checkbox' || el.type === 'radio') { nov.checked = false; nov.removeAttribute('checked'); }
    else { nov.value = ''; nov.removeAttribute('value'); }
    var bylFokus = document.activeElement === el;
    el.replaceWith(nov);
    if (bylFokus) document.getElementById('poisk').focus();
    document.dispatchEvent(new Event('pererisovka'));
  }

  // delayed reveal of an element
  P.pokazatPozzhe = function (el, a, b, gotovo) {
    var ms = P.zaderzhkaMs(a, b);
    if (ms) zapis(P.est('medlenno') ? 'medlenno' : 'zaderzhka');
    setTimeout(function () { el.hidden = false; if (gotovo) gotovo(); }, ms);
  };

  // collect values of all fields inside a container
  P.sobrat = function (kont) {
    var d = {};
    kont.querySelectorAll('input,textarea').forEach(function (el) {
      if (!el.id || el.id === 'poisk' || el.id === 'itog') return;
      if (el.type === 'checkbox') d[el.id] = el.checked;
      else if (el.type === 'password') d[el.id + '_dlina'] = el.value.length;
      else d[el.id] = el.value;
    });
    return d;
  };
  P.pokazatItog = function (kont, dannye) {
    P.vyklyucheno = true; zakrytModal();
    kont.hidden = true;
    var h = document.createElement('h2'); h.textContent = 'Отправлено';
    var t = document.createElement('textarea');
    t.id = 'itog'; t.readOnly = true; t.setAttribute('aria-label', 'Итог'); t.rows = 8;
    t.value = JSON.stringify({ dannye: dannye, pomehi: P.zhurnal });
    document.querySelector('main').appendChild(h);
    document.querySelector('main').appendChild(t);
    document.title = 'Полигон — отправлено';
  };
})();
