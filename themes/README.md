# Writing themes

**English** · [Português](README.pt-BR.md)

A SigmaCord theme is a [KDL](https://kdl.dev) file that describes **the whole interface**:
colors, fonts, styles and the layout tree. You can change the position of everything without writing
a line of code.

Put the file in `~/.config/sigmacord/themes/meu-tema.kdl` (or in `themes/`, when running
from inside the repository). **When you save, the app reloads right away.** If there's an error, a
notice shows `file:line:column` and the previous theme stays in effect.

Switch themes with `F2`, from the palette (`Ctrl+K` → "theme: …") or in Settings → Appearance.

## Minimal example

```kdl
theme "meu-tema" description="Servidores embaixo, chat em cima." preview=classic
palette "wal"                      // uses pywal colors (optional)

colors {
    accent "wal:4"
    surface "mix(wal:0, black, 0.2)"
}

layout {
    column {
        row flex=1 {
            channel-list width=240 bg=sidebar
            column flex=1 {
                messages flex=1
                composer height=46 inset-x=16 inset-y=4
            }
        }
        guild-bar height=60 orientation=horizontal
    }
}
```

## Top-level nodes

| Node | What it does |
|---|---|
| `theme "name" description=… author=… preview=…` | metadata. `preview` picks the thumbnail in settings: `classic`, `glass`, `terminal`, `bubbles`, `zen`, `mirror`, `office`, `desktop` |
| `palette "wal"` or `palette "#hex" …` | the 16 base colors (`wal:0` … `wal:15`). Without it, a default palette is used |
| `colors { token "expression" … }` | overrides color tokens (list below) |
| `roles "color" …` | up to 8 role colors (usernames, server icons) |
| `fonts ui="Inter" mono="JetBrains Mono" size=16` | families (resolved by fontconfig) and base size |
| `metrics radius=6` | default rounding of rows and buttons |
| `window transparent=#true` | transparent window background: the compositor applies blur |
| `styles { style "name" … }` | named styles to use with `style=name` |
| `layout { … }` | the interface tree (a single child at the root) |

## Colors

Expressions accepted anywhere a color is asked for:

```
"#df68ad"   "#df68ad80"   "#fff"   "#fff8"
"wal:4"                    palette color
"@surface"                 another token (already defined)
"mix(a, b, 0.3)"           blend
"alpha(a, 0.5)"            transparency
"lighten(a, 0.1)"  "darken(a, 0.2)"
white  black  transparent
```

Tokens: `bg` `rail` `sidebar` `surface` `elevated` `overlay` `text` `muted` `faint` `accent`
`accent-text` `border` `hover` `selected` `online` `idle` `dnd` `danger` `mention` `link`
`code-bg` `bubble-self` `bubble-self-text` `bubble-other` `shadow`.

## Styles

```kdl
styles {
    style "card" bg="@surface" radius=18 border="@border" border-width=1.5 glow="@accent" shadow=16
}
```

`glow` is the border color when the mouse is over it. `shadow` is the shadow size.
For a plain background with no named style, use it directly on the node: `bg=sidebar radius=12`
(`bg` on the node also accepts an expression: `bg="alpha(@accent, 0.4)"`).

In addition, styles **and layout nodes** can have the primitives from the section
[Beyond the flat rectangle](#beyond-the-flat-rectangle): gradient, pattern, grain, vignette, inner
shadow, per-side border.

## Layout

Containers: `row` (horizontal), `column` (vertical), `stack` (one on top of another).

| Property | Effect |
|---|---|
| `width=` / `height=` | fixed size along the parent's axis |
| `flex=` | weight in the leftover space (default 1) |
| `gap=` `padding=` `padding-x=` `padding-y=` | spacing (containers) |
| `inset-x=` `inset-y=` | inner margin of a component |
| `max-width=` | limits the width and centers |
| `hide-below=` | hides when the window is narrower than this |
| `show=#false` | hides |
| `style=` / `bg=` `radius=` | the node's background |
| `font=mono` / `font=ui` / `font="Liberation Serif"` | the component's font: the mono one, the interface one or **any installed family** |
| `c-<token>=color` | overrides a color token **on this node and its children** (e.g. `c-text="#fff"` on a dark sidebar) |

The child of a `row` that has a fixed `width=` and holds `channel-list` or `member-list` is resizable: the app draws a drag handle on the side facing the row's `flex` sibling, and the width people choose is added to the one you set. Without a `flex` sibling there's no handle.

## Components

| Component | Properties |
|---|---|
| `guild-bar` | `variant=bar\|dock\|list` `icon-style=fill\|soft\|outline` `orientation=vertical\|horizontal` `shape=circle\|squircle\|square\|text` `size=48` `labels=#true` `home=#false` `indicators=#false` |
| `channel-list` | `variant=discord\|tree\|pills` `header=#false` |
| `user-panel` | `variant=discord\|tty` |
| `header` | `variant=discord\|minimal\|tty` `divider=#false` |
| `tabs` | `variant=pills\|underline\|tty` |
| `messages` | `variant=cozy\|irc\|bubbles` `avatar=circle\|squircle\|square\|none` `avatar-size=40` `spacing=16` `font-size=` |
| `composer` | `variant=box\|pill\|prompt` `typing=#false` |
| `member-list` | `variant=discord\|tty` |
| `status-bar` | `variant=pills\|tty\|plain` `items="conn ping ram frame voice spacer theme keys clock"` |
| `label` | `text=` `size=` `weight=regular\|medium\|semibold\|bold` `color=token` `align=left\|center\|right`, plus [display typography](#display-typography-in-label) |
| `shape` | circle, ring, arc, rounded rectangle, line ([details](#shape-and-rule)) |
| `rule` | plain, dashed, double, newspaper or ornamented rule ([details](#shape-and-rule)) |
| `starfield` `orbit` `aurora` `dunes` `topography` `radar` | [procedural backgrounds](#procedural-backgrounds) (first child of a `stack`) |
| `window-controls` | the three window buttons, which really work: close, minimize, maximize. `size=12` `gap=8` `color=` `color2=` `color3=` `align=` |
| `logo` | `variant=ascii\|wordmark` `size=` |
| `topbar` | top bar (tabs, search, help) |
| `crt` | `spacing=3` `strength=0.08` |
| `spacer` | empty space |

A name that doesn't exist shows up with a red border and the file line, to make it easy to spot.

## Beyond the flat rectangle

Everything here is optional, works in a `style "…"` or directly on a layout node, and the colors are expressions
(`"alpha(@accent, 0.4)"`, or just the token name). They are evaluated with the current tokens, so they
follow light/dark mode, the chosen accent color and the `c-…` of that part of the layout.

```kdl
styles {
    style "painel" radius=10 \
        gradient="alpha(@elevated, 0.9) alpha(@surface, 0.75)" gradient-angle=90 \
        pattern=dots pattern-color="alpha(@text, 0.05)" pattern-size=16 pattern-width=1 \
        grain="alpha(@text, 0.04)" vignette="alpha(black, 0.3)" vignette-size=0.55 \
        inner-shadow="alpha(black, 0.2)" inner-shadow-size=14 \
        border-gradient="@accent transparent @border" border-gradient-angle=70 border-width=1 \
        border-bottom="@border" border-bottom-width=2 \
        hover-bg="alpha(@accent, 0.05)"
}
layout { column gradient="@bg @rail" grain="alpha(@text, 0.05)" { … } }
```

| Property | What it does |
|---|---|
| `gradient="a b"` or `"a b c"` | gradient of 2 or 3 colors (separated by spaces) |
| `gradient-angle=90` | degrees: `0` from left to right, `90` from top to bottom (default) |
| `pattern=dots\|lines\|grid\|diagonal` | repeating pattern; requires `pattern-color` |
| `pattern-size=16` `pattern-width=1` | distance between repeats and stroke thickness (or dot radius) |
| `grain=color` | grain: fine noise, tinted by this color |
| `vignette=color` `vignette-size=0.55` | darkens (or tints) the edges; `size` is where it starts, from 0 (center) to 1 (corners) |
| `inner-shadow=color` `inner-shadow-size=14` | inward shadow |
| `border-gradient="a b c"` `border-gradient-angle=` `border-width=` | gradient border |
| `border-top=color` `border-right=` `border-bottom=` `border-left=` | border on that side only |
| `border-top-width=2` (same for the other sides) | thickness of that side (default: `border-width`, or 1) |
| `hover-bg=color` | background drawn on top when the mouse is over it, with a transition |
| `drop-shadow=color` `drop-shadow-size=32` `drop-shadow-y=10` | soft, **hollow** shadow: it doesn't darken what's under a translucent panel (the old `shadow=` does) |
| `corners=left\|right\|top\|bottom` | which corners the fill rounds: a window of two side-by-side panels |
| `border=color` | full border, to use directly on a node (in styles, it already exists) |

Cost: a 2-color gradient is just vertices. Grain, pattern, vignette and 3-color gradients are tiny textures
generated **once** and repeated: one quad per frame, no noise recalculated. A theme that doesn't
use any of this doesn't go through this code.

Very strong grain gets in the way more in dark mode than in light mode. When the value needs to change with the mode,
use separate styles: `styles mode=light { style "pagina" grain="alpha(@text, 0.07)" }` and
`styles mode=dark { style "pagina" grain="alpha(@text, 0.025)" }`. A node can also appear in only one
mode: `when=modo-claro`, `when=modo-escuro`.

## Display typography in `label`

```kdl
// Real tracking: no "O R B I T A L" with spaces.
label text="ORBITAL" tracking=8 size=15 weight=bold font=mono

// Runs: different color, weight, size and font on the same line, on the same baseline.
label height=38 size=9 color=muted font=mono span-gap=9 {
    span "01" size=18 color=accent
    span "CANAIS" en="CHANNELS" tracking=3
}

// Effects.
label text="SigmaCord" size=40 shadow="alpha(black, 0.5)" shadow-x=2 shadow-y=2
label text="SigmaCord" size=40 shadow="alpha(@accent, 0.4)" shadow-blur=3   // glow
label text="SigmaCord" size=40 color=bg outline=accent outline-width=2
label text="SigmaCord" size=40 text-gradient="@text @accent" text-gradient-angle=0
```

| Property | What it does |
|---|---|
| `tracking=` | extra space between letters, in pixels (can be negative) |
| `color=` | also accepts an expression: `color="alpha(@text, 0.7)"` |
| `text-en=` (`en=` on `span`) | English version of the text |
| `span "text"` | a piece of the line; `size` `weight` `color` `font` `tracking` inherit from `label` |
| `span-gap=` | space between spans |
| `shadow=color` `shadow-x=` `shadow-y=` `shadow-blur=` | shadow; with `blur` it becomes a soft halo |
| `outline=color` `outline-width=` | outline |
| `text-gradient="a b"` `text-gradient-angle=` | gradient on the text (default: horizontal) |

A `label` with none of this stays the same, on the same path as always. Effects draw the text more
times: save them for titles and wordmarks.

## `shape` and `rule`

Shapes and rules that are actually drawn, instead of Unicode characters. Pile them up in a `stack` to compose.

```kdl
stack width=28 {
    shape kind=ring size=22 thickness=1 color="alpha(@accent, 0.35)"
    shape kind=arc size=22 thickness=1.6 start=-150 sweep=250 color=accent dot="@text" dot-size=2.4
    shape kind=circle size=6 color=accent
}
shape kind=rounded radius=6 color=accent fill="alpha(@accent, 0.1)" thickness=1
shape kind=line angle=30 thickness=2 color=border

rule height=1 color=border
rule height=1 kind=dashed dash=3 gap=3 color="alpha(@accent, 0.45)"
rule height=7 kind=oxford color=text                                 // thick line over thin line
rule height=11 kind=double color=text ornament=star ornament-color=accent ornament-size=11
rule height=20 ornament-text="§" ornament-size=16 font="Liberation Serif"
rule width=1 vertical=#true color=border
rule height=1 fade=#true color=accent                                // fades out at the ends
```

| `shape` | |
|---|---|
| `kind=` | `circle` `ring` `arc` `rounded` `line` |
| `color=` `thickness=` | stroke color and thickness |
| `size=` | diameter (default: the node's shorter side); on `line`, the length |
| `fill=` | fill of `ring` and `rounded` |
| `start=` `sweep=` | start and opening of the `arc`, in degrees |
| `dot=color` `dot-size=` | a dot at the tip of the `arc` |
| `radius=` | corners of `rounded` |
| `angle=` | tilt of the `line`, in degrees |
| `align=left\|center\|right` `offset-x=` `offset-y=` | position inside the node |

| `rule` | |
|---|---|
| `kind=` | `solid` `dashed` `dotted` `double` `oxford` |
| `color=` `thickness=` | color and thickness |
| `dash=` `gap=` | size of the dash and of the gap on `dashed` |
| `vertical=#true` | from top to bottom (give the node a `width=`) |
| `fade=#true` | fades out at both ends |
| `ornament=` | `diamond` `dot` `ring` `star`, in the middle of the rule |
| `ornament-text=` | a character in the middle, instead of the shape (uses the node's `font=`) |
| `ornament-color=` `ornament-size=` `ornament-gap=` | color, size and the gap in the rule around it |

## Procedural backgrounds

They go as the first child of a `stack`, behind everything else. They are **static by default**: generated
once, they stay in a texture, and a static theme doesn't wake the app.

```kdl
layout {
    stack {
        starfield color="alpha(@muted, 0.75)" color2="alpha(@accent, 0.8)" density=1.1
        orbit center-x=0.73 center-y=0.4 rings=7 color="alpha(@accent, 0.4)" color2=accent
        column { … panels … }
    }
}
```

| Component | Colors | Properties |
|---|---|---|
| `starfield` | `color` distant stars, `color2` the near ones | `density=1` |
| `orbit` | `color` the orbits, `color2` the moons | `center-x=0.7` `center-y=0.35` `rings=6` |
| `aurora` | `color` and `color2`, one for each curtain | |
| `dunes` | `color`, `color2`, `color3`: hills from back to front (the sky is the `gradient` of the surrounding node) | |
| `topography` | `color` | `levels=14` (how many contour lines) |
| `radar` | `color` rings, `color2` the sweep | `center-x=0.5` `center-y=0.5` `rings=5` |

All of them accept `seed=` (a different drawing), and all except `topography` accept motion:
`motion=#true`, or better `motion="$opcao"`, so the user can choose, and `motion-fps=10` (15 at most).
Motion only shifts the texture or redraws a small piece, and it stops on its own with "Reduce motion" and
with the window minimized or out of focus.

The mask is only shape: the color comes at draw time. Switching mode or accent color generates nothing
new. Only `orbit` and `radar` depend on size, and they are rebuilt once when the window stops changing.

**Contrast first.** Text never sits directly on a strong background: put a translucent panel in
between (`gradient="alpha(@surface, 0.9) alpha(@surface, 0.76)"`) and check both modes. Use colors
derived from tokens: `@muted` in dark mode is light stars, and in light mode it becomes ink on paper.

## Light and dark

Every theme has both versions. Blocks with `mode=` only apply in one of the modes:

```kdl
colors mode=dark  { bg "#0b0906"; text "#ffcf73" }
colors mode=light { bg "#f4efe2"; text "#2e2412" }
roles mode=light "#7a4a00" "#9c3f10"
```

Without `mode=`, the block applies in both. If the theme doesn't define the light one, it's derived
from the palette (near-white paper, dark ink and a darkened accent). In the layout, `cl-<token>` and `cd-<token>`
override a color in light only or in dark only. The user chooses in Settings → Appearance
(Dark / Light / Follow system), or on the command line: `--mode claro`.

## Theme options

A theme can offer on/off switches, which show up in Settings → Appearance:

```kdl
options {
    option "crt" label="Efeito CRT" description="Linhas de varredura…" default=#true
    option "verde" label="Fósforo verde" default=#false
}
```

Ways to use the options:

| Where | How |
|---|---|
| hide/show a node | `crt when=crt`, `tabs unless=compacto` |
| boolean property | `banner="$banner"`, `typing="$!digitando"` (the `!` inverts) |
| block of colors, roles, styles | `colors mode=dark when=verde { … }` |
| style | `style "card" sheen="$brilho"` |

The choices are saved per theme in `~/.config/sigmacord/settings.kdl`.

## Custom colors (without editing the `.kdl`)

In **Settings → Appearance → Theme colors** you can replace any color token
(`bg`, `sidebar`, `text`, `accent`, `link`, `bubble-self`…) and the eight role colors with a
free-form hex. It applies only to the **current theme and the current mode** (dark or light), and it takes priority
over the global “Accent color”.

- `#RRGGBB` for an opaque color; `#RRGGBBAA` for a color with transparency.
- Click an item in the grid, paste the hex and press Enter.
- “Clear this color” returns that item to the theme; “Reset theme” erases the theme's choices.
- The choices are kept in `settings.kdl` as `theme-colors "name" mode=dark accent="#…"`,
  so they don't change the theme file.
- Parts that use a fixed `c-…` in the layout (some themes do this to keep contrast) keep
  the file's color; to change those, edit the `.kdl`.

### In English

The interface comes in Portuguese and English. For your theme to look right in both, put the English
version alongside: `label-en=` and `description-en=` on options, and `description-en=` on the `theme` node.
Without them, the Portuguese text shows up.

```kdl
theme "meu-tema" description="Servidores embaixo." description-en="Servers at the bottom."
options {
    option "crt" label="Efeito CRT" label-en="CRT effect" description="Linhas de varredura" description-en="Scanlines"
}
```

## Exclusive features

| Component / property | What it does | Used in |
|---|---|---|
| `channel-list banner=#true` | colored banner with the server name | classico |
| `style … sheen=#true` | glass reflection at the top of the card | vidro |
| `crt` | scanlines + vignette, on top of everything (use it in a `stack`) | terminal, subsolo |
| `logo variant=ascii\|wordmark` | the app logo in ASCII or as text | terminal, subsolo, escritorio |
| `messages ruled=#true margin-line=#true` | ruled paper and red margin | papel |
| `messages ticks=#true typing-bubble=#true` | "Delivered ✓✓" and a typing bubble | bolhas |
| `autohide=#true` (any node) | the component disappears until the mouse gets close | zen |
| `guild-bar variant=bar orientation=horizontal` | horizontal strip of servers at the bottom, no icon zoom | orbital |
| `topbar` | back/forward between tabs, search and help | escritorio, editorial (optional in orbital) |
| `starfield` `orbit`, wordmark with `tracking`, translucent panels | console in the middle of the stars; in light mode, a star chart | orbital |
| `grain`, `rule kind=oxford`, `label` with `span` | grainy paper, masthead, newspaper rules | editorial |
| `aurora`, `border-gradient`, `grain` | light behind frosted glass | vidro |
| `pattern=grid`, `radar`, `topography` | oscilloscope graticule; optional radar and map | terminal |
| `dunes`, `window-controls`, `corners`, `drop-shadow`, `guild-bar variant=dock` | desktop with a floating window, translucent sidebar and Dock | cupertino |
| `topography`, `pattern=diagonal`, `shadow-x` | tunnel map, hazard tape, sign with chromatic aberration | subsolo |
| `shape kind=arc`, `topography`, `grain` | enso and raked sand | zen |
| `shape kind=ring`, `pattern=dots`, `rule kind=oxford`, `ornament-text` | binder holes, dotted page, index | papel |
| `aurora`, `pattern=dots`, `drop-shadow` | cards floating over a colored background | bolhas |

## The bundled themes

- [`classico.kdl`](classico.kdl): the familiar layout
- [`vidro.kdl`](vidro.kdl): translucent cards with compositor blur
- [`terminal.kdl`](terminal.kdl): tmux + IRC in amber phosphor
- [`subsolo.kdl`](subsolo.kdl): underground hacking terminal, acid green, ultraviolet and scanlines
- [`orbital.kdl`](orbital.kdl): ship console among the stars, with numbered systems, a command prompt and a server strip at the bottom
- [`editorial.kdl`](editorial.kdl): printed magazine on grainy paper, serif masthead between rules and an index on the right
- [`bolhas.kdl`](bolhas.kdl): light, with chat bubbles
- [`zen.kdl`](zen.kdl): one central column and nothing else
- [`papel.kdl`](papel.kdl): serif and mirrored
- [`escritorio.kdl`](escritorio.kdl): Slack-style, shows off `c-…` and `variant=list`
- [`cupertino.kdl`](cupertino.kdl): Mac-style desktop, with wallpaper, floating window, traffic lights and Dock

The tests (`zig build test`) load every built-in theme and build the layout of each one.
If you send a new theme in a pull request, it's checked automatically.

## Design tips

What separates a good-looking theme from a strange one is almost never the accent color. It's usually:

- **A single concept.** "Notebook", "terminal", "1989 laptop"… and everything follows it: colors,
  font, corners and borders.
- **Surfaces that separate.** Background, panels and elevated elements need clear steps of
  lightness. Purple on purple on purple turns into one blob.
- **Few bright colors.** One accent and, at most, one secondary. Use `roles` with colors from the
  same family so the names don't become a rainbow.
- **One text font**, and at most one for headings (`header … font="Liberation Serif"`).
- **Enough contrast** for `text`, `muted` and `faint` against each panel's background. Use `c-…`
  when part of the layout has a very different background (a dark sidebar in a light theme).
