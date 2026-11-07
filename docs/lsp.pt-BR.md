# Erros no código (LSP)

Enquanto você digita um bloco de código na caixa de texto, o SigmaCord pode mostrar os erros que
um [servidor de linguagem](https://microsoft.github.io/language-server-protocol/) encontra nele.
Nada vem embutido no app e nada é baixado: o servidor é um programa seu, e só roda para uma
linguagem que você ligou. Com tudo desligado (o padrão), não há thread, processo filho nem memória
a mais em uso.

## Como ligar

Configurações → **Erros no código**. Cada linguagem tem um comando e um interruptor:

| Etiqueta do bloco | Linha |
| --- | --- |
| `zig` | Zig |
| `python`, `py`, `py3` | Python |
| `rust`, `rs` | Rust |
| `c`, `h`, `cpp`, `c++`, `cc`, `cxx`, `hpp` | C / C++ |
| `go`, `golang` | Go |
| `typescript`, `ts`, `tsx`, `javascript`, `js`, `jsx` | TypeScript / JavaScript |
| `lua` | Lua |

O servidor precisa falar LSP por stdin e stdout, então o comando costuma ser algo como `zls`,
`ruff server`, `pyright-langserver --stdio`, `rust-analyzer`, `clangd`, `gopls`,
`typescript-language-server --stdio` ou `lua-language-server`.

- **O comando não passa por um shell.** Ele é separado nos espaços, com `"…"` ou `'…'` para
  argumentos com espaço. `;`, `|`, `$HOME` e `~` são texto comum.
- Um nome de programa sem caminho é procurado no `PATH`.

A página também procura esses nomes conhecidos no seu `PATH` e oferece o que achar. Ela só confere
se o arquivo existe e é executável; não o executa. Clicar em **Usar … e ligar** guarda o caminho
inteiro como comando, e é com isso que você está concordando.

## Enquanto digita

Ponha o cursor dentro de um bloco:

````
```zig
const a: u32 = "texto";
```
````

Uns 300 ms depois que você para de digitar, o bloco vai para o servidor. Até três problemas
aparecem acima da caixa de texto (linha, gravidade, mensagem) e ficam sublinhados no texto. Se o
texto cresceu a ponto de rolar dentro da caixa, só a lista aparece. Os números de linha contam do
começo da mensagem, não do começo do bloco.

- Só o bloco sob o cursor é verificado, e só depois de uma quebra de linha após a etiqueta.
- O servidor sobe no primeiro bloco desses. Depois de um minuto sem digitar ele para; a próxima
  tecla sobe de novo.
- Um servidor que cai é reiniciado depois de 1, 4 e 15 segundos. Depois disso o erro aparece na
  caixa e nas Configurações, com um botão **Tentar de novo**, até você mudar a configuração.

## O que o servidor recebe

O app guarda o seu token do Discord, então o servidor roda com o mínimo possível:

- **Texto:** só o que você está digitando na sua caixa de texto, só o bloco sob o cursor. Nunca as
  mensagens dos outros, nem mais nada do app.
- **Ambiente:** só `PATH` e `HOME` (no Windows, também `SystemRoot`, `SystemDrive`, `USERPROFILE`,
  `APPDATA`, `LOCALAPPDATA`, `TEMP`, `TMP`, `PATHEXT`). O `SIGMACORD_TOKEN` e o resto do seu ambiente
  não chegam até ele.
- **Pasta:** ele roda numa pasta própria (`~/.cache/sigmacord/lsp-scratch`). O que um servidor
  deixou ali é apagado antes do próximo início, menos subpastas que não estão vazias: o app não entra
  nelas, então um link deixado ali não o faz apagar mais nada. `rootUri` e `workspaceFolders` são `null`, e o documento é um virtual,
  `file://<essa pasta vazia>/sigmacord-composer.<ext>`, que nunca existe em disco (servidores como o clangd só aceitam `file:`). Nada do que você digita é gravado em disco, e seus projetos
  ficam de fora. Isso também quer dizer que um servidor que espera um projeto (imports, arquivo de
  build) só vê um arquivo isolado, então os erros são só daquele trecho.
- **Arquivos abertos:** no Linux, os soquetes e arquivos do app são fechados no filho.
- **Limites:** uma mensagem acima de 1 MiB, quadros malformados, mais de 32 MiB de saída por minuto
  ou 10 segundos sem ler a entrada param o servidor. O stderr dele é descartado.

Isso não é uma jaula. Um servidor de linguagem é um programa comum que roda como você, e poderia
ler seus arquivos, inclusive onde o app guarda o token. Só ligue servidores em que você confia.

## Por um plugin

Um plugin Lua pode propor um servidor, por exemplo para uma linguagem que o app não lista:

```lua
sigma.lsp("haskell", {"haskell-language-server-wrapper", "--lsp"})
```

A proposta aparece na mesma página das Configurações, com o comando inteiro, desligada. Ela só roda
depois que você liga, e a decisão vale para aquele plugin, linguagem e comando exatos: se o plugin
mudar o comando, ela volta a ficar desligada. Veja
[plugins.pt-BR.md](plugins.pt-BR.md#sigmalsplinguagem-argv).

Se a linguagem tem os dois, o seu comando vale.

## Limites que vale conhecer

- Parar um servidor mata aquele processo, não o que ele abriu. Um comando intermediário que abre o
  servidor de verdade (`npx …`) pode deixar esse para trás.
- Se o app é morto de vez (`kill -9`, queda de energia), o servidor só percebe quando a entrada dele
  fecha. Servidores bem feitos saem nessa hora.
