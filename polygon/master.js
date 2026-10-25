// Wizard engine for the practice pages: steps with Next / Back, validation with error
// messages, conditional steps, drafts kept when going back, a summary page and a final button.
// Markup: <form id="master"> with <section data-shag data-zagolovok="..." [data-esli="name=value" | "#checkboxId"]>
// and one <section data-svodka data-zagolovok="...">. Field rules on inputs:
//   data-shablon (regex) + data-oshibka, data-min / data-max + data-oshibka,
//   data-zanyato="a,b" + data-zanyato-oshibka, data-neobyaz (optional), data-obyaz on a checkbox (+ data-oshibka).
// Radio groups: <div class="gruppa" role="radiogroup" aria-label="..." data-imya="name">.
// Extra wizard disturbances (with pomehi.js, via ?pomehi=...):
//   iskazhenie - on reaching the summary a stored value of an earlier step drifts (last char lost)
//   chernovik  - on going back a field of the step returned to loses its draft
//   sboj       - a Next press fails once with a transient "try again" message
(function () {
  var P = window.P;
  var forma = document.getElementById('master');
  var sekcii = Array.prototype.slice.call(forma.querySelectorAll('section[data-shag]'));
  var svodka = forma.querySelector('section[data-svodka]');
  var tek = null, otpravok = 0, idOsh = 0;
  var bylo = { iskazhenie: false, chernovik: false, sboj: false };
  var shans = { iskazhenie: P.rnd() < 0.45, chernovik: P.rnd() < 0.5, sboj: P.rnd() < 0.3 };
  var sbojNaShage = P.mezhdu(0, 3);
  function $(id) { return document.getElementById(id); }
  function t(s) { return (s || '').replace(/\s+/g, ' ').trim(); }

  function vybrano(imya) { var r = forma.querySelector('input[name="' + imya + '"]:checked'); return r ? r.value : null; }
  function uslovie(s) {
    var e = s.getAttribute('data-esli');
    if (!e) return true;
    if (e.charAt(0) === '#') { var f = $(e.slice(1)); return !!(f && f.checked); }
    var ch = e.split('=');
    return vybrano(ch[0]) === ch[1];
  }
  function put() { return sekcii.filter(uslovie); }
  function vse() { return put().concat([svodka]); }

  function pokazat(s) {
    sekcii.concat([svodka]).forEach(function (x) { x.hidden = true; });
    var p = vse(), i = p.indexOf(s);
    var h = s.querySelector('h2.zag');
    h.textContent = 'Шаг ' + (i + 1) + ' из ' + p.length + ' · ' + s.getAttribute('data-zagolovok');
    var nz = s.querySelector('button.nazad'); if (nz) nz.hidden = (i === 0);
    ochistit(s);
    if (s === svodka) postroitSvodku();
    tek = s;
    P.pokazatPozzhe(s, 200, 1200);
  }

  function polya(s) { return Array.prototype.slice.call(s.querySelectorAll('input')); }
  function metka(el) { return el.getAttribute('aria-label') || el.id; }

  function ochistit(s) {
    var o = s.querySelector('.oshibki'); if (o) o.innerHTML = '';
    polya(s).forEach(function (el) { el.removeAttribute('aria-invalid'); });
  }
  function oshibka(s, el, txt) {
    var o = s.querySelector('.oshibki');
    var p = document.createElement('p');
    p.className = 'oshibka'; p.setAttribute('role', 'alert'); p.id = 'oshibka-' + (++idOsh);
    p.textContent = txt;
    o.appendChild(p);
    if (el) el.setAttribute('aria-invalid', 'true');
  }

  function proverit(s) {
    var n = 0;
    polya(s).forEach(function (el) {
      if (el.type === 'radio') return;
      var lab = metka(el);
      if (el.type === 'checkbox') {
        if (el.hasAttribute('data-obyaz') && !el.checked) { oshibka(s, el, el.getAttribute('data-oshibka') || ('Нужно отметить: «' + lab + '»')); n++; }
        return;
      }
      var v = el.value.trim();
      if (!v) { if (!el.hasAttribute('data-neobyaz')) { oshibka(s, el, 'Заполните поле «' + lab + '»'); n++; } return; }
      var sh = el.getAttribute('data-shablon');
      if (sh && !(new RegExp(sh)).test(v)) { oshibka(s, el, el.getAttribute('data-oshibka')); n++; return; }
      if (el.type === 'number') {
        var x = Number(v), mn = el.getAttribute('data-min'), mx = el.getAttribute('data-max');
        if (isNaN(x) || (mn !== null && x < Number(mn)) || (mx !== null && x > Number(mx))) { oshibka(s, el, el.getAttribute('data-oshibka')); n++; return; }
      }
      var z = el.getAttribute('data-zanyato');
      if (z && z.split(',').indexOf(v.toLowerCase()) >= 0) { oshibka(s, el, el.getAttribute('data-zanyato-oshibka')); n++; }
    });
    Array.prototype.forEach.call(s.querySelectorAll('.gruppa'), function (g) {
      if (!vybrano(g.getAttribute('data-imya'))) { oshibka(s, null, 'Выберите: «' + g.getAttribute('aria-label') + '»'); n++; }
    });
    return n === 0;
  }

  function pokaz(el) {
    if (el.type === 'checkbox') return el.checked ? 'да' : 'нет';
    return t(el.value) || '—';
  }
  function postroitSvodku() {
    // a stored draft drifts once on the way to the summary
    if (P.est('iskazhenie') && shans.iskazhenie && !bylo.iskazhenie && !P.vyklyucheno) {
      var kand = [];
      put().forEach(function (s) { polya(s).forEach(function (el) { if ((el.type === 'text') && el.value.length >= 3) kand.push(el); }); });
      if (kand.length) {
        var el = kand[P.mezhdu(0, kand.length - 1)];
        el.value = el.value.slice(0, -1);
        bylo.iskazhenie = true; P.zhurnal.push('iskazhenie');
      }
    }
    var ul = $('svodka-spisok');
    ul.innerHTML = '';
    put().forEach(function (s) {
      polya(s).forEach(function (el) {
        if (el.type === 'radio') return;
        var li = document.createElement('li'); li.textContent = metka(el) + ': ' + pokaz(el); ul.appendChild(li);
      });
      Array.prototype.forEach.call(s.querySelectorAll('.gruppa'), function (g) {
        var r = forma.querySelector('input[name="' + g.getAttribute('data-imya') + '"]:checked');
        var li = document.createElement('li'); li.textContent = g.getAttribute('aria-label') + ': ' + (r ? metka(r) : '—'); ul.appendChild(li);
      });
    });
    if (window.MASTER_DOP) window.MASTER_DOP(vybrano).forEach(function (s) { var li = document.createElement('li'); li.textContent = s; ul.appendChild(li); });
  }

  function sobrat() {
    var d = {};
    put().forEach(function (s) {
      polya(s).forEach(function (el) {
        if (el.type === 'radio') { if (!(el.name in d)) d[el.name] = null; if (el.checked) d[el.name] = el.value; }
        else if (el.type === 'checkbox') d[el.id] = el.checked;
        else d[el.id] = el.value;
      });
    });
    return d;
  }

  forma.addEventListener('click', function (e) {
    var b = e.target.closest ? e.target.closest('button') : e.target;
    if (!b || b.disabled || !tek || tek.hidden) return;
    var p = vse(), i = p.indexOf(tek);
    if (b.classList.contains('dalee')) {
      ochistit(tek);
      if (P.est('sboj') && shans.sboj && !bylo.sboj && i >= sbojNaShage) {
        bylo.sboj = true; P.zhurnal.push('sboj');
        oshibka(tek, null, 'Не удалось сохранить шаг. Попробуйте ещё раз.');
        return;
      }
      if (!proverit(tek)) return;
      p = vse(); i = p.indexOf(tek);
      pokazat(p[i + 1]);
    } else if (b.classList.contains('nazad')) {
      if (i <= 0) return;
      var kuda = p[i - 1];
      if (P.est('chernovik') && shans.chernovik && !bylo.chernovik && kuda !== svodka) {
        var tx = polya(kuda).filter(function (el) { return el.type === 'text' && el.value; });
        if (tx.length) { tx[P.mezhdu(0, tx.length - 1)].value = ''; bylo.chernovik = true; P.zhurnal.push('chernovik'); }
      }
      pokazat(kuda);
    } else if (b.classList.contains('final')) {
      otpravok++;
      if (otpravok > 1) return;
      b.disabled = true;
      var dannye = sobrat();
      setTimeout(function () {
        P.vyklyucheno = true; if (P.zakrytModal) P.zakrytModal();
        forma.hidden = true;
        var h = document.createElement('h2'); h.textContent = 'Отправлено';
        var ta = document.createElement('textarea');
        ta.id = 'itog'; ta.readOnly = true; ta.setAttribute('aria-label', 'Итог'); ta.rows = 8;
        ta.value = JSON.stringify({ dannye: dannye, pomehi: P.zhurnal, otpravok: otpravok, put: put().map(function (s) { return s.getAttribute('data-zagolovok'); }) });
        document.querySelector('main').appendChild(h);
        document.querySelector('main').appendChild(ta);
        document.title = document.title.replace(/ — .*$/, '') + ' — отправлено';
      }, P.zaderzhkaMs(200, 1200));
    }
  });

  P.pokazatPozzhe(forma, 300, 2000, function () { $('zagruzka').hidden = true; pokazat(put()[0]); });
})();
