// O playground: um leitor de KDL e um motor de layout em JS, na mesma ideia de
// src/theme/kdl.zig e src/theme/layout.zig. Só para mostrar no navegador o que um
// arquivo de tema faz; o app desenha com Dear ImGui, não com isto.
(function () {
  var box = document.querySelector("[data-playground]");
  if (!box) return;
  var lang = document.documentElement.dataset.lang;
  var S = lang === "pt"
    ? { ok: "ok: recarregado", err: "erro", kept: "o layout anterior continua valendo", unknown: "componente desconhecido", line: "linha", you: "você", hi: "isso aqui é só um arquivo?", ana: "é. salva e a janela muda.", msg: "Conversar em #geral", general: "geral", memes: "memes", setups: "setups", a: "alguém tem carregador usb-c na sala?", b: "olha o pôr do sol daqui de casa", c: "e se eu mudar a largura?", d: "muda. salvou, mudou." }
    : { ok: "ok: reloaded", err: "error", kept: "the previous layout stays in place", unknown: "unknown component", line: "line", you: "you", hi: "wait, this is just a file?", ana: "yep. save it and the window changes.", msg: "Message #general", general: "general", memes: "memes", setups: "setups", a: "anyone got a usb-c charger in the room?", b: "check out the sunset from my place", c: "and if I change the width?", d: "it changes. save, and it's there." };

  // ------------------------------------------------------------ Leitor ----
  function SyntaxErr(msg, line, col) { this.message = msg; this.line = line; this.col = col; }

  function tokens(src) {
    var out = [], i = 0, line = 1, ls = 0, n = src.length;
    function at() { return { line: line, col: i - ls + 1 }; }
    while (i < n) {
      var ch = src[i];
      if (src.startsWith("//", i)) { while (i < n && src[i] !== "\n") i++; continue; }
      if (src.startsWith("/*", i)) {
        var end = src.indexOf("*/", i);
        if (end < 0) { var p0 = at(); throw new SyntaxErr("/* without */", p0.line, p0.col); }
        for (var k = i; k < end; k++) if (src[k] === "\n") { line++; ls = k + 1; }
        i = end + 2;
        continue;
      }
      if (ch === "\n" || ch === ";") { out.push({ k: "nl", p: at() }); if (ch === "\n") { line++; ls = i + 1; } i++; continue; }
      if (ch === " " || ch === "\t" || ch === "\r") { i++; continue; }
      if (ch === "{" || ch === "}" || ch === "=") { out.push({ k: ch, p: at() }); i++; continue; }
      if (ch === '"') {
        var p = at(), j = i + 1, s = "";
        while (j < n && src[j] !== '"' && src[j] !== "\n") {
          if (src[j] === "\\") j++;
          s += src[j++];
        }
        if (src[j] !== '"') throw new SyntaxErr('unterminated string', p.line, p.col);
        out.push({ k: "str", v: s, p: p });
        i = j + 1;
        continue;
      }
      var pw = at(), w = i;
      while (w < n && ' \t\r\n{}=;"'.indexOf(src[w]) < 0) w++;
      out.push({ k: "word", v: src.slice(i, w), p: pw });
      i = w;
    }
    return out;
  }

  function value(t) {
    if (t.k === "str") return t.v;
    if (t.v === "#true") return true;
    if (t.v === "#false") return false;
    return isNaN(+t.v) ? t.v : +t.v;
  }

  function parse(src) {
    var toks = tokens(src), pos = 0;
    function block(depth) {
      var nodes = [];
      while (pos < toks.length) {
        var t = toks[pos];
        if (t.k === "nl") { pos++; continue; }
        if (t.k === "}") {
          if (!depth) throw new SyntaxErr("unexpected }", t.p.line, t.p.col);
          pos++;
          return nodes;
        }
        if (t.k !== "word" && t.k !== "str") throw new SyntaxErr("expected a node name", t.p.line, t.p.col);
        var node = { name: t.v, args: [], props: {}, kids: [], line: t.p.line };
        pos++;
        while (pos < toks.length && toks[pos].k !== "nl" && toks[pos].k !== "}") {
          var a = toks[pos];
          if (a.k === "{") { pos++; node.kids = block(depth + 1); break; }
          if (a.k === "=") throw new SyntaxErr("= without a property name", a.p.line, a.p.col);
          if (toks[pos + 1] && toks[pos + 1].k === "=") {
            var v = toks[pos + 2];
            if (!v || (v.k !== "word" && v.k !== "str")) throw new SyntaxErr("property " + a.v + " has no value", a.p.line, a.p.col);
            node.props[a.v] = value(v);
            pos += 3;
          } else { node.args.push(value(a)); pos++; }
        }
        nodes.push(node);
      }
      if (depth) {
        var last = toks[toks.length - 1];
        throw new SyntaxErr("missing }", last ? last.p.line : 1, last ? last.p.col : 1);
      }
      return nodes;
    }
    return block(0);
  }

  // ------------------------------------------------------------- Cores ----
  function hexRgb(c) {
    c = c.replace("#", "");
    if (c.length < 6) c = c.split("").map(function (x) { return x + x; }).join("");
    return [parseInt(c.slice(0, 2), 16), parseInt(c.slice(2, 4), 16), parseInt(c.slice(4, 6), 16)];
  }
  function colorOf(expr, toks) {
    var e = String(expr).trim();
    if (e[0] === "@" || toks[e] !== undefined) return toks[e.replace("@", "")] || null;
    var m = /^(mix|alpha|lighten|darken)\((.*)\)$/.exec(e);
    if (m) {
      var args = [], depth = 0, cur = "";
      m[2].split("").forEach(function (ch) {
        if (ch === "," && !depth) { args.push(cur); cur = ""; return; }
        if (ch === "(") depth++;
        if (ch === ")") depth--;
        cur += ch;
      });
      args.push(cur);
      var a = colorOf(args[0], toks);
      if (!a) return null;
      if (m[1] === "alpha") return "color-mix(in srgb," + a + " " + (+args[1] * 100) + "%,transparent)";
      if (m[1] === "mix") {
        var b = colorOf(args[1], toks);
        return b && "color-mix(in srgb," + a + "," + b + " " + (+args[2] * 100) + "%)";
      }
      return "color-mix(in srgb," + a + "," + (m[1] === "lighten" ? "white " : "black ") + (+args[1] * 100) + "%)";
    }
    if (/^(#|rgb)/.test(e) || e === "white" || e === "black" || e === "transparent") return e;
    return null;
  }

  // ------------------------------------------------------------ Layout ----
  var CONTAINERS = { row: "m-row", column: "m-col", stack: "m-stack" };

  function el(cls, html) {
    var d = document.createElement("div");
    d.className = "m " + cls;
    if (html) d.innerHTML = html;
    return d;
  }

  var comps = {
    "guild-bar": function (p, parent) {
      var size = +p.size || 44;
      var d = el("m-guild" + (p.orientation === "horizontal" ? " h" : "") + (p.shape === "square" ? " sq" : p.shape === "squircle" ? " sc" : ""));
      for (var i = 0; i < 9; i++) {
        var c = document.createElement("i");
        c.style.width = c.style.height = size + "px";
        d.appendChild(c);
      }
      return d;
    },
    "channel-list": function (p) {
      var tree = p.variant === "tree" ? "├ " : "# ";
      return el("m-list", (p.header === false ? "" : "<b>SigmaCord dev</b>") + "<small>general</small><span>" + tree + "rules</span><span class='on'>" + tree + S.general + "</span><span>" + tree + S.memes + "</span><span>" + tree + S.setups + "</span><small>voice</small><span>" + tree + "late-night call</span>");
    },
    "user-panel": function () { return el("m-user", "<u></u><span>rsha</span>"); },
    header: function (p) { return el("m-header", "# " + S.general + (p.variant === "minimal" ? "" : "<small>no spam</small>")); },
    tabs: function () { return el("m-tabs", "<span class='on'>#" + S.general + "</span><span>#zig</span><span>#" + S.memes + "</span>"); },
    messages: function (p) {
      var v = p.variant === "irc" ? " m-irc" : p.variant === "bubbles" ? " m-bub" : "";
      var av = p.avatar === "none" || p.variant === "irc" ? "" : "<u></u>";
      var line = function (who, text, me) { return "<div class='m-msg" + (me ? " me" : "") + "'>" + av + "<div><b>" + who + "</b><p>" + text + "</p></div></div>"; };
      return el("m-msgs" + v,
        line("kaique", S.a) + line("duda", S.b) + "<div class='m-pic'></div>" +
        line("ana.exe", S.hi) + line("rsha", S.ana, true) + line("ana.exe", S.c) + line("rsha", S.d, true));
    },
    composer: function (p) {
      var v = p.variant === "pill" ? " pill" : p.variant === "prompt" ? " prompt" : "";
      return el("m-comp" + v, "<div>" + (p.variant === "prompt" ? "rsha@" + S.general + " ❯" : S.msg) + "</div>");
    },
    "member-list": function () { return el("m-members", "<small>online — 3</small><span>rsha</span><span>ana.exe</span><span>brunão</span><small>offline</small><span>duda</span>"); },
    "status-bar": function (p) {
      var items = String(p.items || "conn theme ping ram spacer clock").split(/\s+/);
      var map = { conn: "● demo", ping: "0 ms", ram: "48 MB", frame: "0.4 ms", voice: "", theme: "theme", keys: "Ctrl+K", clock: "21:30" };
      return el("m-status", items.map(function (x) { return x === "spacer" ? "<span class='sp'></span>" : "<span>" + (map[x] || "") + "</span>"; }).join(""));
    },
    topbar: function () { return el("m-topbar", "<div>Ctrl+K</div>"); },
    label: function (p, _, toks) {
      var d = el("m-label");
      d.textContent = p.text || "";
      if (p.size) d.style.fontSize = p.size + "px";
      if (p.weight) d.style.fontWeight = { regular: 400, medium: 500, semibold: 600, bold: 700 }[p.weight] || 400;
      if (p.color) d.style.color = "var(--t-" + p.color + ")";
      if (p.align === "right") d.style.justifyContent = "flex-end";
      if (p.align === "center") d.style.justifyContent = "center";
      if (p.font === "mono") d.style.fontFamily = "var(--mono)";
      else if (p.font && p.font !== "ui") d.style.fontFamily = "Fraunces,serif";
      return d;
    },
    logo: function (p) { return el("m-logo", "SigmaCord"); },
    crt: function () { return el("m-crt"); },
    spacer: function () { return el("m-spacer"); },
  };

  function visible(n, opts, width) {
    var p = n.props;
    if (p.show === false) return false;
    if (p.when !== undefined && !opts[p.when]) return false;
    if (p.unless !== undefined && opts[p.unless]) return false;
    if (p["hide-below"] !== undefined && width < +p["hide-below"]) return false;
    return true;
  }

  function build(n, axis, ctx) {
    var p = n.props, d;
    if (CONTAINERS[n.name]) {
      d = el(CONTAINERS[n.name]);
      if (p.gap) d.style.gap = p.gap + "px";
      if (p.padding !== undefined) d.style.padding = p.padding + "px";
      if (p["padding-x"] !== undefined) { d.style.paddingLeft = d.style.paddingRight = p["padding-x"] + "px"; }
      if (p["padding-y"] !== undefined) { d.style.paddingTop = d.style.paddingBottom = p["padding-y"] + "px"; }
      var childAxis = n.name === "row" ? "row" : n.name === "column" ? "column" : "stack";
      n.kids.filter(function (k) { return visible(k, ctx.opts, ctx.width); }).forEach(function (k) { d.appendChild(build(k, childAxis, ctx)); });
    } else if (comps[n.name]) {
      d = comps[n.name](p, axis, ctx.toks);
      if (p.autohide === true) d.style.opacity = ".35";
    } else {
      d = el("m-bad", S.unknown + ": " + n.name + "<br>" + S.line + " " + n.line);
    }
    // Tamanho no eixo do pai, como em src/theme/layout.zig: fixo ou flex.
    var main = axis === "row" ? "width" : "height";
    if (axis !== "stack") {
      if (p[main] !== undefined) { d.style.flex = "0 0 " + p[main] + "px"; d.style[main] = p[main] + "px"; }
      else d.style.flex = (p.flex !== undefined ? p.flex : 1) + " 1 0";
    }
    if (p["max-width"] !== undefined) { d.style.maxWidth = p["max-width"] + "px"; d.style.marginLeft = d.style.marginRight = "auto"; d.style.width = "100%"; }
    if (p["inset-x"] !== undefined) d.style.marginLeft = d.style.marginRight = p["inset-x"] + "px";
    if (p["inset-y"] !== undefined) d.style.marginTop = d.style.marginBottom = p["inset-y"] + "px";
    // Fundo: style= ou bg=/radius= direto.
    var st = p.style && ctx.styles[p.style];
    var bg = (st && st.bg) || p.bg;
    if (bg) { var col = colorOf(bg, ctx.toks); if (col) d.style.background = col; }
    var rad = p.radius !== undefined ? p.radius : st && st.radius;
    if (rad !== undefined) d.style.borderRadius = rad + "px";
    if (st && st.border) {
      var bc = colorOf(st.border, ctx.toks);
      if (bc) d.style.border = (st["border-width"] || 1) + "px solid " + bc;
    }
    if (p.font === "mono") d.style.fontFamily = "var(--mono)";
    else if (p.font && p.font !== "ui" && n.name !== "label") d.style.fontFamily = "Fraunces,serif";
    // c-<token> vale neste nó e nos filhos.
    Object.keys(p).forEach(function (k) {
      if (k.indexOf("c-") === 0) {
        var c = colorOf(p[k], ctx.toks);
        if (c) d.style.setProperty("--t-" + k.slice(2), c);
      }
    });
    return d;
  }

  // ------------------------------------------------------------- Tela ----
  var area = box.querySelector("textarea");
  var pre = box.querySelector(".pg-code pre code");
  var screen = box.querySelector(".pg-screen");
  var frame = box.querySelector(".pg-frame");
  var status = box.querySelector(".pg-status");
  var select = box.querySelector("select");
  var lastTree = null;

  function hl(src) {
    var esc = function (s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;"); };
    var re = /(\/\/[^\n]*)|("(?:\\.|[^"\\\n])*")|(#true|#false|\b\d+(?:\.\d+)?\b)|([\w-]+(?==))|(^[ \t]*[\w-]+)/gm;
    var out = "", last = 0, m;
    while ((m = re.exec(src))) {
      if (m[0] === "") { re.lastIndex++; continue; }
      out += esc(src.slice(last, m.index));
      var c = m[1] ? "c" : m[2] ? "s" : m[3] ? "n" : m[4] ? "p" : "k";
      out += '<span class="t-' + c + '">' + esc(m[0]) + "</span>";
      last = m.index + m[0].length;
    }
    return out + esc(src.slice(last)) + "\n";
  }

  function fit() {
    var w = screen.clientWidth, h = screen.clientHeight;
    if (!w || !h) return;
    var vw = Math.max(1280, 800 * (w / h));
    var scale = w / vw;
    frame.style.width = vw + "px";
    frame.style.height = h / scale + "px";
    frame.style.transform = "scale(" + scale + ")";
    screen.style.height = "";
    return vw;
  }

  function render() {
    var src = area.value;
    pre.innerHTML = hl(src);
    var nodes;
    try {
      nodes = parse(src);
    } catch (e) {
      if (!(e instanceof SyntaxErr)) throw e;
      status.className = "pg-status err";
      status.textContent = "playground.kdl:" + e.line + ":" + e.col + ": " + e.message + " · " + S.kept;
      return;
    }
    var layout = nodes.filter(function (n) { return n.name === "layout"; })[0];
    if (!layout || !layout.kids.length) {
      status.className = "pg-status err";
      status.textContent = "playground.kdl: layout { … } · " + S.kept;
      return;
    }
    var toks = {};
    var defaults = window.LC_DATA.themes[select.value || "orbital"];
    Object.keys(defaults.dark).forEach(function (k) { toks[k] = defaults.dark[k]; });
    var opts = {}, styles = {};
    nodes.forEach(function (n) {
      if (n.name === "colors") n.kids.forEach(function (c) {
        var v = colorOf(c.args[0], toks);
        if (v) toks[c.name] = v;
      });
      if (n.name === "options") n.kids.forEach(function (o) { opts[o.args[0]] = o.props.default !== false; });
      if (n.name === "styles") n.kids.forEach(function (s) { styles[s.args[0]] = s.props; });
    });
    var vw = fit() || 1280;
    frame.innerHTML = "";
    Object.keys(toks).forEach(function (k) { frame.style.setProperty("--t-" + k, toks[k]); });
    frame.style.background = toks.bg;
    var tree = build(layout.kids[0], "stack", { toks: toks, opts: opts, styles: styles, width: vw });
    tree.style.position = "absolute";
    tree.style.inset = "0";
    frame.appendChild(tree);
    status.className = "pg-status";
    status.textContent = S.ok;
  }

  var pending = 0;
  area.addEventListener("input", function () {
    clearTimeout(pending);
    pre.innerHTML = hl(area.value);
    pending = setTimeout(render, 90);
  });
  area.addEventListener("scroll", function () {
    pre.parentElement.scrollTop = area.scrollTop;
    pre.parentElement.scrollLeft = area.scrollLeft;
  });
  area.addEventListener("keydown", function (e) {
    if (e.key === "Tab" && !e.shiftKey) {
      e.preventDefault();
      area.setRangeText("    ", area.selectionStart, area.selectionEnd, "end");
      area.dispatchEvent(new Event("input"));
    }
  });
  select.addEventListener("change", function () { load(select.value); });
  box.querySelector("[data-pg-reset]").addEventListener("click", function () { load(select.value); });
  box.querySelector("[data-pg-break]").addEventListener("click", function () {
    area.value = area.value.replace(/\n(\s*)messages\b/, "\n$1messagez");
    area.dispatchEvent(new Event("input"));
  });
  box.querySelector("[data-pg-swap]").addEventListener("click", function () {
    // Inverte a ordem dos filhos do primeiro `row flex=1` com mais de um filho, editando o texto de verdade.
    var nodes;
    try { nodes = parse(area.value); } catch (e) { return; }
    var lines = area.value.split("\n");
    var m = lines.findIndex(function (l) { return /^\s*member-list\b/.test(l); });
    var c = lines.findIndex(function (l) { return /^\s*(column|channel-list)\b.*(width=)/.test(l); });
    if (m < 0 || c < 0 || m < c) return;
    var mem = lines.splice(m, 1)[0].replace(/^\s*/, lines[c].match(/^\s*/)[0]);
    lines.splice(c, 0, mem);
    area.value = lines.join("\n");
    area.dispatchEvent(new Event("input"));
  });

  function load(name) {
    area.value = window.LC_PRESETS[name];
    area.scrollTop = 0;
    render();
  }

  // Enquanto ninguém mexe, o arquivo se edita sozinho: é o que acontece ao salvar.
  var touched = matchMedia("(prefers-reduced-motion: reduce)").matches, visibleNow = false, demoStep = 0;
  box.addEventListener("pointerdown", function () { touched = true; });
  box.addEventListener("keydown", function () { touched = true; });
  new IntersectionObserver(function (es) { visibleNow = es[0].isIntersecting; }, { threshold: 0.4 }).observe(box);
  setInterval(function () {
    if (touched || !visibleNow || !area.value || document.hidden) return;
    var src = area.value, m;
    if (demoStep % 2 === 0) {
      m = /((?:column|channel-list) width=)(\d+)/.exec(src);
      if (m) src = src.replace(m[0], m[1] + (+m[2] < 300 ? +m[2] + 170 : +m[2] - 170));
    } else {
      m = /(messages[^\n]*?variant=)(\w+)/.exec(src);
      if (m) src = src.replace(m[0], m[1] + (m[2] === "bubbles" ? "irc" : "bubbles"));
      else {
        m = /(messages)( flex=1)/.exec(src);
        if (m) src = src.replace(m[0], m[0] + " variant=bubbles");
      }
    }
    demoStep++;
    area.value = src;
    render();
    box.classList.remove("saved");
    void box.offsetWidth;
    box.classList.add("saved");
  }, 2400);

  if (window.ResizeObserver) new ResizeObserver(function () { if (area.value) render(); }).observe(screen);
  // Abre quando chega perto da tela: os presets só carregam se alguém for usar.
  var started = false;
  new IntersectionObserver(function (es) {
    if (started || !es[0].isIntersecting) return;
    started = true;
    var s = document.createElement("script");
    s.src = document.documentElement.dataset.root + "assets/site/presets.js";
    s.onload = function () { load(select.value); };
    document.head.appendChild(s);
  }, { rootMargin: "400px" }).observe(box);
})();
