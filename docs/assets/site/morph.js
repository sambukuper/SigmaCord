// O topo da página: a interface do app em 3D, com os layouts reais dos temas
// (calculados de themes/*.kdl em tools/gen_site.py). Ela se desmonta no ar, os
// painéis vão para o layout do próximo tema e tudo encaixa de novo.
(function () {
  var host = document.querySelector("[data-morph]");
  var L = window.LC_LAYOUTS;
  if (!host || !L) return;
  var html = document.documentElement, data = window.LC_DATA, lang = html.dataset.lang;
  var calm = matchMedia("(prefers-reduced-motion: reduce)").matches;
  var scene = host.querySelector(".morph-scene"), app = host.querySelector(".morph-app");
  var tilt = host.querySelector(".morph-tilt"), file = host.querySelector("[data-morph-file]"), desc = host.querySelector("[data-morph-desc]");
  var Z = { box: 8, "guild-bar": 58, "channel-list": 34, "user-panel": 66, header: 50, tabs: 62, messages: 22, composer: 78, "member-list": 40, "status-bar": 30, topbar: 84, logo: 92, label: 88 };
  var panels = {}, shownName = null, busy = false, queued = null;

  function bars(widths) {
    return widths.map(function (w) { return '<i class="b" style="width:' + w + '%"></i>'; }).join("");
  }
  function content(n) {
    var horiz = n.w > n.h * 1.4, out = "", i;
    switch (n.k) {
      case "guild-bar":
        var size = Math.min(44, Math.max(20, (horiz ? n.h : n.w) - 22)), count = Math.min(11, Math.floor((horiz ? n.w : n.h) / (size + 11)));
        for (i = 0; i < count; i++) out += '<u class="' + (i === 1 ? "on" : "") + '" style="width:' + size + "px;height:" + size + 'px"></u>';
        return '<div class="p-guild ' + (horiz ? "h" : "") + " " + (n.s || "") + '">' + out + "</div>";
      case "channel-list":
        return '<div class="p-rows">' + bars([58]) + bars([26]) + '<i class="b on" style="width:74%"></i>' + bars([52, 66, 44]) + bars([26]) + bars([60, 48, 70]) + "</div>";
      case "member-list":
        return '<div class="p-rows p-mem">' + bars([30]) + [62, 48, 70, 40, 56, 66].map(function (w) { return '<em></em><i class="b" style="width:' + w + '%"></i>'; }).join("") + "</div>";
      case "messages":
        var v = n.v === "bubbles" ? "bub" : n.v === "irc" ? "irc" : "coz";
        return '<div class="p-msgs ' + v + '"><div><u></u>' + bars([42, 78]) + '</div><div class="pic"></div><div><u></u>' + bars([30, 62]) + '</div><div class="me"><u></u>' + bars([36, 54]) + "</div><div><u></u>" + bars([48, 84]) + "</div></div>";
      case "composer":
        return '<div class="p-comp ' + (n.v || "") + '"><span>' + (n.v === "prompt" ? "rsha@general ❯" : "") + "</span></div>";
      case "header":
        return '<div class="p-head"><i class="b on" style="width:90px"></i>' + bars([18]) + "</div>";
      case "tabs":
        return '<div class="p-tabs"><u class="on"></u><u></u><u></u></div>';
      case "user-panel":
        return '<div class="p-user"><u></u>' + bars([44]) + "</div>";
      case "status-bar":
        return '<div class="p-stat">' + bars([7, 5, 9, 6]) + '<span></span>' + bars([8]) + "</div>";
      case "topbar":
        return '<div class="p-top"><span></span></div>';
      case "logo":
        return '<div class="p-logo">SigmaCord</div>';
      case "label":
        return '<div class="p-label" style="font-size:' + Math.max(n.fs || 12, 11) + 'px">' + (n.t || "") + "</div>";
      default:
        return "";
    }
  }

  function panelFor(key, kind) {
    if (panels[key]) return panels[key];
    var el = document.createElement("div"), body = document.createElement("div"), tag = document.createElement("span");
    el.className = "pn pn-" + kind;
    body.className = "pn-body";
    tag.className = "pn-tag";
    el.append(body, tag);
    el.style.opacity = 0;
    app.appendChild(el);
    return (panels[key] = { el: el, body: body, tag: tag, kind: kind, z: (Z[kind] || 20) + (parseInt(key.split("#")[1], 10) % 4) * 6 });
  }

  function shown(n) {
    // Etiquetas e caixinhas não fazem falta na cena e cada painel é uma camada a mais.
    return n.k !== "label" && (n.k !== "box" || n.w * n.h > 30000);
  }

  function place(name, mult) {
    var m = html.dataset.mode === "light" ? 1 : 0, spec = L[name], seen = {}, count = {}, moves = [];
    var toks = data.themes[name][m ? "light" : "dark"];
    for (var k in toks) app.style.setProperty("--t-" + k, toks[k]);
    spec.nodes.filter(shown).forEach(function (n, i) {
      count[n.k] = (count[n.k] || 0) + 1;
      var key = n.k + "#" + count[n.k], p = panelFor(key, n.k), was = p.rect;
      seen[key] = true;
      var s = p.el.style;
      s.left = n.x + "px";
      s.top = n.y + "px";
      s.width = n.w + "px";
      s.height = n.h + "px";
      s.background = n.c ? n.c[m] : "transparent";
      s.borderRadius = (n.r || 0) + "px";
      s.opacity = 1;
      p.body.innerHTML = content(n);
      p.tag.textContent = (n.n || "").slice(0, 30);
      p.rect = n;
      p.live = true;
      // O painel já está no lugar novo: uma transformação o devolve ao antigo e ele
      // anima de lá. Só a GPU trabalha, sem layout a cada quadro.
      if (mult && was && p.wasLive) {
        s.transition = "none";
        s.transform = "translateZ(" + p.z * mult + "px) translate(" + (was.x - n.x) + "px," + (was.y - n.y) + "px) scale(" + was.w / Math.max(n.w, 1) + "," + was.h / Math.max(n.h, 1) + ")";
        moves.push({ p: p, delay: i * 16 });
      } else {
        s.transform = "translateZ(" + p.z * (mult || 1) + "px)";
      }
    });
    Object.keys(panels).forEach(function (key) {
      panels[key].wasLive = !!seen[key];
      if (!seen[key]) {
        panels[key].el.style.opacity = 0;
        panels[key].rect = null;
      }
    });
    if (moves.length) {
      void app.offsetWidth;
      moves.forEach(function (x) {
        x.p.el.style.transition = "";
        x.p.el.style.transitionDelay = x.delay + "ms";
        x.p.el.style.transform = "translateZ(" + x.p.z * mult + "px)";
      });
    }
    app.style.background = toks.bg;
    if (file) file.textContent = "themes/" + name + ".kdl";
    if (desc) desc.textContent = lang === "pt" ? spec.pt : spec.en;
    shownName = name;
  }

  function depth(mult) {
    Object.keys(panels).forEach(function (key) {
      var p = panels[key];
      p.el.style.transitionDelay = "0ms";
      p.el.style.transform = "translateZ(" + p.z * mult + "px)";
    });
  }

  function morphTo(name) {
    if (!L[name]) return;
    if (busy) { queued = name; return; }
    if (calm) { place(name); return; }
    if (name === shownName) { place(name); return; }
    busy = true;
    app.classList.add("ex");
    depth(2.5);
    setTimeout(function () { place(name, 2.5); }, 320);
    setTimeout(function () {
      depth(1);
      app.classList.remove("ex");
    }, 1120);
    setTimeout(function () {
      busy = false;
      if (queued) { var q = queued; queued = null; morphTo(q); }
    }, 1650);
  }

  function fit() {
    var w = scene.clientWidth;
    app.style.transform = "scale(" + w / 1280 + ")";
    scene.style.height = w * 0.625 + "px";
  }
  fit();
  addEventListener("resize", fit);

  var first = html.dataset.theme === "sigma" ? "orbital" : html.dataset.theme;
  place(first);
  Object.keys(panels).forEach(function (key) { panels[key].wasLive = true; });

  document.addEventListener("lc-cycle", function (e) { morphTo(e.detail); });
  document.addEventListener("lc-rendered", function () {
    if (html.dataset.theme !== "sigma") morphTo(html.dataset.theme);
    else if (shownName && !busy) place(shownName);
  });

  // Inclina com o ponteiro.
  if (!calm && matchMedia("(hover: hover) and (pointer: fine)").matches) {
    var heroBox = document.querySelector(".hero");
    heroBox.addEventListener("pointermove", function (e) {
      var r = heroBox.getBoundingClientRect(), x = (e.clientX - r.left) / r.width - 0.5, y = (e.clientY - r.top) / r.height - 0.5;
      if (html.classList.contains("lite")) return;
      tilt.style.transform = "rotateY(" + (x * 16).toFixed(2) + "deg) rotateX(" + (-y * 12).toFixed(2) + "deg)";
    }, { passive: true });
    heroBox.addEventListener("pointerleave", function () { tilt.style.transform = ""; });
  }
})();
