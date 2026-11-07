# Escrevendo temas

[English](README.md) · **Português**

Um tema do SigmaCord é um arquivo [KDL](https://kdl.dev) que descreve **a interface inteira**:
cores, fontes, estilos e a árvore de layout. Dá pra mudar a posição de tudo sem escrever
uma linha de código.

Coloque o arquivo em `~/.config/sigmacord/themes/meu-tema.kdl` (ou em `themes/`, ao rodar
de dentro do repositório). **Ao salvar, o app recarrega na hora.** Se houver um erro, aparece
um aviso com `arquivo:linha:coluna` e o tema anterior continua valendo.

Troque de tema com `F2`, pela paleta (`Ctrl+K` → "tema: …") ou em Configurações → Aparência.

## Exemplo mínimo

```kdl
theme "meu-tema" description="Servidores embaixo, chat em cima." preview=classic
palette "wal"                      // usa as cores do pywal (opcional)

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

## Nós de topo

| Nó | O que faz |
|---|---|
| `theme "nome" description=… author=… preview=…` | metadados. `preview` escolhe a miniatura nas configurações: `classic`, `glass`, `terminal`, `bubbles`, `zen`, `mirror`, `office`, `desktop` |
| `palette "wal"` ou `palette "#hex" …` | as 16 cores base (`wal:0` … `wal:15`). Sem isso, usa uma paleta padrão |
| `colors { token "expressão" … }` | sobrescreve tokens de cor (lista abaixo) |
| `roles "cor" …` | até 8 cores de cargo (nomes de usuário, ícones de servidor) |
| `fonts ui="Inter" mono="JetBrains Mono" size=16` | famílias (resolvidas pelo fontconfig) e tamanho base |
| `metrics radius=6` | arredondamento padrão de linhas e botões |
| `window transparent=#true` | fundo da janela transparente: o compositor aplica blur |
| `styles { style "nome" … }` | estilos nomeados para usar com `style=nome` |
| `layout { … }` | a árvore da interface (um único filho na raiz) |

## Cores

Expressões aceitas em qualquer lugar que pede cor:

```
"#df68ad"   "#df68ad80"   "#fff"   "#fff8"
"wal:4"                    cor da paleta
"@surface"                 outro token (já definido)
"mix(a, b, 0.3)"           mistura
"alpha(a, 0.5)"            transparência
"lighten(a, 0.1)"  "darken(a, 0.2)"
white  black  transparent
```

Tokens: `bg` `rail` `sidebar` `surface` `elevated` `overlay` `text` `muted` `faint` `accent`
`accent-text` `border` `hover` `selected` `online` `idle` `dnd` `danger` `mention` `link`
`code-bg` `bubble-self` `bubble-self-text` `bubble-other` `shadow`.

## Estilos

```kdl
styles {
    style "card" bg="@surface" radius=18 border="@border" border-width=1.5 glow="@accent" shadow=16
}
```

`glow` é a cor da borda quando o mouse está em cima. `shadow` é o tamanho da sombra.
Para um fundo simples, sem estilo nomeado, use direto no nó: `bg=sidebar radius=12`
(`bg` no nó também aceita expressão: `bg="alpha(@accent, 0.4)"`).

Além disso, estilos **e nós do layout** podem ter as primitivas da seção
[Além do retângulo chapado](#além-do-retângulo-chapado): gradiente, padrão, grão, vinheta, sombra
interna, borda por lado.

## Layout

Contêineres: `row` (horizontal), `column` (vertical), `stack` (um sobre o outro).

| Propriedade | Efeito |
|---|---|
| `width=` / `height=` | tamanho fixo no eixo do pai |
| `flex=` | peso no espaço que sobra (padrão 1) |
| `gap=` `padding=` `padding-x=` `padding-y=` | espaçamentos (contêineres) |
| `inset-x=` `inset-y=` | margem interna de um componente |
| `max-width=` | limita a largura e centraliza |
| `hide-below=` | esconde quando a janela é mais estreita que isso |
| `show=#false` | esconde |
| `style=` / `bg=` `radius=` | fundo do nó |
| `font=mono` / `font=ui` / `font="Liberation Serif"` | fonte do componente: a mono, a da interface ou **qualquer família instalada** |
| `c-<token>=cor` | sobrescreve um token de cor **neste nó e nos filhos** (ex.: `c-text="#fff"` numa barra lateral escura) |

O filho de uma `row` que tem `width=` fixo e contém `channel-list` ou `member-list` é ajustável: o app desenha uma alça de arrastar do lado que dá para o vizinho `flex` da row, e a largura escolhida pela pessoa soma com a que você definiu. Sem vizinho `flex`, não tem alça.

## Componentes

| Componente | Propriedades |
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
| `label` | `text=` `size=` `weight=regular\|medium\|semibold\|bold` `color=token` `align=left\|center\|right`, mais [tipografia de display](#tipografia-de-display-no-label) |
| `shape` | círculo, anel, arco, retângulo arredondado, linha ([detalhes](#shape-e-rule)) |
| `rule` | régua lisa, tracejada, dupla, de jornal, com ornamento ([detalhes](#shape-e-rule)) |
| `starfield` `orbit` `aurora` `dunes` `topography` `radar` | [fundos procedurais](#fundos-procedurais) (primeiro filho de um `stack`) |
| `window-controls` | os três botões da janela, que funcionam de verdade: fechar, minimizar, maximizar. `size=12` `gap=8` `color=` `color2=` `color3=` `align=` |
| `logo` | `variant=ascii\|wordmark` `size=` |
| `topbar` | barra superior (abas, busca, ajuda) |
| `crt` | `spacing=3` `strength=0.08` |
| `spacer` | espaço vazio |

Um nome que não existe aparece com uma borda vermelha e a linha do arquivo, pra facilitar.

## Além do retângulo chapado

Tudo aqui é opcional, vale num `style "…"` ou direto num nó do layout, e as cores são expressões
(`"alpha(@accent, 0.4)"`, ou só o nome do token). Elas são avaliadas com os tokens do momento, então
acompanham o modo claro/escuro, a cor de destaque escolhida e os `c-…` do pedaço do layout.

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

| Propriedade | O que faz |
|---|---|
| `gradient="a b"` ou `"a b c"` | gradiente de 2 ou 3 cores (separadas por espaço) |
| `gradient-angle=90` | graus: `0` da esquerda para a direita, `90` de cima para baixo (padrão) |
| `pattern=dots\|lines\|grid\|diagonal` | padrão repetido; pede `pattern-color` |
| `pattern-size=16` `pattern-width=1` | distância entre repetições e espessura do traço (ou raio do ponto) |
| `grain=cor` | grão: ruído fino, tingido por essa cor |
| `vignette=cor` `vignette-size=0.55` | escurece (ou tinge) as bordas; `size` é onde começa, de 0 (centro) a 1 (cantos) |
| `inner-shadow=cor` `inner-shadow-size=14` | sombra para dentro |
| `border-gradient="a b c"` `border-gradient-angle=` `border-width=` | borda em gradiente |
| `border-top=cor` `border-right=` `border-bottom=` `border-left=` | borda só naquele lado |
| `border-top-width=2` (idem para os outros lados) | espessura daquele lado (padrão: `border-width`, ou 1) |
| `hover-bg=cor` | fundo por cima quando o mouse está em cima, com transição |
| `drop-shadow=cor` `drop-shadow-size=32` `drop-shadow-y=10` | sombra macia e **oca**: não escurece o que está embaixo de um painel translúcido (o `shadow=` antigo escurece) |
| `corners=left\|right\|top\|bottom` | quais cantos o preenchimento arredonda: uma janela de dois painéis lado a lado |
| `border=cor` | borda inteira, para usar direto num nó (nos estilos, ela já existe) |

Custo: gradiente de 2 cores são só vértices. Grão, padrão, vinheta e gradiente de 3 cores são texturas
minúsculas geradas **uma vez** e repetidas: um quad por quadro, nada de ruído recalculado. Tema que não
usa nada disso não passa por esse código.

Grão muito forte no escuro atrapalha mais do que no claro. Quando o valor precisa mudar com o modo,
use estilos separados: `styles mode=light { style "pagina" grain="alpha(@text, 0.07)" }` e
`styles mode=dark { style "pagina" grain="alpha(@text, 0.025)" }`. Um nó também pode aparecer só num
modo: `when=modo-claro`, `when=modo-escuro`.

## Tipografia de display no `label`

```kdl
// Tracking de verdade: nada de "O R B I T A L" com espaços.
label text="ORBITAL" tracking=8 size=15 weight=bold font=mono

// Runs: cor, peso, tamanho e fonte diferentes na mesma linha, na mesma linha de base.
label height=38 size=9 color=muted font=mono span-gap=9 {
    span "01" size=18 color=accent
    span "CANAIS" en="CHANNELS" tracking=3
}

// Efeitos.
label text="SigmaCord" size=40 shadow="alpha(black, 0.5)" shadow-x=2 shadow-y=2
label text="SigmaCord" size=40 shadow="alpha(@accent, 0.4)" shadow-blur=3   // brilho
label text="SigmaCord" size=40 color=bg outline=accent outline-width=2
label text="SigmaCord" size=40 text-gradient="@text @accent" text-gradient-angle=0
```

| Propriedade | O que faz |
|---|---|
| `tracking=` | espaço extra entre as letras, em pixels (pode ser negativo) |
| `color=` | também aceita expressão: `color="alpha(@text, 0.7)"` |
| `text-en=` (`en=` no `span`) | versão em inglês do texto |
| `span "texto"` | um pedaço da linha; `size` `weight` `color` `font` `tracking` herdam do `label` |
| `span-gap=` | espaço entre os spans |
| `shadow=cor` `shadow-x=` `shadow-y=` `shadow-blur=` | sombra; com `blur` vira um halo macio |
| `outline=cor` `outline-width=` | contorno |
| `text-gradient="a b"` `text-gradient-angle=` | gradiente no texto (padrão: horizontal) |

O `label` sem nada disso continua igual e no mesmo caminho de sempre. Efeitos desenham o texto mais
vezes: guarde para títulos e wordmarks.

## `shape` e `rule`

Formas e réguas desenhadas de verdade, em vez de caracteres Unicode. Empilhe num `stack` para compor.

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
rule height=7 kind=oxford color=text                                 // fio grosso sobre fio fino
rule height=11 kind=double color=text ornament=star ornament-color=accent ornament-size=11
rule height=20 ornament-text="§" ornament-size=16 font="Liberation Serif"
rule width=1 vertical=#true color=border
rule height=1 fade=#true color=accent                                // some nas pontas
```

| `shape` | |
|---|---|
| `kind=` | `circle` `ring` `arc` `rounded` `line` |
| `color=` `thickness=` | cor e espessura do traço |
| `size=` | diâmetro (padrão: o menor lado do nó); em `line`, o comprimento |
| `fill=` | preenchimento de `ring` e `rounded` |
| `start=` `sweep=` | início e abertura do `arc`, em graus |
| `dot=cor` `dot-size=` | um ponto na ponta do `arc` |
| `radius=` | cantos do `rounded` |
| `angle=` | inclinação da `line`, em graus |
| `align=left\|center\|right` `offset-x=` `offset-y=` | posição dentro do nó |

| `rule` | |
|---|---|
| `kind=` | `solid` `dashed` `dotted` `double` `oxford` |
| `color=` `thickness=` | cor e espessura |
| `dash=` `gap=` | tamanho do traço e do vão em `dashed` |
| `vertical=#true` | de cima para baixo (dê um `width=` ao nó) |
| `fade=#true` | some nas duas pontas |
| `ornament=` | `diamond` `dot` `ring` `star`, no meio da régua |
| `ornament-text=` | um caractere no meio, em vez da forma (usa o `font=` do nó) |
| `ornament-color=` `ornament-size=` `ornament-gap=` | cor, tamanho e o vão da régua em volta |

## Fundos procedurais

Vão como primeiro filho de um `stack`, atrás de todo o resto. São **parados por padrão**: gerados uma
vez, ficam numa textura, e um tema parado não acorda o app.

```kdl
layout {
    stack {
        starfield color="alpha(@muted, 0.75)" color2="alpha(@accent, 0.8)" density=1.1
        orbit center-x=0.73 center-y=0.4 rings=7 color="alpha(@accent, 0.4)" color2=accent
        column { … painéis … }
    }
}
```

| Componente | Cores | Propriedades |
|---|---|---|
| `starfield` | `color` estrelas de longe, `color2` as de perto | `density=1` |
| `orbit` | `color` as órbitas, `color2` as luas | `center-x=0.7` `center-y=0.35` `rings=6` |
| `aurora` | `color` e `color2`, uma para cada cortina | |
| `dunes` | `color`, `color2`, `color3`: colinas de trás para a frente (o céu é o `gradient` do nó em volta) | |
| `topography` | `color` | `levels=14` (quantas curvas de nível) |
| `radar` | `color` anéis, `color2` a varredura | `center-x=0.5` `center-y=0.5` `rings=5` |

Todos aceitam `seed=` (outro desenho), e todos menos `topography` aceitam movimento:
`motion=#true`, ou melhor `motion="$opcao"`, para o usuário escolher, e `motion-fps=10` (no máximo 15).
O movimento só desloca a textura ou redesenha uma peça pequena, e para sozinho com "Reduzir movimento" e
com a janela minimizada ou fora de foco.

A máscara é só forma: a cor vem na hora de desenhar. Trocar de modo ou de cor de destaque não gera nada
de novo. Só `orbit` e `radar` dependem do tamanho, e são refeitos uma vez quando a janela para de mudar.

**Contraste primeiro.** Texto nunca fica direto sobre um fundo forte: ponha um painel translúcido no
meio (`gradient="alpha(@surface, 0.9) alpha(@surface, 0.76)"`) e confira nos dois modos. Use cores
derivadas de tokens: `@muted` no escuro são estrelas claras, e no claro viram tinta sobre papel.

## Claro e escuro

Todo tema tem as duas versões. Blocos com `mode=` só valem num dos modos:

```kdl
colors mode=dark  { bg "#0b0906"; text "#ffcf73" }
colors mode=light { bg "#f4efe2"; text "#2e2412" }
roles mode=light "#7a4a00" "#9c3f10"
```

Sem `mode=`, o bloco vale nos dois. Se o tema não definir o claro, ele é derivado da paleta
(papel quase branco, tinta escura e destaque escurecido). No layout, `cl-<token>` e `cd-<token>`
sobrescrevem uma cor só no claro ou só no escuro. O usuário escolhe em Configurações → Aparência
(Escuro / Claro / Seguir o sistema), ou pela linha de comando: `--mode claro`.

## Opções do tema

Um tema pode oferecer chaves de liga/desliga, que aparecem em Configurações → Aparência:

```kdl
options {
    option "crt" label="Efeito CRT" description="Linhas de varredura…" default=#true
    option "verde" label="Fósforo verde" default=#false
}
```

Formas de usar as opções:

| Onde | Como |
|---|---|
| esconder/mostrar um nó | `crt when=crt`, `tabs unless=compacto` |
| propriedade booleana | `banner="$banner"`, `typing="$!digitando"` (o `!` inverte) |
| bloco de cores, cargos, estilos | `colors mode=dark when=verde { … }` |
| estilo | `style "card" sheen="$brilho"` |

As escolhas ficam salvas por tema em `~/.config/sigmacord/settings.kdl`.

## Cores personalizadas (sem editar o `.kdl`)

Em **Configurações → Aparência → Cores do tema** você pode trocar qualquer token de cor
(`bg`, `sidebar`, `text`, `accent`, `link`, `bubble-self`…) e as oito cores de cargo por um
hex livre. Vale só para o **tema atual e o modo atual** (escuro ou claro), e tem prioridade
sobre a “Cor de destaque” global.

- `#RRGGBB` para cor opaca; `#RRGGBBAA` para cor com transparência.
- Clique num item da grade, cole o hex e aperte Enter.
- “Limpar esta cor” volta aquele item ao tema; “Restaurar tema” apaga as escolhas do tema.
- As escolhas ficam em `settings.kdl` como `theme-colors "nome" mode=dark accent="#…"`,
  então não alteram o arquivo do tema.
- Trechos que usam `c-…` fixo no layout (alguns temas usam para manter contraste) continuam
  com a cor do arquivo; para mudar esses, edite o `.kdl`.

### Em inglês

A interface tem português e inglês. Para o seu tema aparecer bem nos dois, ponha a versão em
inglês ao lado: `label-en=` e `description-en=` nas opções, e `description-en=` no nó `theme`.
Sem elas, aparece o texto em português.

```kdl
theme "meu-tema" description="Servidores embaixo." description-en="Servers at the bottom."
options {
    option "crt" label="Efeito CRT" label-en="CRT effect" description="Linhas de varredura" description-en="Scanlines"
}
```

## Recursos exclusivos

| Componente / propriedade | O que faz | Usado em |
|---|---|---|
| `channel-list banner=#true` | banner colorido com o nome do servidor | classico |
| `style … sheen=#true` | reflexo de vidro no topo do cartão | vidro |
| `crt` | linhas de varredura + vinheta, por cima de tudo (use num `stack`) | terminal, subsolo |
| `logo variant=ascii\|wordmark` | logo do app em ASCII ou em texto | terminal, subsolo, escritorio |
| `messages ruled=#true margin-line=#true` | folha pautada e margem vermelha | papel |
| `messages ticks=#true typing-bubble=#true` | "Entregue ✓✓" e balão de digitando | bolhas |
| `autohide=#true` (qualquer nó) | o componente some até o mouse chegar perto | zen |
| `guild-bar variant=bar orientation=horizontal` | faixa horizontal de servidores no rodapé, sem zoom nos ícones | orbital |
| `topbar` | voltar/avançar entre abas, busca e ajuda | escritorio, editorial (opcional no orbital) |
| `starfield` `orbit`, wordmark com `tracking`, painéis translúcidos | console no meio das estrelas; no claro, carta celeste | orbital |
| `grain`, `rule kind=oxford`, `label` com `span` | papel com grão, masthead, fios de jornal | editorial |
| `aurora`, `border-gradient`, `grain` | luz por trás do vidro fosco | vidro |
| `pattern=grid`, `radar`, `topography` | retícula de osciloscópio; radar e mapa opcionais | terminal |
| `dunes`, `window-controls`, `corners`, `drop-shadow`, `guild-bar variant=dock` | mesa de trabalho com janela flutuante, barra lateral translúcida e Dock | cupertino |
| `topography`, `pattern=diagonal`, `shadow-x` | mapa de túneis, fita de perigo, letreiro com aberração cromática | subsolo |
| `shape kind=arc`, `topography`, `grain` | enso e areia rastelada | zen |
| `shape kind=ring`, `pattern=dots`, `rule kind=oxford`, `ornament-text` | furos de fichário, página pontilhada, índice | papel |
| `aurora`, `pattern=dots`, `drop-shadow` | cartões flutuando sobre um fundo colorido | bolhas |

## Os temas que vêm junto

- [`classico.kdl`](classico.kdl): o layout familiar
- [`vidro.kdl`](vidro.kdl): cartões translúcidos com blur do compositor
- [`terminal.kdl`](terminal.kdl): tmux + IRC em fósforo âmbar
- [`subsolo.kdl`](subsolo.kdl): terminal de hacking underground, verde ácido, ultravioleta e scanlines
- [`orbital.kdl`](orbital.kdl): console de bordo entre as estrelas, com sistemas numerados, prompt de comando e faixa de servidores no rodapé
- [`editorial.kdl`](editorial.kdl): revista impressa em papel com grão, masthead em serifa entre réguas e índice à direita
- [`bolhas.kdl`](bolhas.kdl): claro, com balões de conversa
- [`zen.kdl`](zen.kdl): uma coluna central e mais nada
- [`papel.kdl`](papel.kdl): serifado e espelhado
- [`escritorio.kdl`](escritorio.kdl): estilo Slack, mostra o `c-…` e o `variant=list`
- [`cupertino.kdl`](cupertino.kdl): mesa de trabalho estilo Mac, com papel de parede, janela flutuante, semáforo e Dock

Os testes (`zig build test`) carregam todos os temas embutidos e montam o layout de cada um.
Se você mandar um tema novo num pull request, ele é verificado automaticamente.

## Dicas de design

O que separa um tema bonito de um tema estranho quase nunca é a cor de destaque. Normalmente é:

- **Um conceito só.** "Caderno", "terminal", "portátil de 1989"… e tudo segue ele: cores,
  fonte, cantos e bordas.
- **Superfícies que se separam.** Fundo, painéis e elementos elevados precisam de degraus de
  luminosidade claros. Roxo sobre roxo sobre roxo vira uma massa só.
- **Poucas cores acesas.** Uma de destaque e, no máximo, uma secundária. Use `roles` com cores da
  mesma família para os nomes não virarem um arco-íris.
- **Uma fonte de texto**, e no máximo uma de títulos (`header … font="Liberation Serif"`).
- **Contraste suficiente** para `text`, `muted` e `faint` sobre o fundo de cada painel. Use `c-…`
  quando um pedaço do layout tem fundo bem diferente (barra lateral escura num tema claro).
