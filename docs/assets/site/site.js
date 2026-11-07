// Tema da página, paleta de comandos e os pedaços interativos da página inicial.
(function () {
  var html = document.documentElement;
  var root = html.dataset.root || "";
  var lang = html.dataset.lang;
  var data = window.LC_DATA;
  var names = ["sigma"].concat(data.order);
  var T = lang === "pt"
    ? { dark: "escuro", light: "claro", copy: "copiar", copied: "copiado", search: "Vá para uma página, seção ou tema…", none: "Nada encontrado.", theme: "tema", appearance: "aparência", toLight: "Modo claro", toDark: "Modo escuro", next: "Próximo tema", action: "ação", foot: "↑↓ escolher · Enter abrir · Esc fechar", brand: "Prints reais, passando pelos 11 temas. Escolha um lá em cima e a página inteira veste ele.", typed: [["ps -o pss sigmacord", "cerca de 130 MB"], ["top -p $(pidof sigmacord)", "0% de CPU parado"], ["ls themes/*.kdl | wc -l", "11"], ["grep -c electron sigmacord", "0"], ["$EDITOR themes/subsolo.kdl", "salvou, a janela mudou"]], appTheme: "Print real do app, tema " , top: "topo", bot: "fim", fxOn: "Efeitos: ligar todos", fxOff: "Efeitos: modo leve", loaded: "carregado", site: "tema do site", quips: ["próximo arquivo.", "mesmo binário.", "e nada de Electron.", "de novo?", "pode continuar, eu espero.", "cada clique é um .kdl."], sep: ".", mode: { dark: "escuro", light: "claro" } }
    : { dark: "dark", light: "light", copy: "copy", copied: "copied", search: "Jump to a page, section or theme…", none: "Nothing found.", theme: "theme", appearance: "appearance", toLight: "Light mode", toDark: "Dark mode", next: "Next theme", action: "action", foot: "↑↓ select · Enter open · Esc close", brand: "Real screenshots, cycling through all 11 themes. Pick one up top and the whole page wears it.", typed: [["ps -o pss sigmacord", "about 130 MB"], ["top -p $(pidof sigmacord)", "0% CPU at idle"], ["ls themes/*.kdl | wc -l", "11"], ["grep -c electron sigmacord", "0"], ["$EDITOR themes/subsolo.kdl", "saved, the window changed"]], appTheme: "Real app screenshot, theme ", top: "top", bot: "bot", fxOn: "Effects: turn everything on", fxOff: "Effects: lite mode", loaded: "loaded", site: "site theme", quips: ["next file.", "same binary.", "still no Electron.", "again?", "go on, I can wait.", "every click is a .kdl."], sep: ",", mode: { dark: "dark", light: "light" } };

  function current() { return html.dataset.theme; }
  function mode() { return html.dataset.mode; }

  function shotFile(name, m) {
    if (name === "sigma") return m === "light" ? "classico-claro" : "sigma";
    return m === "light" ? name + "-claro" : name;
  }

  function render() {
    var name = current(), m = mode();
    document.querySelectorAll("[data-theme-name]").forEach(function (e) { e.textContent = name; });
    document.querySelectorAll("[data-mode-name]").forEach(function (e) { e.textContent = T[m]; });
    document.querySelectorAll(".tab").forEach(function (b) { b.setAttribute("aria-selected", b.dataset.apply === name ? "true" : "false"); });
    var hero = document.querySelector("[data-hero-shot]");
    if (hero) hero.src = root + "assets/shots/" + lang + "/" + shotFile(name, m) + ".webp";
    var note = document.querySelector("[data-stage-note]");
    if (note) note.textContent = name === "sigma" ? T.brand : T.appTheme + name + ".";
    var win = document.querySelector("[data-win-title]");
    if (win) win.textContent = name === "sigma" ? "sigmacord --demo" : "sigmacord --demo --theme " + name;
    document.dispatchEvent(new CustomEvent("lc-rendered"));
    var mascot = document.querySelector(".mascot");
    if (mascot) {
      mascot.classList.add("pop");
      setTimeout(function () { mascot.classList.remove("pop"); }, 260);
    }
  }

  var calm = matchMedia("(prefers-reduced-motion: reduce)").matches;
  var wipe = null, wiping = false, toast = null, toastTimer = 0;

  function applyTheme(name, m) {
    window.LC_apply(name, m);
    try {
      localStorage.setItem("lc-theme", name);
      localStorage.setItem("lc-mode", m);
    } catch (e) {}
    render();
    document.dispatchEvent(new CustomEvent("lc-theme"));
  }

  function say(name, m) {
    if (!toast) {
      toast = document.createElement("div");
      toast.className = "toast";
      toast.setAttribute("role", "status");
      document.body.appendChild(toast);
    }
    var file = name === "sigma" ? T.site : name + ".kdl";
    toast.innerHTML = "<b>✓</b> " + file + " · " + T[m] + " · " + T.loaded;
    toast.classList.add("on");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toast.classList.remove("on"); }, 1500);
  }

  // A troca de tema: faixas passam pela tela e o tema novo está por baixo delas.
  function setTheme(name, m) {
    m = m || mode();
    say(name, m);
    if (calm || wiping) return applyTheme(name, m);
    if (!wipe) {
      wipe = document.createElement("div");
      wipe.className = "wipe";
      wipe.setAttribute("aria-hidden", "true");
      for (var i = 0; i < 9; i++) {
        var bar = document.createElement("i");
        bar.style.setProperty("--n", (i * 7) % 9);
        wipe.appendChild(bar);
      }
      document.body.appendChild(wipe);
    }
    var toks = data.themes[name][m];
    wipe.style.setProperty("--w1", toks.accent);
    wipe.style.setProperty("--w2", toks.mention);
    wipe.style.setProperty("--w3", toks.rail);
    wiping = true;
    wipe.classList.add("run");
    setTimeout(function () { applyTheme(name, m); }, 240);
    setTimeout(function () { wipe.classList.remove("run"); wiping = false; }, 620);
  }

  // O texto "decodifica": letras trocam até assentar, da esquerda para a direita.
  // Só nas fontes monoespaçadas, em que nada muda de lugar enquanto isso.
  var GLYPHS = "!<>-_/[]{}=+*^?#01";
  function scramble(el) {
    var d = html.dataset.display;
    if (calm || (d !== "pixel" && d !== "mono")) return;
    if (!el.hasAttribute("aria-label")) el.setAttribute("aria-label", el.textContent.replace(/\s+/g, " ").trim());
    var nodes = [], walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    while (walk.nextNode()) if (walk.currentNode.nodeValue.trim()) nodes.push({ n: walk.currentNode, t: walk.currentNode.nodeValue });
    var total = nodes.reduce(function (a, x) { return a + x.t.length; }, 0), start = performance.now(), dur = 620 + total * 9;
    function frame(now) {
      var done = Math.min((now - start) / dur, 1) * total, seen = 0;
      nodes.forEach(function (x) {
        var out = "";
        for (var i = 0; i < x.t.length; i++, seen++) {
          var ch = x.t[i];
          out += seen < done || ch === " " || ch === "\u00a0" ? ch : GLYPHS[Math.floor(Math.random() * GLYPHS.length)];
        }
        x.n.nodeValue = out;
      });
      if (done < total) requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }

  function step(d) {
    var i = names.indexOf(current());
    setTheme(names[(i + d + names.length) % names.length]);
  }

  document.addEventListener("click", function (e) {
    var el = e.target.closest("[data-apply],[data-next-theme],[data-toggle-mode],[data-open-palette],[data-copy]");
    if (!el) return;
    if (el.dataset.apply) setTheme(el.dataset.apply);
    else if ("nextTheme" in el.dataset) step(1);
    else if ("toggleMode" in el.dataset) setTheme(current(), mode() === "dark" ? "light" : "dark");
    else if ("openPalette" in el.dataset) openPalette();
    else if ("copy" in el.dataset) {
      var code = el.parentElement.querySelector("code").textContent;
      if (navigator.clipboard) navigator.clipboard.writeText(code);
      el.textContent = T.copied;
      setTimeout(function () { el.textContent = T.copy; }, 1200);
    }
  });
  document.querySelectorAll("[data-copy]").forEach(function (b) { b.textContent = T.copy; });

  // Relógio da barra de status.
  var clock = document.querySelector("[data-clock]");
  function tick() {
    var d = new Date();
    clock.textContent = String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0");
  }
  tick();
  setInterval(tick, 20000);

  // Posição na página, como a régua do vim, e o fio de progresso da barra.
  var pos = document.querySelector("[data-scroll-pos]"), queued = false, shownPos = "", maxScroll = 1, barW = 0;
  var prog = document.querySelector(".sb-prog"), buddyEl = document.querySelector(".buddy");
  function measure() {
    maxScroll = Math.max(html.scrollHeight - innerHeight, 1);
    barW = innerWidth - (buddyEl ? buddyEl.offsetWidth : 0);
    place();
  }
  function place() {
    queued = false;
    var p = Math.min(scrollY / maxScroll, 1);
    prog.style.transform = "scaleX(" + p.toFixed(4) + ")";
    if (buddyEl) buddyEl.style.transform = "translateX(" + (p * barW).toFixed(1) + "px)";
    var label = p < 0.005 ? T.top : p > 0.995 ? T.bot : Math.round(p * 100) + "%";
    if (label !== shownPos) pos.textContent = shownPos = label;
  }
  addEventListener("scroll", function () {
    if (!queued) { queued = true; requestAnimationFrame(place); }
  }, { passive: true });
  addEventListener("resize", measure);
  addEventListener("load", measure);
  // Seções fora da tela só têm tamanho estimado: a altura muda enquanto se rola.
  if (window.ResizeObserver) new ResizeObserver(function () {
    maxScroll = Math.max(html.scrollHeight - innerHeight, 1);
  }).observe(document.body);
  measure();

  // ------------------------------------------------------------ Paleta ----
  var pal, input, list, items = [], sel = 0, shown = [], searchLoaded = false;

  function themeItems() {
    var out = names.map(function (n) {
      return { t: T.theme + ": " + n, s: n === current() ? "✓" : T.appearance, run: function () { setTheme(n); } };
    });
    out.push({ t: mode() === "dark" ? T.toLight : T.toDark, s: T.action, run: function () { setTheme(current(), mode() === "dark" ? "light" : "dark"); } });
    out.push({ t: T.next, s: "F2", run: function () { step(1); } });
    var lite = html.classList.contains("lite");
    out.push({ t: lite ? T.fxOn : T.fxOff, s: T.action, run: function () {
      html.classList.toggle("lite");
      try { localStorage.setItem("lc-fx", html.classList.contains("lite") ? "lite" : "full"); } catch (e) {}
    } });
    return out;
  }

  // A mesma ideia da busca aproximada do app: letras em ordem, com bônus para
  // começo de palavra e letras seguidas. Sem diferença de acentos.
  function norm(s) { return s.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, ""); }
  function score(q, text) {
    if (!q) return 1;
    var t = norm(text), i = 0, last = -2, s = 0;
    for (var k = 0; k < q.length; k++) {
      var at = t.indexOf(q[k], i);
      if (at < 0) return 0;
      s += at === last + 1 ? 4 : 1;
      if (at === 0 || " :-/".indexOf(t[at - 1]) >= 0) s += 5;
      last = at;
      i = at + 1;
    }
    return s - t.length * 0.02;
  }

  function draw() {
    var q = norm(input.value.trim());
    var scored = [];
    items.forEach(function (it) {
      var s = score(q, it.t);
      if (!s && it.x && q.length > 2 && norm(it.x).indexOf(q) >= 0) s = 0.5;
      if (s > 0) scored.push({ it: it, s: s });
    });
    scored.sort(function (a, b) { return b.s - a.s; });
    shown = (q ? scored : scored.slice()).slice(0, 40).map(function (x) { return x.it; });
    sel = Math.min(sel, Math.max(shown.length - 1, 0));
    list.innerHTML = "";
    if (!shown.length) {
      var none = document.createElement("div");
      none.className = "empty";
      none.textContent = T.none;
      list.appendChild(none);
      return;
    }
    shown.forEach(function (it, i) {
      var li = document.createElement("li");
      li.setAttribute("role", "option");
      li.setAttribute("aria-selected", i === sel ? "true" : "false");
      var a = document.createElement("span");
      a.textContent = it.t;
      var b = document.createElement("small");
      b.textContent = it.s;
      li.append(a, b);
      li.addEventListener("click", function () { choose(it); });
      li.addEventListener("mousemove", function () {
        if (sel !== i) { sel = i; paint(); }
      });
      list.appendChild(li);
    });
  }

  function paint() {
    Array.prototype.forEach.call(list.children, function (li, i) {
      li.setAttribute("aria-selected", i === sel ? "true" : "false");
      if (i === sel) li.scrollIntoView({ block: "nearest" });
    });
  }

  function choose(it) {
    closePalette();
    if (it.run) it.run();
    else location.href = root + it.u;
  }

  function buildPalette() {
    pal = document.createElement("div");
    pal.className = "palette";
    pal.innerHTML = '<div class="palette-box" role="dialog" aria-modal="true"><input type="text" autocomplete="off" spellcheck="false" aria-label="' + T.search + '" placeholder="' + T.search + '"><ul role="listbox"></ul><div class="palette-foot">' + T.foot + "</div></div>";
    document.body.appendChild(pal);
    input = pal.querySelector("input");
    list = pal.querySelector("ul");
    input.addEventListener("input", function () { sel = 0; draw(); });
    pal.addEventListener("mousedown", function (e) { if (e.target === pal) closePalette(); });
    input.addEventListener("keydown", function (e) {
      if (e.key === "ArrowDown") { e.preventDefault(); sel = Math.min(sel + 1, shown.length - 1); paint(); }
      else if (e.key === "ArrowUp") { e.preventDefault(); sel = Math.max(sel - 1, 0); paint(); }
      else if (e.key === "Enter") { e.preventDefault(); if (shown[sel]) choose(shown[sel]); }
      else if (e.key === "Escape") { e.preventDefault(); closePalette(); }
    });
  }

  var before = null;
  function openPalette(actionsFirst) {
    if (!pal) buildPalette();
    before = document.activeElement;
    var pages = window.LC_SEARCH || [];
    items = actionsFirst ? themeItems().concat(pages) : pages.concat(themeItems());
    pal.classList.add("open");
    input.value = "";
    sel = 0;
    draw();
    input.focus();
    if (!searchLoaded) {
      searchLoaded = true;
      var s = document.createElement("script");
      s.src = root + "assets/site/search-" + lang + ".js";
      s.onload = function () {
        items = actionsFirst ? themeItems().concat(window.LC_SEARCH) : window.LC_SEARCH.concat(themeItems());
        if (pal.classList.contains("open")) draw();
      };
      document.head.appendChild(s);
    }
  }
  function closePalette() {
    pal.classList.remove("open");
    if (before && before.focus) before.focus();
  }

  document.addEventListener("keydown", function (e) {
    var open = pal && pal.classList.contains("open");
    if ((e.ctrlKey || e.metaKey) && !e.altKey && e.key.toLowerCase() === "k") {
      e.preventDefault();
      if (open) closePalette(); else openPalette(false);
    } else if ((e.ctrlKey || e.metaKey) && e.shiftKey && e.key.toLowerCase() === "p") {
      e.preventDefault();
      openPalette(true);
    } else if (e.key === "F2") {
      e.preventDefault();
      step(e.shiftKey ? -1 : 1);
    }
  });

  // ----------------------------------------------------- Página inicial ----
  // Entradas ao rolar.
  var seen = new IntersectionObserver(function (es) {
    es.forEach(function (x) {
      if (x.isIntersecting) {
        x.target.classList.add("seen");
        seen.unobserve(x.target);
        if (x.target.matches(".h")) scramble(x.target);
        var num = x.target.querySelector && x.target.querySelector("[data-count]");
        if (num) countUp(num);
      }
    });
  }, { rootMargin: "0px 0px -8% 0px" });
  document.querySelectorAll(".reveal").forEach(function (e) { seen.observe(e); });

  function countUp(el) {
    if (calm) return;
    var end = +el.dataset.count, start = performance.now();
    function frame(now) {
      var k = Math.min((now - start) / 1300, 1), v = Math.round(end * (1 - Math.pow(1 - k, 4)));
      el.textContent = String(v).replace(/\B(?=(\d{3})+$)/g, T.sep) + "\u00a0MB";
      if (k < 1) requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }

  // O título: cada letra é uma peça, e entra decodificando.
  var title = document.querySelector(".hero h1"), letters = [];
  if (title) {
    var plain = title.textContent;
    title.setAttribute("aria-label", Array.prototype.map.call(title.children, function (e) { return e.textContent; }).join(" "));
    var c = 0;
    Array.prototype.forEach.call(title.children, function (lineEl) {
      var words = lineEl.textContent.split(" ");
      lineEl.textContent = "";
      words.forEach(function (w, wi) {
        var word = document.createElement("span");
        word.className = "ch-w";
        word.setAttribute("aria-hidden", "true");
        Array.prototype.forEach.call(w, function (ch) {
          var s = document.createElement("span");
          s.className = "ch";
          s.textContent = ch;
          s.style.setProperty("--c", c++);
          word.appendChild(s);
          letters.push(s);
        });
        lineEl.appendChild(word);
        if (wi < words.length - 1) lineEl.appendChild(document.createTextNode(" "));
      });
    });
    setTimeout(function () { scramble(title); }, 60);
  }

  // Linha de comando que se digita sozinha embaixo do título.
  var typed = document.querySelector(".typed");
  if (typed) {
    var tCmd = typed.querySelector(".typed-cmd"), tOut = typed.querySelector(".typed-out"), tN = 0;
    if (calm) {
      tCmd.textContent = "$ " + T.typed[0][0] + "  ";
      tOut.textContent = "→ " + T.typed[0][1];
    } else (function next() {
      var item = T.typed[tN++ % T.typed.length], i = 0;
      tOut.textContent = "";
      (function type() {
        tCmd.textContent = "$ " + item[0].slice(0, i);
        if (i++ < item[0].length) return setTimeout(type, 26 + Math.random() * 34);
        setTimeout(function () {
          tOut.textContent = "  → " + item[1];
          setTimeout(next, 2300);
        }, 240);
      })();
    })();
  }

  // Nome na barra: letra por letra, para a onda e o glitch ao passar o mouse.
  var brandText = document.querySelector("[data-brand]");
  if (brandText && !calm) {
    var bt = brandText.textContent;
    brandText.textContent = "";
    Array.prototype.forEach.call(bt, function (ch, i) {
      var b = document.createElement("b");
      b.textContent = ch;
      b.style.setProperty("--c", i);
      brandText.appendChild(b);
    });
  }

  // Indicador que desliza entre os links da barra.
  var navEl = document.querySelector(".topnav nav");
  if (navEl) {
    var ind = document.createElement("i");
    ind.className = "nav-ind";
    navEl.appendChild(ind);
    navEl.addEventListener("pointerover", function (e) {
      var a = e.target.closest("a");
      if (!a) return;
      ind.style.width = a.offsetWidth + "px";
      ind.style.transform = "translateX(" + a.offsetLeft + "px)";
      ind.style.opacity = "1";
    });
    navEl.addEventListener("pointerleave", function () { ind.style.opacity = "0"; });
  }

  // Enquanto ninguém escolheu um tema, o topo e a janela passam pelos 10.
  var heroShot = document.querySelector("[data-hero-shot]");
  if (heroShot) (function () {
    var next = document.querySelector(".shot-next"), laser = document.querySelector(".shot-laser");
    var win = document.querySelector("[data-win-title]"), windowEl = document.querySelector(".window"), morphEl = document.querySelector(".morph");
    var n = 4, hover = false, winSeen = false, morphSeen = true;
    function peek(name) {
      document.querySelectorAll(".tab").forEach(function (t) { t.classList.toggle("peek", t.dataset.apply === name); });
    }
    function swap(name) {
      var src = root + "assets/shots/" + lang + "/" + shotFile(name, mode()) + ".webp", im = new Image();
      im.onload = function () {
        if (current() !== "sigma") return;
        next.src = src;
        next.classList.remove("in");
        void next.offsetWidth;
        next.classList.add("in");
        laser.classList.remove("go");
        void laser.offsetWidth;
        laser.classList.add("go");
        if (win) win.textContent = "sigmacord --demo --theme " + name;
        setTimeout(function () {
          if (current() !== "sigma") return;
          heroShot.src = src;
          next.classList.remove("in");
        }, 430);
      };
      im.src = src;
    }
    [windowEl, morphEl].forEach(function (el) {
      el.addEventListener("pointerenter", function () { hover = true; });
      el.addEventListener("pointerleave", function () { hover = false; });
    });
    new IntersectionObserver(function (es) { winSeen = es[0].isIntersecting; }).observe(windowEl);
    new IntersectionObserver(function (es) { morphSeen = es[0].isIntersecting; }).observe(morphEl);
    document.addEventListener("lc-rendered", function () {
      if (current() !== "sigma") { peek(null); next.classList.remove("in"); }
    });
    if (!calm) setInterval(function () {
      if (current() !== "sigma" || hover || !(winSeen || morphSeen) || document.hidden) return;
      n = (n + 1) % data.order.length;
      var name = data.order[n];
      peek(name);
      document.dispatchEvent(new CustomEvent("lc-cycle", { detail: name }));
      if (winSeen) swap(name);
    }, 4400);
  })();

  // O gráfico: um quadradinho para cada 5 MB.
  document.querySelectorAll("[data-units]").forEach(function (box) {
    var n = Math.round(+box.dataset.units / 5);
    var frag = document.createDocumentFragment();
    for (var i = 0; i < n; i++) {
      var c = document.createElement("i");
      c.style.setProperty("--i", i);
      frag.appendChild(c);
    }
    box.appendChild(frag);
  });

  // Cartões da galeria: a metade clara segue o mouse.
  document.querySelectorAll(".tcard-shots").forEach(function (b) {
    b.addEventListener("pointermove", function (e) {
      if (e.pointerType === "touch") return;
      var r = b.getBoundingClientRect();
      b.style.setProperty("--x", ((e.clientX - r.left) / r.width * 100).toFixed(1) + "%");
    });
    b.addEventListener("pointerleave", function () { b.style.removeProperty("--x"); });
  });

  // Tour dos recursos: a imagem acompanha o item no meio da tela.
  var stage = document.querySelector(".tour-stage");
  if (stage) {
    var rows = Array.prototype.slice.call(document.querySelectorAll(".tour-list li"));
    rows.forEach(function (li, i) {
      var img = li.querySelector("img").cloneNode();
      img.removeAttribute("loading");
      img.alt = "";
      img.dataset.i = i;
      stage.appendChild(img);
    });
    var activate = function (i) {
      rows.forEach(function (r, k) { r.classList.toggle("on", k === i); });
      stage.querySelectorAll("img").forEach(function (m) { m.classList.toggle("on", +m.dataset.i === i); });
    };
    var io = new IntersectionObserver(function (es) {
      es.forEach(function (x) { if (x.isIntersecting) activate(rows.indexOf(x.target)); });
    }, { rootMargin: "-45% 0px -50% 0px" });
    rows.forEach(function (r) { io.observe(r); });
    activate(0);
  }

  // Sumário do guia: marca a seção atual.
  var toc = document.querySelectorAll(".toc a");
  if (toc.length) {
    var byId = {};
    toc.forEach(function (a) { byId[a.getAttribute("href").slice(1)] = a; });
    var tio = new IntersectionObserver(function (es) {
      es.forEach(function (x) {
        if (x.isIntersecting) {
          toc.forEach(function (a) { a.classList.remove("on"); });
          var a = byId[x.target.id];
          if (a) a.classList.add("on");
        }
      });
    }, { rootMargin: "-15% 0px -75% 0px" });
    Object.keys(byId).forEach(function (id) {
      var h = document.getElementById(id);
      if (h) tio.observe(h);
    });
  }

  // Mascote: cada clique troca o tema e rende um comentário.
  var quip = document.querySelector(".quip"), quipN = 0, quipTimer = 0;
  var mascotBtn = document.querySelector("button.mascot");
  if (mascotBtn && quip) mascotBtn.addEventListener("click", function () {
    quip.textContent = T.quips[quipN++ % T.quips.length];
    quip.classList.add("on");
    clearTimeout(quipTimer);
    quipTimer = setTimeout(function () { quip.classList.remove("on"); }, 1700);
    if (calm) return;
    // Pulo com amassada e faíscas nas cores do tema.
    var svg = mascotBtn.querySelector(".ma");
    svg.animate([
      { transform: "none" }, { transform: "scale(1.2,.74)", offset: .16 }, { transform: "translateY(-46%) scale(.86,1.18) rotate(-9deg)", offset: .5 },
      { transform: "scale(1.16,.82)", offset: .84 }, { transform: "none" }
    ], { duration: 620, easing: "cubic-bezier(.3,.7,.3,1)" });
    svg.classList.add("grin");
    setTimeout(function () { svg.classList.remove("grin"); }, 900);
    var shades = svg.querySelector(".ma-shades");
    shades.animate([
      { transform: "none" }, { transform: "translateY(-190px) rotate(-14deg)", offset: .42 }, { transform: "translateY(-120px) rotate(12deg)", offset: .6 },
      { transform: "translateY(14px)", offset: .86 }, { transform: "none" }
    ], { duration: 860, easing: "cubic-bezier(.3,.7,.3,1)" });
    var r = mascotBtn.getBoundingClientRect(), cs = getComputedStyle(html), cols = [cs.getPropertyValue("--accent"), cs.getPropertyValue("--mention"), cs.getPropertyValue("--text")];
    for (var k = 0; k < 16; k++) (function (k) {
      var sp = document.createElement("i"), a = k / 16 * Math.PI * 2, d = 50 + Math.random() * 80;
      sp.className = "spk";
      sp.style.left = r.left + r.width / 2 + "px";
      sp.style.top = r.top + r.height / 2 + "px";
      sp.style.background = cols[k % 3];
      document.body.appendChild(sp);
      sp.animate([{ transform: "none", opacity: 1 }, { transform: "translate(" + Math.cos(a) * d + "px," + Math.sin(a) * d + "px) scale(.2) rotate(180deg)", opacity: 0 }], { duration: 560 + Math.random() * 260, easing: "cubic-bezier(.1,.8,.3,1)" }).onfinish = function () { sp.remove(); };
    })(k);
  });

  // Com os óculos abaixados (ponteiro em cima), os olhos seguem o ponteiro.
  if (mascotBtn && !calm) {
    var heroMa = mascotBtn.querySelector(".ma");
    mascotBtn.addEventListener("pointermove", function (e) {
      var b = mascotBtn.getBoundingClientRect();
      heroMa.style.setProperty("--px", (((e.clientX - b.left) / b.width - 0.5) * 44).toFixed(1) + "px");
      heroMa.style.setProperty("--py", (((e.clientY - b.top) / b.height - 0.5) * 16).toFixed(1) + "px");
    }, { passive: true });
  }

  // Sem animação infinita no SVG: de tempos em tempos o mascote faz uma coisa só,
  // e o título dá um glitch. Com o topo fora da tela, nada acontece.
  if (mascotBtn && !calm) {
    var ma = mascotBtn.querySelector(".ma"), heroOn = true, act = 0;
    new IntersectionObserver(function (es) { heroOn = es[0].isIntersecting; }).observe(mascotBtn);
    var glare = ma.querySelector(".ma-glare"), spark = ma.querySelector(".ma-spark"), shadesEl = ma.querySelector(".ma-shades");
    var eyes = ma.querySelector(".ma-eyes"), g1 = ma.querySelector(".ma-g1"), g2 = ma.querySelector(".ma-g2");
    var acts = [
      function () { glare.animate([{ transform: "translateX(-520px)" }, { transform: "translateX(860px)" }], { duration: 760, easing: "cubic-bezier(.5,0,.3,1)" }); },
      function () { spark.animate([{ transform: "none" }, { transform: "scale(1.45) rotate(90deg)", offset: .45 }, { transform: "scale(.85) rotate(180deg)", offset: .75 }, { transform: "rotate(180deg)" }], { duration: 760, easing: "cubic-bezier(.3,1.4,.5,1)" }); },
      function () {
        if (title) { title.classList.add("glitching"); setTimeout(function () { title.classList.remove("glitching"); }, 600); }
        [[g1, -34, 8], [g2, 34, -8]].forEach(function (x) {
          x[0].animate([{ opacity: 0.85, transform: "translate(" + x[1] + "px," + x[2] + "px)" }, { opacity: 0.85, transform: "translate(" + -x[1] + "px," + -x[2] + "px)", offset: .6 }, { opacity: 0 }], { duration: 300, easing: "steps(3)" });
        });
      },
      function () { glare.animate([{ transform: "translateX(-520px)" }, { transform: "translateX(860px)" }], { duration: 760, easing: "cubic-bezier(.5,0,.3,1)" }); },
      function () {
        shadesEl.animate([{ transform: "none" }, { transform: "translateY(92px) rotate(-2.5deg)", offset: .16 }, { transform: "translateY(92px) rotate(-2.5deg)", offset: .84 }, { transform: "none" }], { duration: 2300, easing: "ease-in-out" });
        eyes.animate([{ transform: "none" }, { transform: "none", offset: .46 }, { transform: "scaleY(.1)", offset: .5 }, { transform: "none", offset: .54 }, { transform: "none" }], { duration: 2300 });
      }
    ];
    setInterval(function () {
      if (heroOn && !document.hidden) acts[act++ % acts.length]();
    }, 2800);
  }

  // As letras do título sobem e acendem perto do ponteiro.
  if (title && letters.length && !calm && matchMedia("(hover: hover) and (pointer: fine)").matches) {
    var lq = false, lx = 0, ly = 0, centers = null, active = [];
    var heroBox = document.querySelector(".hero");
    function remember() {
      centers = letters.map(function (el) {
        var b = el.getBoundingClientRect();
        return { el: el, x: b.left + b.width / 2 + scrollX, y: b.top + b.height / 2 + scrollY };
      });
    }
    addEventListener("resize", function () { centers = null; });
    heroBox.addEventListener("pointermove", function (e) {
      lx = e.clientX + scrollX;
      ly = e.clientY + scrollY;
      if (lq) return;
      lq = true;
      requestAnimationFrame(function () {
        lq = false;
        if (!centers) remember();
        var now = [];
        centers.forEach(function (c) {
          var dx = lx - c.x, dy = ly - c.y;
          if (dx * dx + dy * dy < 22500) now.push(c);
        });
        active.forEach(function (c) {
          if (now.indexOf(c) < 0) { c.el.style.transform = ""; c.el.style.color = ""; }
        });
        now.forEach(function (c) {
          var t = 1 - Math.hypot(lx - c.x, ly - c.y) / 150;
          c.el.style.transform = "translateY(" + (-t * 16).toFixed(1) + "px) scale(" + (1 + t * 0.16).toFixed(3) + ")";
          c.el.style.color = t > 0.45 ? "var(--mention)" : "";
        });
        active = now;
      });
    }, { passive: true });
    heroBox.addEventListener("pointerleave", function () {
      active.forEach(function (c) { c.el.style.transform = ""; c.el.style.color = ""; });
      active = [];
    });
  }

  var fine = matchMedia("(hover: hover) and (pointer: fine)").matches;

  // Luz que segue o ponteiro.
  if (fine && !calm) {
    var spot = document.createElement("div");
    spot.className = "spot";
    spot.setAttribute("aria-hidden", "true");
    document.body.appendChild(spot);
    var mx = 0, my = 0, spotQueued = false;
    addEventListener("pointermove", function (e) {
      mx = e.clientX;
      my = e.clientY;
      spot.classList.add("on");
      if (spotQueued) return;
      spotQueued = true;
      requestAnimationFrame(function () {
        spotQueued = false;
        spot.style.transform = "translate(" + mx + "px," + my + "px)";
      });
    }, { passive: true });
    document.addEventListener("pointerleave", function () { spot.classList.remove("on"); });
  }

  // A janela inclina com o ponteiro e o mascote vai para o outro lado.
  var heroEl = document.querySelector(".hero"), tilt = document.querySelector(".stage-tilt");
  if (heroEl && tilt && fine && !calm) {
    heroEl.addEventListener("pointermove", function (e) {
      var r = heroEl.getBoundingClientRect();
      var x = (e.clientX - r.left) / r.width - 0.5, y = (e.clientY - r.top) / r.height - 0.5;
      tilt.style.transform = "rotateY(" + (x * 5).toFixed(2) + "deg) rotateX(" + (-y * 4).toFixed(2) + "deg)";
      if (mascotBtn) mascotBtn.style.translate = (-x * 14).toFixed(1) + "px " + (-y * 10).toFixed(1) + "px";
    }, { passive: true });
    heroEl.addEventListener("pointerleave", function () {
      tilt.style.transform = "";
      if (mascotBtn) mascotBtn.style.translate = "";
    });
  }

  // Campo de pixels do topo: acendem perto do ponteiro e piscam sozinhos de vez em
  // quando. Só roda com o topo visível e a aba aberta.
  var cv = document.querySelector(".pixels");
  if (cv && !calm) (function () {
    var ctx = cv.getContext("2d", { alpha: true }), cell = 28, size = 4, cols = 0, rows = 0, lit = new Map(), colors = [], px = -1, py = -1;
    var visible = true, running = false, last = 0;
    function palette() {
      var cs = getComputedStyle(html);
      colors = [cs.getPropertyValue("--accent").trim(), cs.getPropertyValue("--accent").trim(), cs.getPropertyValue("--mention").trim()];
    }
    function resize() {
      var r = cv.getBoundingClientRect();
      cv.width = r.width;
      cv.height = r.height;
      cols = Math.ceil(r.width / cell);
      rows = Math.ceil(r.height / cell);
    }
    function loop(now) {
      if (!visible || document.hidden) { running = false; return; }
      if (!lit.size && px < 0) { ctx.clearRect(0, 0, cv.width, cv.height); running = false; return; }
      requestAnimationFrame(loop);
      if (now - last < 48) return;
      last = now;
      if (px >= 0) {
        var cx = Math.floor(px / cell), cy = Math.floor(py / cell);
        for (var n = 0; n < 9; n++) {
          var dx = Math.round((Math.random() - 0.5) * 9), dy = Math.round((Math.random() - 0.5) * 9), dist = Math.hypot(dx, dy);
          if (dist <= 5) lit.set(cx + dx + (cy + dy) * 10000, 1 - dist / 6);
        }
      }
      ctx.clearRect(0, 0, cv.width, cv.height);
      lit.forEach(function (v, key) {
        var x = key % 10000, y = Math.floor(key / 10000);
        ctx.globalAlpha = v * 0.75;
        ctx.fillStyle = colors[(x * 7 + y * 13) % colors.length];
        ctx.fillRect(x * cell + 12, y * cell + 12, size, size);
        var nv = v * 0.88;
        if (nv < 0.04) lit.delete(key); else lit.set(key, nv);
      });
      ctx.globalAlpha = 1;
    }
    function wake() {
      if (running || !visible || document.hidden) return;
      running = true;
      requestAnimationFrame(loop);
    }
    palette();
    resize();
    addEventListener("resize", resize);
    document.addEventListener("lc-theme", palette);
    document.addEventListener("visibilitychange", wake);
    // Um pixel aceso de vez em quando, para o fundo não ficar morto.
    setInterval(function () {
      if (!visible || document.hidden) return;
      lit.set(Math.floor(Math.random() * cols) + Math.floor(Math.random() * rows) * 10000, 0.8);
      wake();
    }, 420);
    if (fine) {
      cv.parentElement.addEventListener("pointermove", function (e) {
        var r = cv.getBoundingClientRect();
        px = e.clientX - r.left;
        py = e.clientY - r.top;
        wake();
      }, { passive: true });
      cv.parentElement.addEventListener("pointerleave", function () { px = -1; });
    }
    new IntersectionObserver(function (es) {
      visible = es[0].isIntersecting;
      wake();
    }).observe(cv);
  })();

  // ------------------------------------------------- Movimento na página ----
  var pointerFine = matchMedia("(hover: hover) and (pointer: fine)").matches;
  if (!calm) {
    // Cada item de lista e tabela entra em cascata ao aparecer.
    var riseIO = new IntersectionObserver(function (es) {
      es.forEach(function (x) {
        if (x.isIntersecting) { x.target.classList.add("in"); riseIO.unobserve(x.target); }
      });
    }, { rootMargin: "0px 0px -6% 0px" });
    [".rules li", ".ticks li", ".chain div", ".state tbody tr", ".facts tbody tr", ".stats div", ".tour-list li", ".colophon > div"].forEach(function (sel) {
      document.querySelectorAll(sel).forEach(function (el, i) {
        el.classList.add("rise");
        el.style.setProperty("--d", (sel.indexOf("tr") >= 0 ? i % 16 : i % 10));
        riseIO.observe(el);
      });
    });
    document.querySelectorAll(".split > img, .install video").forEach(function (el) {
      el.classList.add("clipin");
      riseIO.observe(el);
    });

    if (pointerFine) {
      // Cartões giram em 3D na direção do ponteiro, com um reflexo.
      document.querySelectorAll(".tcard-shots, .rules li, .ticks li, .stats div, .flow b").forEach(function (el) {
        el.addEventListener("pointermove", function (e) {
          var r = el.getBoundingClientRect(), x = (e.clientX - r.left) / r.width, y = (e.clientY - r.top) / r.height;
          el.style.transition = "transform .08s linear";
          el.style.transform = "perspective(760px) rotateY(" + ((x - 0.5) * 11).toFixed(2) + "deg) rotateX(" + ((0.5 - y) * 11).toFixed(2) + "deg) translateZ(14px)";
          el.style.setProperty("--gx", (x * 100).toFixed(0) + "%");
          el.style.setProperty("--gy", (y * 100).toFixed(0) + "%");
        });
        el.addEventListener("pointerleave", function () {
          el.style.transition = "";
          el.style.transform = "";
        });
      });
      // Botões atraídos pelo ponteiro.
      document.querySelectorAll(".btn, .lang").forEach(function (el) {
        el.addEventListener("pointermove", function (e) {
          var r = el.getBoundingClientRect();
          el.style.translate = ((e.clientX - r.left - r.width / 2) * 0.22).toFixed(1) + "px " + ((e.clientY - r.top - r.height / 2) * 0.32).toFixed(1) + "px";
        });
        el.addEventListener("pointerleave", function () { el.style.translate = ""; });
      });
      // Anel que persegue o ponteiro e cresce sobre o que é clicável.
      var ring = document.createElement("div"), rx = 0, ry = 0, tx = 0, ty = 0, ringOn = false;
      ring.className = "ring";
      ring.setAttribute("aria-hidden", "true");
      document.body.appendChild(ring);
      function chase() {
        rx += (tx - rx) * 0.2;
        ry += (ty - ry) * 0.2;
        ring.style.transform = "translate(" + rx.toFixed(1) + "px," + ry.toFixed(1) + "px)";
        if (Math.abs(tx - rx) + Math.abs(ty - ry) > 0.2) requestAnimationFrame(chase); else ringOn = false;
      }
      addEventListener("pointermove", function (e) {
        tx = e.clientX;
        ty = e.clientY;
        ring.classList.add("on");
        ring.classList.toggle("big", !!e.target.closest("a, button, select, textarea, .tcard-shots"));
        if (!ringOn) { ringOn = true; requestAnimationFrame(chase); }
      }, { passive: true });
    }

    // Faixas animadas aceleram e entortam com a velocidade da rolagem.
    var tickers = Array.prototype.map.call(document.querySelectorAll(".ticker div"), function (d) { return d.getAnimations()[0]; }).filter(Boolean);
    var tickerEls = Array.prototype.slice.call(document.querySelectorAll(".ticker"));
    var lastY = scrollY, speed = 0, speedOn = false;
    function settle() {
      speed *= 0.9;
      tickers.forEach(function (a) { a.playbackRate = 1 + Math.min(speed * 0.14, 9); });
      var sk = (Math.max(-9, Math.min(9, speed * 0.16))).toFixed(2);
      tickerEls.forEach(function (el, i) { el.style.transform = (i ? "rotate(.5deg)" : "rotate(-.7deg)") + " scale(1.02) skewX(" + sk + "deg)"; });
      if (speed > 0.3) requestAnimationFrame(settle);
      else { speedOn = false; tickerEls.forEach(function (el) { el.style.transform = ""; }); tickers.forEach(function (a) { a.playbackRate = 1; }); }
    }
    addEventListener("scroll", function () {
      speed = Math.min(speed + Math.abs(scrollY - lastY) * 0.5, 80);
      if (!speedOn) { speedOn = true; requestAnimationFrame(settle); }
      lastY = scrollY;
    }, { passive: true });
  }

  // Modo leve automático: mede os quadros em momentos curtos e, se o navegador não
  // está dando conta, desliga o que custa mais. Quem escolheu na paleta manda.
  if (!window.LC_fx && !calm) (function () {
    var slow = 0, rounds = 0;
    function sample() {
      if (html.classList.contains("lite") || rounds >= 4) return;
      if (document.hidden) return setTimeout(sample, 4000);
      var n = 0, t0 = performance.now();
      (function count(t) {
        n++;
        if (t - t0 < 1000) return requestAnimationFrame(count);
        rounds++;
        slow = n < 28 ? slow + 1 : 0;
        if (slow >= 2) html.classList.add("lite");
        else setTimeout(sample, 3000);
      })(t0);
    }
    setTimeout(sample, 1400);
  })();

  // O que está fora da tela não anima, e o vídeo só toca visível.
  var offIO = new IntersectionObserver(function (es) {
    es.forEach(function (x) {
      if (x.isIntersecting) x.target.removeAttribute("data-off"); else x.target.setAttribute("data-off", "");
    });
  }, { rootMargin: "120px" });
  document.querySelectorAll(".hero-first, .stage, .node, .ticker").forEach(function (el) { offIO.observe(el); });
  var vid = document.querySelector(".install video");
  if (vid) {
    if (!calm) new IntersectionObserver(function (es) {
      if (es[0].isIntersecting) vid.play().catch(function () {}); else vid.pause();
    }).observe(vid);
  }

  // O mascote pequeno anda na barra de progresso, na direção da rolagem.
  var buddy = document.querySelector(".buddy"), walkTimer = 0, buddyY = scrollY;
  if (buddy && !calm) addEventListener("scroll", function () {
    buddy.classList.add("walk");
    buddy.classList.toggle("back", scrollY < buddyY);
    buddyY = scrollY;
    clearTimeout(walkTimer);
    walkTimer = setTimeout(function () { buddy.classList.remove("walk"); }, 180);
  }, { passive: true });

  render();
  var mascot0 = document.querySelector(".mascot");
  if (mascot0) mascot0.classList.remove("pop");
})();
