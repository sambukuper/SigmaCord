#!/usr/bin/env python3
"""Gera o site do GitHub Pages em docs/ (inglês na raiz, português em docs/pt/).

Entradas:
  site/landing.html         a página inicial, com os textos como {{inglês||português}}
  site/guide/{en,pt}/*.md   os guias
  docs/plugins*.md, themes/README*.md   guias que também vivem fora do site
  themes/*.kdl              paletas, opções e layouts dos temas (a fonte de verdade)

Só usa a biblioteca padrão. Rode: python3 tools/gen_site.py
"""
import html
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs"
SITE = ROOT / "site"
REPO = "https://github.com/sambukuper/SigmaCord"
VERSION = re.search(r'number = "(.+?)"', (ROOT / "src/core/version.zig").read_text()).group(1)
BASE_URL = "https://sambukuper.github.io/SigmaCord/"
THEMES = ["classico", "vidro", "terminal", "subsolo", "orbital", "editorial", "bolhas", "zen", "papel", "escritorio", "cupertino"]
LANGS = ["en", "pt"]


# ---------------------------------------------------------------- KDL ----
class Node:
    def __init__(self, name, start):
        self.name, self.start, self.end = name, start, start
        self.args, self.props, self.children = [], {}, []


def kdl_tokens(src):
    i, n = 0, len(src)
    while i < n:
        ch = src[i]
        if src.startswith("//", i):
            while i < n and src[i] != "\n":
                i += 1
        elif src.startswith("/*", i):
            i = src.index("*/", i) + 2
        elif ch == "\n" or ch == ";":
            yield ("nl", ch, i, i + 1)
            i += 1
        elif ch in " \t\r":
            i += 1
        elif ch == "\\":
            i += 1
            while i < n and src[i] in " \t\r\n":
                i += 1
        elif ch in "{}=":
            yield (ch, ch, i, i + 1)
            i += 1
        elif ch == '"':
            j, out = i + 1, []
            while src[j] != '"':
                if src[j] == "\\":
                    j += 1
                    out.append({"n": "\n", "t": "\t"}.get(src[j], src[j]))
                else:
                    out.append(src[j])
                j += 1
            yield ("str", "".join(out), i, j + 1)
            i = j + 1
        else:
            j = i
            while j < n and src[j] not in ' \t\r\n{}=;"':
                j += 1
            yield ("word", src[i:j], i, j)
            i = j


def kdl_value(tok):
    kind, val = tok[0], tok[1]
    if kind == "str":
        return val
    if val == "#true":
        return True
    if val == "#false":
        return False
    try:
        return float(val) if "." in val else int(val)
    except ValueError:
        return val


def kdl_parse(src):
    toks = list(kdl_tokens(src))
    pos = [0]

    def block():
        nodes = []
        while pos[0] < len(toks):
            t = toks[pos[0]]
            if t[0] == "nl":
                pos[0] += 1
            elif t[0] == "}":
                pos[0] += 1
                return nodes
            else:
                node = Node(t[1], t[2])
                node.end = t[3]
                pos[0] += 1
                while pos[0] < len(toks) and toks[pos[0]][0] not in ("nl", "}"):
                    a = toks[pos[0]]
                    if a[0] == "{":
                        pos[0] += 1
                        node.children = block()
                        node.end = toks[pos[0] - 1][3]
                        break
                    if pos[0] + 1 < len(toks) and toks[pos[0] + 1][0] == "=":
                        node.props[a[1]] = kdl_value(toks[pos[0] + 2])
                        node.end = toks[pos[0] + 2][3]
                        pos[0] += 3
                    else:
                        node.args.append(kdl_value(a))
                        node.end = a[3]
                        pos[0] += 1
                nodes.append(node)
        return nodes

    return block()


# -------------------------------------------------------------- Cores ----
# As mesmas contas de src/theme/color.zig e dos padrões de src/theme/theme.zig.
FALLBACK = ["15161b", "e06c75", "98c379", "e5c07b", "7aa2f7", "c678dd", "56b6c2", "d7dae0",
            "5c6370", "e06c75", "98c379", "e5c07b", "7aa2f7", "c678dd", "56b6c2", "f0f2f5"]


def rgb(hexstr):
    h = hexstr.lstrip("#")
    if len(h) in (3, 4):
        h = "".join(c * 2 for c in h)
    a = int(h[6:8], 16) / 255 if len(h) == 8 else 1.0
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a)


WHITE, BLACK = (255, 255, 255, 1.0), (0, 0, 0, 1.0)


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(4))


def alpha(a, t):
    return (a[0], a[1], a[2], t)


def luma(c):
    return (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255


def css(c):
    r, g, b = (round(max(0, min(255, v))) for v in c[:3])
    if c[3] >= 0.999:
        return f"#{r:02x}{g:02x}{b:02x}"
    return f"rgba({r},{g},{b},{c[3]:.3f})"


def split_args(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            depth += ch == "("
            depth -= ch == ")"
            cur += ch
    out.append(cur)
    return [x.strip() for x in out]


def color_eval(expr, pal, toks):
    e = str(expr).strip()
    if e.startswith("#"):
        return rgb(e)
    if e.startswith("wal:"):
        return pal[int(e[4:])]
    if e.startswith("@"):
        return toks[e[1:]]
    if e == "white":
        return WHITE
    if e == "black":
        return BLACK
    if e == "transparent":
        return (0, 0, 0, 0.0)
    m = re.fullmatch(r"(\w+)\((.*)\)", e)
    if m:
        args = split_args(m.group(2))
        if m.group(1) == "mix":
            return mix(color_eval(args[0], pal, toks), color_eval(args[1], pal, toks), float(args[2]))
        if m.group(1) == "alpha":
            return alpha(color_eval(args[0], pal, toks), float(args[1]))
        if m.group(1) == "lighten":
            a = color_eval(args[0], pal, toks)
            return mix(a, alpha(WHITE, a[3]), float(args[1]))
        if m.group(1) == "darken":
            a = color_eval(args[0], pal, toks)
            return mix(a, alpha(BLACK, a[3]), float(args[1]))
    raise ValueError(f"cor desconhecida: {expr}")


def default_tokens(p, mode):
    if mode == "dark":
        bg, fg = p[0], p[15]
        accent = p[4]
        on = BLACK if luma(accent) > 0.6 else WHITE
        return {"bg": mix(bg, fg, .035), "rail": mix(bg, BLACK, .38), "sidebar": mix(bg, BLACK, .18),
                "surface": mix(bg, fg, .035), "elevated": mix(bg, fg, .085), "overlay": mix(bg, BLACK, .55),
                "text": fg, "muted": mix(fg, bg, .42), "faint": mix(fg, bg, .62), "accent": accent, "accent-text": on,
                "border": alpha(fg, .08), "hover": alpha(fg, .05), "selected": alpha(fg, .10),
                "online": rgb("45b36b"), "idle": rgb("e5a83b"), "dnd": rgb("e5484d"), "danger": rgb("e5484d"),
                "mention": accent, "link": mix(accent, fg, .25), "code-bg": mix(bg, BLACK, .45),
                "bubble-self": accent, "bubble-self-text": on, "bubble-other": mix(bg, fg, .1), "shadow": alpha(BLACK, .35)}
    tint = p[0]
    bg = mix(WHITE, tint, .035)
    ink = mix(mix(tint, BLACK, .55), p[15], .05)
    accent = mix(p[4], BLACK, .3) if luma(p[4]) > .5 else p[4]
    on = BLACK if luma(accent) > .6 else WHITE
    return {"bg": bg, "rail": mix(WHITE, tint, .12), "sidebar": mix(WHITE, tint, .07), "surface": bg,
            "elevated": mix(WHITE, tint, .09), "overlay": WHITE, "text": ink, "muted": mix(ink, bg, .4),
            "faint": mix(ink, bg, .6), "accent": accent, "accent-text": on, "border": alpha(ink, .1),
            "hover": alpha(ink, .05), "selected": alpha(accent, .13), "online": rgb("23a55a"), "idle": rgb("d08a12"),
            "dnd": rgb("d83a42"), "danger": rgb("d83a42"), "mention": accent, "link": mix(accent, BLACK, .1),
            "code-bg": mix(bg, ink, .07), "bubble-self": accent, "bubble-self-text": on,
            "bubble-other": mix(WHITE, tint, .1), "shadow": alpha(BLACK, .12)}


# O "estilo" do site em cada tema: tipografia e efeitos. As cores vêm do .kdl.
FLAVOR = {
    "classico": {"display": "grotesk", "fx": ""},
    "vidro": {"display": "grotesk", "fx": "glass"},
    "terminal": {"display": "mono", "fx": "crt"},
    "subsolo": {"display": "mono", "fx": "crt"},
    "orbital": {"display": "wide", "fx": ""},
    "editorial": {"display": "serif", "fx": ""},
    "bolhas": {"display": "round", "fx": ""},
    "zen": {"display": "thin", "fx": ""},
    "papel": {"display": "serif", "fx": "ruled"},
    "escritorio": {"display": "plain", "fx": ""},
    "cupertino": {"display": "plain", "fx": ""},
}


def load_themes():
    out = {}
    for name in THEMES:
        src = (ROOT / "themes" / f"{name}.kdl").read_text(encoding="utf-8")
        nodes = kdl_parse(src)
        top = {n.name: n for n in nodes}
        t = top["theme"]
        options = []
        if "options" in top:
            for o in top["options"].children:
                options.append({"name": o.args[0], "default": o.props.get("default", True),
                                "label": o.props.get("label", o.args[0]), "desc": o.props.get("description", ""),
                                "labelEn": o.props.get("label-en", o.props.get("label", o.args[0])),
                                "descEn": o.props.get("description-en", o.props.get("description", ""))})
        on = {o["name"] for o in options if o["default"]}
        pal = [rgb(x) for x in FALLBACK]
        if "palette" in top and top["palette"].args and top["palette"].args[0] != "wal":
            pal = [rgb(x) for x in top["palette"].args] + pal[len(top["palette"].args):]
        modes, raw = {}, {}
        for mode in ("dark", "light"):
            toks = default_tokens(pal, mode)
            for n in nodes:
                if n.name != "colors":
                    continue
                if n.props.get("mode", mode) != mode:
                    continue
                if "when" in n.props and n.props["when"] not in on:
                    continue
                for c in n.children:
                    toks[c.name] = color_eval(c.args[0], pal, toks)
            modes[mode] = {k: css(v) for k, v in toks.items()}
            raw[mode] = toks
        radius = top["metrics"].props.get("radius", 6) if "metrics" in top else 6
        # O que o playground abre: o layout e os estilos do arquivo, como estão,
        # mais as cores já resolvidas (no arquivo podem depender do pywal).
        keep = ["bg", "rail", "sidebar", "surface", "elevated", "text", "muted", "faint", "accent", "accent-text",
                "border", "selected", "online", "mention", "bubble-self", "bubble-self-text", "bubble-other"]
        lines = [f"// themes/{name}.kdl: try changing a width", src[top["layout"].start:top["layout"].end], ""]
        if options:
            lines.append("options {")
            lines += [f'    option "{o["name"]}" default={"#true" if o["default"] else "#false"}' for o in options]
            lines.append("}")
        if "styles" in top:
            lines.append(src[top["styles"].start:top["styles"].end])
        lines.append("colors {")
        lines += [f'    {k} "{modes["dark"][k]}"' for k in keep]
        lines.append("}")
        out[name] = {"desc": t.props.get("description", ""), "descEn": t.props.get("description-en", t.props.get("description", "")),
                     "radius": radius, "options": options, "dark": modes["dark"], "light": modes["light"],
                     "preset": "\n".join(lines), "nodes": layout_nodes(src, top, on, pal, raw), **FLAVOR[name]}
    return out


# O tema do próprio site: neon sobre preto, terminal e zine. Não existe no app.
BRAND = {
    "desc": "", "descEn": "", "radius": 0, "options": [], "display": "pixel", "fx": "zine", "preset": "",
    "dark": {"bg": "#050505", "rail": "#030208", "sidebar": "#0a050f", "surface": "#0a050f", "elevated": "#140a1f",
             "overlay": "#0a050f", "text": "#e5e7eb", "muted": "#9c95ab", "faint": "#5e5669", "accent": "#d946ef",
             "accent-text": "#0a0210", "border": "#2a1740", "hover": "rgba(217,70,239,.08)", "selected": "rgba(217,70,239,.15)",
             "online": "#22c55e", "idle": "#f59e0b", "dnd": "#ef4444", "danger": "#ef4444", "mention": "#06b6d4",
             "link": "#22d3ee", "code-bg": "#0a0a0a", "bubble-self": "#9333ea", "bubble-self-text": "#fff",
             "bubble-other": "#140a1f", "shadow": "rgba(0,0,0,.6)"},
    "light": {"bg": "#ffffff", "rail": "#f1f5f9", "sidebar": "#f8fafc", "surface": "#f8fafc", "elevated": "#ffffff",
              "overlay": "#ffffff", "text": "#111827", "muted": "#4b5563", "faint": "#9ca3af", "accent": "#7c3aed",
              "accent-text": "#ffffff", "border": "#d1d5db", "hover": "rgba(124,58,237,.07)", "selected": "rgba(124,58,237,.12)",
              "online": "#166534", "idle": "#92400e", "dnd": "#b91c1c", "danger": "#dc2626", "mention": "#0e7490",
              "link": "#0e7490", "code-bg": "#f6f8fa", "bubble-self": "#6d28d9", "bubble-self-text": "#fff",
              "bubble-other": "#e5e7eb", "shadow": "rgba(40,10,60,.12)"},
}


# ------------------------------------------------------------- Realce ----
HL = {
    "kdl": r'''(?P<c>//[^\n]*)|(?P<s>"(?:\\.|[^"\\])*")|(?P<n>\#true|\#false|\b\d+(?:\.\d+)?\b)|(?P<p>[\w-]+(?==))|(?P<k>^[ \t]*[\w-]+)''',
    "lua": r'''(?P<c>--[^\n]*)|(?P<s>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(?P<n>\b\d+\b)|(?P<k>\b(?:local|function|end|if|then|else|elseif|for|in|do|while|return|not|and|or|nil|true|false)\b)|(?P<p>\bsigma\.\w+)''',
    "bash": r'''(?P<c>(?:^|(?<=\s))\#[^\n]*)|(?P<s>"(?:\\.|[^"\\])*"|'[^']*')|(?P<k>^[ \t]*(?:sudo\s+)?[\w./-]+)|(?P<p>(?<=\s)--?[\w-]+)''',
    "zig": r'''(?P<c>//[^\n]*)|(?P<s>"(?:\\.|[^"\\])*")|(?P<n>\b\d+\b)|(?P<k>\b(?:const|var|fn|pub|return|if|else|while|for|try|struct)\b)''',
}


def highlight(code, lang):
    pat = HL.get({"sh": "bash", "shell": "bash"}.get(lang, lang))
    if not pat:
        return html.escape(code, quote=False)
    out, last = [], 0
    for m in re.finditer(pat, code, re.M):
        if m.start() == m.end():
            continue
        out.append(html.escape(code[last:m.start()], quote=False))
        out.append(f'<span class="t-{m.lastgroup}">{html.escape(m.group(0), quote=False)}</span>')
        last = m.end()
    out.append(html.escape(code[last:], quote=False))
    return "".join(out)


def code_block(code, lang):
    label = f'<span class="code-lang">{html.escape(lang)}</span>' if lang else ""
    return (f'<div class="code" data-lang="{html.escape(lang)}">{label}<button class="copy" type="button" data-copy>copy</button>'
            f'<pre><code>{highlight(code, lang)}</code></pre></div>')


# ----------------------------------------------------------- Markdown ----
def slugify(s):
    s = re.sub(r"<[^>]+>", "", s).lower()
    s = re.sub(r"[`*]", "", s)
    table = str.maketrans("áàãâéêíóõôúç", "aaaaeeiooouc")
    s = s.translate(table)
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", s)).strip("-")


def inline(text, rewrite):
    keep = []

    def stash(v):
        keep.append(v)
        return f"\x00{len(keep) - 1}\x00"

    text = re.sub(r"`([^`]+)`", lambda m: stash(f"<code>{html.escape(m.group(1), quote=False)}</code>"), text)
    # HTML que os documentos usam de propósito (<sub>) passa; o resto é escapado.
    text = re.sub(r"</?sub>", lambda m: stash(m.group(0)), text)
    text = html.escape(text, quote=False)
    text = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)", lambda m: stash(f'<img src="{rewrite(m.group(2))}" alt="{m.group(1)}" loading="lazy">'), text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", lambda m: f'<a href="{rewrite(m.group(2))}">{m.group(1)}</a>', text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w*])\*([^*\n]+)\*(?![\w*])", r"<em>\1</em>", text)
    text = re.sub(r"~~([^~]+)~~", r"<s>\1</s>", text)
    return re.sub(r"\x00(\d+)\x00", lambda m: keep[int(m.group(1))], text)


def split_row(line):
    line = line.strip().strip("|")
    cells, cur, in_code = [], "", False
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == "`":
            in_code = not in_code
        if ch == "\\" and i + 1 < len(line) and line[i + 1] == "|":
            cur += "|"
            i += 2
            continue
        if ch == "|" and not in_code:
            cells.append(cur.strip())
            cur = ""
        else:
            cur += ch
        i += 1
    cells.append(cur.strip())
    return cells


ALERTS = {"WARNING": "warn", "IMPORTANT": "warn", "NOTE": "note", "TIP": "note"}


def markdown(src, rewrite, skip_h1=False):
    lines = src.split("\n")
    out, heads = [], []
    i = 0
    seen = {}

    def heading(level, text):
        base = slugify(text) or "section"
        n = seen.get(base, 0)
        seen[base] = n + 1
        hid = base if n == 0 else f"{base}-{n}"
        heads.append((level, re.sub(r"`", "", text), hid))
        return f'<h{level} id="{hid}"><a class="anchor" href="#{hid}" aria-hidden="true">#</a>{inline(text, rewrite)}</h{level}>'

    def blocks_list(start):
        j = start
        kind = "ol" if re.match(r"\s*\d+\.\s", lines[j]) else "ul"
        items = []
        while j < len(lines):
            m = re.match(r"(\s*)(?:[-*]|\d+\.)\s+(.*)", lines[j])
            if m and not m.group(1):
                items.append(m.group(2))
                j += 1
            elif m or (lines[j].startswith("  ") and lines[j].strip()):
                items[-1] += "\n" + lines[j].strip()
                j += 1
            elif not lines[j].strip() and j + 1 < len(lines) and re.match(r"(?:[-*]|\d+\.)\s", lines[j + 1]):
                j += 1
            else:
                break
        body = []
        for it in items:
            if "```" in it:
                body.append("<li>" + markdown(it, rewrite)[0] + "</li>")
                continue
            task = re.match(r"\[( |x)\]\s+(.*)", it, re.S)
            if task:
                state = "done" if task.group(1) == "x" else "todo"
                body.append(f'<li class="task {state}">{inline(task.group(2), rewrite)}</li>')
            else:
                body.append(f"<li>{inline(it, rewrite)}</li>")
        return f"<{kind}>" + "".join(body) + f"</{kind}>", j

    while i < len(lines):
        ln = lines[i]
        if not ln.strip():
            i += 1
        elif ln.startswith("```"):
            lang = ln[3:].strip()
            j = i + 1
            while not lines[j].startswith("```"):
                j += 1
            out.append(code_block("\n".join(lines[i + 1:j]), lang))
            i = j + 1
        elif re.match(r"#{1,6}\s", ln):
            lv = len(ln) - len(ln.lstrip("#"))
            text = ln[lv:].strip()
            if not (lv == 1 and skip_h1):
                out.append(heading(lv, text))
            i += 1
        elif ln.startswith(">"):
            j = i
            quote = []
            while j < len(lines) and lines[j].startswith(">"):
                quote.append(lines[j][1:].lstrip(" "))
                j += 1
            kind = "note"
            m = re.match(r"\[!(\w+)\]", quote[0])
            if m:
                kind = ALERTS.get(m.group(1), "note")
                quote = quote[1:]
            inner, _ = markdown("\n".join(quote), rewrite)
            out.append(f'<aside class="callout {kind}">{inner}</aside>')
            i = j
        elif ln.startswith("|") and i + 1 < len(lines) and re.match(r"\s*\|?[\s:|-]+\|?\s*$", lines[i + 1]):
            head = split_row(ln)
            j = i + 2
            rows = []
            while j < len(lines) and lines[j].startswith("|"):
                rows.append(split_row(lines[j]))
                j += 1
            th = "".join(f"<th>{inline(c, rewrite)}</th>" for c in head)
            tr = "".join("<tr>" + "".join(f"<td>{inline(c, rewrite)}</td>" for c in r) + "</tr>" for r in rows)
            out.append(f'<div class="table-wrap"><table><thead><tr>{th}</tr></thead><tbody>{tr}</tbody></table></div>')
            i = j
        elif re.match(r"\s*(?:[-*]|\d+\.)\s", ln):
            block, i = blocks_list(i)
            out.append(block)
        elif re.match(r"-{3,}\s*$", ln):
            out.append("<hr>")
            i += 1
        else:
            # A primeira linha é sempre do parágrafo: um "|" que não abre tabela chega aqui.
            j = i + 1
            para = [ln]
            while j < len(lines) and lines[j].strip() and not re.match(r"(?:```|#{1,6}\s|>|\|)", lines[j]) and not re.match(r"\s*(?:[-*]|\d+\.)\s", lines[j]):
                para.append(lines[j])
                j += 1
            out.append(f"<p>{inline(' '.join(para), rewrite)}</p>")
            i = j
    return "\n".join(out), heads


# ------------------------------------------------------------- Mascote ----
# O desenho de assets/logo-mark.svg, em peças que o site anima (site.css e site.js).
BODY = "M340 258 L568 188 L625 268 Q700 262 778 268 L838 182 Q960 200 1048 248 C1180 420 1260 620 1262 812 C1180 880 1080 920 985 945 L930 830 Q700 850 482 802 L428 938 C320 910 220 870 148 830 C150 620 220 420 340 258 Z"
EYE_L = "M338 600 L660 548 C640 640 590 702 482 705 C400 705 346 662 338 600 Z"
EYE_R = "M698 540 L1068 455 C1086 540 1048 612 950 614 C842 614 736 600 698 540 Z"
MOUTH = "M728 742 C830 722 922 700 980 652 C988 668 980 680 962 690 C900 722 822 742 732 750 Z"
SPARK = "M1095 160 C1105 250 1120 282 1240 296 C1130 310 1112 340 1110 436 C1100 340 1080 322 940 322 C1060 306 1088 272 1095 160 Z"


def shrink(path, cx, cy, k, nx, ny):
    """A forma do olho é a da lente, menor: a pálpebra reta dá a cara de deboche."""
    xy = 0

    def repl(m):
        nonlocal xy
        v = float(m.group(0))
        xy += 1
        return f"{(nx + (v - cx) * k) if xy % 2 else (ny + (v - cy) * k):.1f}"

    return re.sub(r"-?\d+(?:\.\d+)?", repl, path)


EYE_LS = shrink(EYE_L, 499, 626, 0.6, 496, 628)
EYE_RS = shrink(EYE_R, 885, 535, 0.6, 884, 536)


def mascot(uid):
    return f'''<svg class="ma" viewBox="100 110 1200 900" aria-hidden="true" focusable="false"><defs><clipPath id="ma-b{uid}"><path d="{BODY}"/></clipPath><clipPath id="ma-l{uid}"><path d="{EYE_L}"/><path d="{EYE_R}"/></clipPath><clipPath id="ma-e{uid}"><path d="{EYE_LS}"/><path d="{EYE_RS}"/></clipPath><linearGradient id="ma-lens{uid}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2b0a44"/><stop offset=".55" stop-color="#0c0316"/><stop offset="1" stop-color="#040108"/></linearGradient></defs><g class="ma-rig"><path class="ma-ghost ma-g1" d="{BODY}"/><path class="ma-ghost ma-g2" d="{BODY}"/><g clip-path="url(#ma-b{uid})"><path class="ma-edge" d="{BODY}"/><path class="ma-core" d="{BODY}" transform="translate(12.5 45) scale(0.95)"/><path class="ma-shade" d="M150 690 C230 810 330 870 470 900 L440 980 L100 980 L100 690 Z"/></g><path class="ma-line" d="{BODY}"/><g class="ma-eyes"><path class="ma-white" d="{EYE_LS}"/><path class="ma-white" d="{EYE_RS}"/><g clip-path="url(#ma-e{uid})"><ellipse class="ma-iris" cx="520" cy="634" rx="30" ry="36"/><ellipse class="ma-iris" cx="908" cy="538" rx="30" ry="36"/></g><path class="ma-lid" d="{EYE_LS}"/><path class="ma-lid" d="{EYE_RS}"/></g><path class="ma-mouth ma-ink" d="{MOUTH}"/><g class="ma-shades"><path class="ma-arm" d="M345 596 L196 566"/><path class="ma-arm" d="M1066 458 L1196 424"/><path class="ma-arm" d="M655 554 Q680 528 702 544"/><path class="ma-lens" fill="url(#ma-lens{uid})" d="{EYE_L}"/><path class="ma-lens" fill="url(#ma-lens{uid})" d="{EYE_R}"/><g clip-path="url(#ma-l{uid})"><path class="ma-tint" d="M300 640 L1100 450 L1100 520 L300 700 Z"/><path class="ma-glare" d="M250 760 L350 760 L620 420 L520 420 Z M400 760 L440 760 L710 420 L670 420 Z"/></g></g><path class="ma-spark" d="{SPARK}"/></g></svg>'''


def live_icon():
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><style>@keyframes t{{0%,80%,100%{{transform:scale(1) rotate(0)}}90%{{transform:scale(1.35) rotate(90deg)}}}}@keyframes g{{0%,70%{{transform:translateX(-420px)}}90%,100%{{transform:translateX(900px)}}}}#s{{transform-box:fill-box;transform-origin:center;animation:t 3.4s infinite}}#g{{animation:g 3.6s infinite}}</style><defs><clipPath id="c"><path d="{EYE_L}"/><path d="{EYE_R}"/></clipPath></defs><rect width="512" height="512" rx="116" fill="#0a050f"/><g transform="translate(28 85) scale(0.38) translate(-100 -110)"><path d="{BODY}" fill="#F03CFF"/><path d="{BODY}" fill="#7A0BD0" transform="translate(12.5 45) scale(0.95)"/><path d="{BODY}" fill="none" stroke="#12061F" stroke-width="26" stroke-linejoin="round"/><path d="M345 596 L196 566M1066 458 L1196 424M655 554 Q680 528 702 544" fill="none" stroke="#12061F" stroke-width="26"/><path d="{EYE_L}" fill="#12061F"/><path d="{EYE_R}" fill="#12061F"/><g clip-path="url(#c)"><path id="g" d="M300 760 L420 760 L690 420 L570 420 Z" fill="#fff" opacity=".55"/></g><path d="{MOUTH}" fill="#12061F"/><path id="s" d="{SPARK}" fill="#FF3CF0" stroke="#12061F" stroke-width="18"/></g></svg>'''


# ------------------------------------------------------------ Layouts ----
# Os retângulos de cada tema numa janela de 1280x800, como src/theme/layout.zig
# calcula: é o que a interface 3D do topo da página mostra.
CONTAINERS = ("row", "column", "stack")


def layout_nodes(src, top, on, pal, raw):
    styles = {}
    if "styles" in top:
        for st in top["styles"].children:
            styles[st.args[0]] = st.props
    radius_default = top["metrics"].props.get("radius", 6) if "metrics" in top else 6

    def color(expr, mode):
        if expr is None:
            return None
        toks = raw[mode]
        try:
            return css(toks[expr]) if expr in toks else css(color_eval(expr, pal, toks))
        except (KeyError, ValueError, IndexError):
            return None

    def visible(n):
        p = n.props
        if p.get("show") is False:
            return False
        if "when" in p and p["when"] not in on:
            return False
        if "unless" in p and p["unless"] in on:
            return False
        if "hide-below" in p and 1280 < p["hide-below"]:
            return False
        return True

    out = []

    def walk(n, x, y, w, h):
        p = n.props
        style = styles.get(p.get("style"), {}) if p.get("style") else {}
        fill = style.get("bg", p.get("bg"))
        c = [color(fill, "dark"), color(fill, "light")] if fill else None
        if "max-width" in p and w > p["max-width"]:
            x += (w - p["max-width"]) / 2
            w = p["max-width"]
        r = p.get("radius", style.get("radius", 0 if n.name in CONTAINERS else radius_default if fill else 0))
        r = r if isinstance(r, (int, float)) else 0
        line = " ".join(src[n.start:n.end].split("{")[0].split())
        if n.name in CONTAINERS:
            if c and c[0]:
                out.append({"k": "box", "x": x, "y": y, "w": w, "h": h, "c": c, "r": r, "n": line[:44]})
            pad = p.get("padding", 0)
            px, py = p.get("padding-x", pad), p.get("padding-y", pad)
            x, y, w, h = x + px, y + py, w - 2 * px, h - 2 * py
            kids = [k for k in n.children if visible(k)]
            if n.name == "stack":
                for k in kids:
                    walk(k, x, y, w, h)
                return
            horiz = n.name == "row"
            main, size = ("width", w) if horiz else ("height", h)
            gap = p.get("gap", 0)
            free = size - gap * max(len(kids) - 1, 0)
            weights = 0
            for k in kids:
                if main in k.props:
                    free -= k.props[main]
                else:
                    weights += k.props.get("flex", 1)
            at = x if horiz else y
            for k in kids:
                length = k.props[main] if main in k.props else max(free, 0) * k.props.get("flex", 1) / (weights or 1)
                if horiz:
                    walk(k, at, y, length, h)
                else:
                    walk(k, x, at, w, length)
                at += length + gap
            return
        if n.name in ("spacer", "crt"):
            return
        ix, iy = p.get("inset-x", 0), p.get("inset-y", 0)
        node = {"k": n.name, "x": round(x + ix, 1), "y": round(y + iy, 1), "w": round(w - 2 * ix, 1), "h": round(h - 2 * iy, 1), "r": r, "n": line[:44]}
        if c and c[0]:
            node["c"] = c
        for key, short in (("variant", "v"), ("shape", "s")):
            if key in p:
                node[short] = p[key]
        if n.name == "label":
            node["t"] = p.get("text", "")
            node["fs"] = p.get("size", 12)
        out.append(node)

    root = top["layout"].children[0]
    walk(root, 0, 0, 1280, 800)
    for o in out:
        for key in ("x", "y", "w", "h"):
            o[key] = round(o[key], 1)
    return out


# ------------------------------------------------------------- Páginas ----
GUIDE = [
    ("Start", "Comece", [
        ("getting-started", "Getting started", "Primeiros passos"),
        ("account", "Connect your account", "Conectar sua conta"),
    ]),
    ("Use", "Use", [
        ("features", "Feature tour", "Tour dos recursos"),
        ("shortcuts", "Shortcuts and CLI", "Atalhos e linha de comando"),
        ("settings", "Settings and files", "Configurações e arquivos"),
        ("voice", "Voice calls", "Chamadas de voz"),
    ]),
    ("Customize", "Personalize", [
        ("themes", "Writing themes", "Escrevendo temas"),
        ("theme-gallery", "Built-in themes", "Temas embutidos"),
        ("plugins", "Lua plugins", "Plugins em Lua"),
        ("lsp", "Code diagnostics", "Erros no código"),
    ]),
    ("Internals", "Por dentro", [
        ("architecture", "Architecture", "Arquitetura"),
        ("performance", "Performance", "Desempenho"),
        ("privacy", "Privacy and security", "Privacidade e segurança"),
    ]),
    ("Project", "Projeto", [
        ("status", "Status and roadmap", "Estado e roteiro"),
        ("contributing", "Contributing", "Contribuir"),
    ]),
]
FLAT = [p for _, _, ps in GUIDE for p in ps]


def t(lang, en, pt):
    return en if lang == "en" else pt


def page_url(lang, slug=None):
    """Caminho a partir da raiz do site."""
    prefix = "" if lang == "en" else "pt/"
    return f"{prefix}guide/{slug}.html" if slug else (prefix or "./")


def root_of(path):
    return "../" * path.count("/")


def rel(path_from, target):
    return root_of(path_from) + target


def shell(lang, path, alt_path, title, desc, body, kind):
    root = root_of(path)
    other = "pt" if lang == "en" else "en"
    other_label = "Português" if lang == "en" else "English"
    home = rel(path, page_url(lang) if lang == "pt" else "") or "./"
    guide = rel(path, page_url(lang, "getting-started"))
    anchor_home = home if kind != "landing" else ""
    return f'''<!doctype html>
<html lang="{'en' if lang == 'en' else 'pt-BR'}" data-lang="{lang}" data-root="{root}" data-page="{kind}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<meta name="description" content="{html.escape(desc, quote=True)}">
<meta name="color-scheme" content="dark light">
<link rel="canonical" href="{BASE_URL}{path.removesuffix('index.html')}">
<link rel="alternate" hreflang="en" href="{BASE_URL}{(path if lang == 'en' else alt_path).removesuffix('index.html')}">
<link rel="alternate" hreflang="pt-BR" href="{BASE_URL}{(alt_path if lang == 'en' else path).removesuffix('index.html')}">
<meta property="og:type" content="website">
<meta property="og:title" content="{html.escape(title, quote=True)}">
<meta property="og:description" content="{html.escape(desc, quote=True)}">
<meta property="og:image" content="{BASE_URL}assets/og.png">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" type="image/svg+xml" href="{root}assets/icon-live.svg">
<link rel="icon" type="image/png" sizes="32x32" href="{root}assets/icon-32.png">
<link rel="apple-touch-icon" href="{root}assets/icon-180.png">
<link rel="preload" href="{root}assets/fonts/departure-mono.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="{root}assets/fonts/jetbrains-mono-400.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="{root}assets/site/site.css">
<script src="{root}assets/site/data.js"></script>
<script src="{root}assets/site/boot.js"></script>
</head>
<body>
<a class="skip" href="#main">{t(lang, 'Skip to content', 'Pular para o conteúdo')}</a>
<header class="topnav">
  <a class="brand" href="{home}" aria-label="SigmaCord">{mascot("n")}<span data-brand>SigmaCord</span></a>
  <nav aria-label="{t(lang, 'Main', 'Principal')}">
    <a href="{anchor_home}#themes">{t(lang, 'Themes', 'Temas')}</a>
    <a href="{anchor_home}#playground">Playground</a>
    <a href="{anchor_home}#features">{t(lang, 'Features', 'Recursos')}</a>
    <a href="{guide}"{' aria-current="page"' if kind == 'guide' else ''}>{t(lang, 'Guide', 'Guia')}</a>
    <a href="{REPO}" rel="noopener">★ {t(lang, 'Star on GitHub', 'Dar estrela no GitHub')}</a>
  </nav>
  <a class="kofi-mini" href="https://ko-fi.com/M7E72A1EGZ" target="_blank" rel="noopener"><img src="{root}assets/kofi6.png" alt="{t(lang, 'Buy Me a Coffee at ko-fi.com', 'Me pague um café no ko-fi.com')}" width="580" height="146"></a>
  <a class="lang" href="{rel(path, alt_path.removesuffix('index.html')) or './'}" hreflang="{'pt-BR' if other == 'pt' else 'en'}" lang="{'pt-BR' if other == 'pt' else 'en'}">{other_label}</a>
</header>
{body}
<footer class="statusbar" aria-label="{t(lang, 'Page theme', 'Tema da página')}">
  <button type="button" class="buddy" data-next-theme aria-label="{t(lang, 'Next theme', 'Próximo tema')}">{mascot("b")}</button>
  <i class="sb-prog" aria-hidden="true"></i>
  <span class="sb-dot" aria-hidden="true"></span>
  <button type="button" class="sb-btn" data-next-theme title="F2"><span data-theme-name>sigma</span></button>
  <button type="button" class="sb-btn" data-toggle-mode><span data-mode-name>dark</span></button>
  <span class="sb-spacer"></span>
  <button type="button" class="sb-btn sb-keys" data-open-palette><kbd>Ctrl</kbd><kbd>K</kbd> {t(lang, 'palette', 'paleta')}</button>
  <span class="sb-keys sb-hint"><kbd>F2</kbd> {t(lang, 'next theme', 'próximo tema')}</span>
  <a class="sb-btn sb-kofi" href="https://ko-fi.com/M7E72A1EGZ" target="_blank" rel="noopener">&#9829; ko-fi</a>
  <span class="sb-pos" data-scroll-pos></span>
  <time class="sb-clock" data-clock></time>
</footer>
<div class="fx-layer" aria-hidden="true"></div>
<script src="{root}assets/site/site.js"></script>
</body>
</html>
'''


def external_sources(slug, lang):
    """Guias que moram fora de site/: o .md de lá é a fonte."""
    if slug == "plugins":
        return ROOT / "docs" / ("plugins.md" if lang == "en" else "plugins.pt-BR.md")
    if slug == "lsp":
        return ROOT / "docs" / ("lsp.md" if lang == "en" else "lsp.pt-BR.md")
    if slug == "themes":
        return ROOT / "themes" / ("README.md" if lang == "en" else "README.pt-BR.md")
    return None


def rewriter(lang, slug, path):
    def rewrite(url):
        if re.match(r"(?:https?:|mailto:|#)", url):
            return url
        target, _, frag = url.partition("#")
        frag = f"#{frag}" if frag else ""
        name = Path(target).name
        if name.startswith("guide:"):
            return rel(path, page_url(lang, name[6:])) + frag
        if slug == "themes" and name.endswith(".kdl"):
            return f"{REPO}/blob/main/themes/{name}"
        if slug == "plugins" and target.rstrip("/").startswith("plugins"):
            return f"{REPO}/tree/main/docs/{target}"
        return f"{REPO}/blob/main/{target}"
    return rewrite


def gallery_md(lang, themes):
    out = [t(lang, "# Built-in themes", "# Temas embutidos"), "",
           t(lang, "Generated from `themes/*.kdl`. Every theme has a light and a dark mode, and the options below show up in Settings → Appearance.",
             "Gerado a partir de `themes/*.kdl`. Todo tema tem modo claro e escuro, e as opções abaixo aparecem em Configurações → Aparência."), ""]
    for name in THEMES:
        th = themes[name]
        out += [f"## {name}", "", th["descEn"] if lang == "en" else th["desc"], ""]
        out.append(f"![{name}](shot:{name})")
        out.append("")
        if th["options"]:
            out += [t(lang, "| Option | Default | What it does |", "| Opção | Padrão | O que faz |"), "|---|---|---|"]
            for o in th["options"]:
                label = o["labelEn"] if lang == "en" else o["label"]
                desc = o["descEn"] if lang == "en" else o["desc"]
                state = t(lang, "on" if o["default"] else "off", "ligada" if o["default"] else "desligada")
                out.append(f"| {label} (`{o['name']}`) | {state} | {desc} |")
            out.append("")
        out += [t(lang, f"Source: [`{name}.kdl`]({REPO}/blob/main/themes/{name}.kdl)", f"Fonte: [`{name}.kdl`]({REPO}/blob/main/themes/{name}.kdl)"), ""]
    return "\n".join(out)


def build_guide(lang, themes):
    index = []
    for gi, (slug, ten, tpt) in enumerate(FLAT):
        path = page_url(lang, slug)
        alt = page_url("pt" if lang == "en" else "en", slug)
        title = ten if lang == "en" else tpt
        if slug == "theme-gallery":
            src = gallery_md(lang, themes)
        else:
            f = external_sources(slug, lang) or SITE / "guide" / lang / f"{slug}.md"
            if not f.exists():
                f = external_sources(slug, "en") or SITE / "guide" / "en" / f"{slug}.md"
            src = f.read_text(encoding="utf-8")
        # A linha de idioma dos .md não faz sentido aqui: o site tem a dele.
        src = re.sub(r"^(?:\*\*English\*\*|\[English\]\(.*?\)) · .*$", "", src, flags=re.M)
        base_rw = rewriter(lang, slug, path)

        def rw(url, base_rw=base_rw, path=path):
            if url.startswith("#"):
                # Os .md de fora têm âncoras no estilo do GitHub, com acento.
                return "#" + slugify(url[1:])
            if url.startswith("shot:"):
                return rel(path, f"assets/shots/{lang}/{url[5:]}.webp")
            if url.startswith("home:"):
                return rel(path, "pt/index.html" if lang == "pt" else "index.html") + "#" + url[5:]
            if url.startswith("page:"):
                name, _, frag = url[5:].partition("#")
                return rel(path, page_url(lang, name)) + (f"#{frag}" if frag else "")
            return base_rw(url)

        lead = ""
        m = re.search(r"^#\s+.*$", src, re.M)
        body_md = src[m.end():] if m else src
        content, heads = markdown(body_md, rw)
        side = []
        for gten, gpt, pages in GUIDE:
            links = "".join(
                f'<a href="{rel(path, page_url(lang, s))}"{" aria-current=page" if s == slug else ""}>{te if lang == "en" else tp}</a>'
                for s, te, tp in pages)
            side.append(f'<div class="side-group"><p>{gten if lang == "en" else gpt}</p>{links}</div>')
        toc = "".join(f'<a class="l{lv}" href="#{hid}">{inline(text, lambda u: u)}</a>' for lv, text, hid in heads if lv in (2, 3))
        prev_ = FLAT[gi - 1] if gi else None
        next_ = FLAT[gi + 1] if gi + 1 < len(FLAT) else None
        pager = '<nav class="pager">'
        if prev_:
            pager += f'<a href="{rel(path, page_url(lang, prev_[0]))}"><small>{t(lang, "Previous", "Anterior")}</small>{prev_[1] if lang == "en" else prev_[2]}</a>'
        else:
            pager += "<span></span>"
        if next_:
            pager += f'<a class="next" href="{rel(path, page_url(lang, next_[0]))}"><small>{t(lang, "Next", "Próximo")}</small>{next_[1] if lang == "en" else next_[2]}</a>'
        pager += "</nav>"
        edit = f"{REPO}/blob/main/" + str((external_sources(slug, lang) or SITE / "guide" / lang / f"{slug}.md").relative_to(ROOT)) if slug != "theme-gallery" else f"{REPO}/tree/main/themes"
        body = f'''<div class="guide">
<aside class="side" aria-label="{t(lang, 'Guide pages', 'Páginas do guia')}">
<button type="button" class="side-search" data-open-palette>{t(lang, 'Search the guide', 'Buscar no guia')}<span><kbd>Ctrl</kbd><kbd>K</kbd></span></button>
{''.join(side)}
</aside>
<main id="main" class="prose">
<h1>{html.escape(title)}</h1>
{content}
<p class="edit"><a href="{edit}" rel="noopener">{t(lang, 'Source of this page on GitHub', 'Fonte desta página no GitHub')}</a></p>
{pager}
</main>
<nav class="toc" aria-label="{t(lang, 'On this page', 'Nesta página')}"><p>{t(lang, 'On this page', 'Nesta página')}</p>{toc}</nav>
</div>'''
        plain = re.sub(r"<[^>]+>", " ", content)
        desc = " ".join(plain.split())[:155]
        full = f"{title} · SigmaCord"
        write(path, shell(lang, path, alt, full, desc, body, "guide"))
        index.append({"t": title, "s": t(lang, "Guide", "Guia"), "u": path})
        # Cada seção entra na busca com um trecho do que vem depois do título.
        for lv, text, hid in heads:
            if lv > 3:
                continue
            at = content.find(f'id="{hid}"')
            snippet = " ".join(re.sub(r"<[^>]+>", " ", content[at:at + 900]).split())
            snippet = snippet[len(text) + 12:220] if at >= 0 else ""
            index.append({"t": re.sub(r"[*]", "", text), "s": title, "u": f"{path}#{hid}", "x": snippet})
    return index


def write(path, text):
    f = OUT / path
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(text, encoding="utf-8")


def build_landing(lang, themes):
    src = (SITE / "landing.html").read_text(encoding="utf-8")
    src = re.sub(r"\{\{(.*?)\|\|(.*?)\}\}", lambda m: m.group(1 if lang == "en" else 2), src, flags=re.S)
    path = "index.html" if lang == "en" else "pt/index.html"
    alt = "pt/index.html" if lang == "en" else "index.html"
    root = root_of(path)
    src = src.replace("%ROOT%", root).replace("%LANG%", lang).replace("%REPO%", REPO).replace("%VERSION%", VERSION).replace("%GUIDE%", rel(path, page_url(lang, "x")).removesuffix("x.html"))

    def code(m):
        return code_block(html.unescape(m.group(2)).strip("\n"), m.group(1))

    src = re.sub(r'<code-block lang="(\w+)">(.*?)</code-block>', code, src, flags=re.S)
    cards = []
    for i, name in enumerate(THEMES):
        th = themes[name]
        cards.append(f'''<figure class="tcard" data-card="{name}">
  <button type="button" class="tcard-shots" data-apply="{name}" aria-label="{t(lang, f'Dress this page in {name}', f'Vestir esta página de {name}')}">
    <img class="dark" src="{root}assets/shots/{lang}/{name}.webp" alt="{t(lang, f'{name} theme, dark mode', f'Tema {name}, modo escuro')}" loading="lazy" width="1280" height="800">
    <img class="light" src="{root}assets/shots/{lang}/{name}-claro.webp" alt="" loading="lazy" width="1280" height="800">
    <span class="tcard-split" aria-hidden="true"></span>
  </button>
  <figcaption><span class="tnum">{i + 1:02d}</span><strong>{name}</strong><span class="tdesc">{html.escape(th['descEn'] if lang == 'en' else th['desc'])}</span></figcaption>
</figure>''')
    src = src.replace("%THEME_CARDS%", "\n".join(cards)).replace("%MASCOT%", mascot("h"))
    tabs = [f'<button type="button" role="tab" data-apply="sigma" class="tab"><i>0</i>sigma</button>']
    tabs += [f'<button type="button" role="tab" data-apply="{n}" class="tab"><i>{i + 1}</i>{n}</button>' for i, n in enumerate(THEMES)]
    src = src.replace("%THEME_TABS%", "".join(tabs))
    presets = "".join(f'<option value="{n}"{" selected" if n == "subsolo" else ""}>{n}.kdl</option>' for n in THEMES)
    src = src.replace("%PRESET_OPTIONS%", presets)
    title = t(lang, "SigmaCord: a native Discord client whose whole UI is one file", "SigmaCord: um cliente nativo de Discord cuja interface inteira é um arquivo")
    desc = t(lang, "Unofficial native Discord client in Zig. About 130 MB of RAM with a real account, 0% CPU at idle, and a whole interface described by hot-reloading KDL theme files. Voice calls, Lua plugins, offline search.",
             "Cliente nativo e não oficial de Discord em Zig. Cerca de 130 MB de RAM com uma conta real, 0% de CPU parado e a interface inteira descrita em temas KDL que recarregam ao salvar. Voz, plugins em Lua, busca offline.")
    src = src.replace('loading="lazy"', 'loading="lazy" decoding="async"')
    write(path, shell(lang, path, alt, title, desc, src, "landing"))
    return [
        {"t": t(lang, "Home", "Início"), "s": "SigmaCord", "u": page_url(lang) if lang == "pt" else "index.html"},
        *[{"t": label, "s": t(lang, "Home", "Início"), "u": f"{'' if lang == 'en' else 'pt/'}index.html#{a}"} for label, a in [
            (t(lang, "Numbers", "Números"), "numbers"), (t(lang, "Layout playground", "Playground de layout"), "playground"),
            (t(lang, "Themes", "Temas"), "themes"), (t(lang, "Features", "Recursos"), "features"),
            (t(lang, "Voice", "Voz"), "voice"), (t(lang, "Plugins", "Plugins"), "plugins"),
            (t(lang, "How it stays light", "Como fica leve"), "light"), (t(lang, "What works today", "O que funciona hoje"), "status"),
            (t(lang, "Install", "Instalar"), "install")]],
    ]


def main():
    themes = load_themes()
    data = {"order": THEMES, "themes": {**{k: {x: v[x] for x in v if x not in ("preset", "options", "desc", "descEn", "nodes")} for k, v in themes.items()},
                                        "sigma": {k: BRAND[k] for k in ("radius", "display", "fx", "dark", "light")}}}
    write("assets/site/data.js", "window.LC_DATA=" + json.dumps(data, ensure_ascii=False, separators=(",", ":")) + ";\n")
    write("assets/site/layouts.js", "window.LC_LAYOUTS=" + json.dumps({k: {"nodes": v["nodes"], "en": v["descEn"], "pt": v["desc"]} for k, v in themes.items()}, ensure_ascii=False, separators=(",", ":")) + ";\n")
    write("assets/site/presets.js", "window.LC_PRESETS=" + json.dumps({k: v["preset"] for k, v in themes.items()}, ensure_ascii=False) + ";\n")
    for lang in LANGS:
        index = build_landing(lang, themes)
        index += build_guide(lang, themes)
        write(f"assets/site/search-{lang}.js", "window.LC_SEARCH=" + json.dumps(index, ensure_ascii=False, separators=(",", ":")) + ";\n")
    urls = ["", "pt/"] + [page_url(la, s) for la in LANGS for s, _, _ in FLAT]
    write("sitemap.xml", '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
          + "".join(f"  <url><loc>{BASE_URL}{u}</loc></url>\n" for u in urls) + "</urlset>\n")
    write("robots.txt", f"User-agent: *\nAllow: /\nSitemap: {BASE_URL}sitemap.xml\n")
    write(".nojekyll", "")
    write("assets/icon-live.svg", live_icon())
    # O 404 é servido em qualquer profundidade: os caminhos são absolutos a partir do projeto.
    body = (f'<main id="main" class="lost"><img src="/SigmaCord/assets/logo.svg" alt="" width="320">'
            f'<h1>404</h1><p class="aside">nothing here. <span lang="pt-BR">nada aqui.</span></p>'
            f'<p><a class="btn primary" href="/SigmaCord/">Home</a> <a class="btn" href="/SigmaCord/pt/">Início</a></p></main>')
    page = shell("en", "index.html", "pt/index.html", "404 · SigmaCord", "Page not found.", body, "lost")
    page = page.replace('data-root=""', 'data-root="/SigmaCord/"')
    page = re.sub(r'(href|src)="(?!https?:|/|#)(?:\./)?([^"]*)"', r'\1="/SigmaCord/\2"', page)
    write("404.html", page)
    print(f"site gerado em {OUT} ({len(urls)} páginas no sitemap)")


if __name__ == "__main__":
    main()
