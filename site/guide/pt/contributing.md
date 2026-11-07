# Contribuindo

## Compilar e testar

```bash
zig build -Doptimize=ReleaseFast    # o app
zig build test                      # testes unitários
tools/qa.sh                         # o QA completo da interface, fora da tela
tools/membench.sh 50                # RAM e CPU parado por tema, com um orçamento em MB
```

| Comando | O que faz |
|---|---|
| `zig build test` | Testa as partes puras: KDL, cores, layout, markdown, Store, temas embutidos, configurações, protobuf, APNG, URLs de mídia. Não precisa de SDL nem de janela |
| `tools/qa.sh` | Um build de debug com verificações de segurança. Roda a bateria geral, a tela de login nos dois modos e uma bateria por tema, em claro e escuro. As capturas de tela vão para `qa-out/` |
| `tools/qa_http_tls.sh` | Depois do `tools/qa.sh`: o HTTP dos plugins com TLS de verdade, contra um servidor local com certificado próprio. Precisa de `python3` e `openssl` |
| `tools/snapshots.sh` | Regenera as capturas de tela do README em `docs/` sem abrir janela |
| `tools/membench.sh N` | Mede todos os temas e falha se passar de N MB |
| `tools/site_shots.sh` | Regenera as imagens do site |
| `python3 tools/gen_site.py` | Regenera o site em `docs/` |

O QA controla a interface de verdade: ele clica nos elementos, e um botão sem efeito conta como falha. Roda em modo demonstração, sem janela, e nunca toca na sua conta.

O CI (`.github/workflows/ci.yml`) roda os testes, depois compila o app no Arch e roda o QA completo a cada push e pull request.

## Enviando um tema

Um tema é o jeito mais fácil de contribuir: um arquivo `.kdl` e nada de Zig. O `zig build test` carrega todos os temas embutidos e monta o layout de cada um, então um tema novo é verificado automaticamente. Leia [Escrevendo temas](page:themes), principalmente as dicas de design no final.

Para incluir um como embutido, ponha o arquivo em `themes/` e acrescente o nome dele em `theme_names` no `build.zig` e em `themes/builtin.zig`.

## Enviando código

- Mantenha as camadas separadas: o `core/` não sabe nada de janelas, e a interface nunca muda dados diretamente.
- Mantenha leve. Não acrescente trabalho por quadro, por mensagem ou por tecla quando ninguém está usando, e lembre que o laço deve dormir.
- Teste as partes puras no `zig build test` e acrescente um passo ao QA para o comportamento da interface.
- Rode o `tools/qa.sh` antes de abrir um pull request.
- Os comentários e identificadores do código deste repositório estão, em sua maioria, em português, então siga o arquivo que você está editando.

## Documentação

O inglês é a versão principal e o português é a secundária, e as duas devem mudar juntas.

| Inglês | Português |
|---|---|
| `README.md` | `README.pt-BR.md` |
| `docs/plugins.md` | `docs/plugins.pt-BR.md` |
| `site/guide/en/*.md` | `site/guide/pt/*.md` |
| `site/landing.html` (`{{English\|\|Português}}`) | o mesmo arquivo |

O site fica em `docs/` e é gerado pelo `tools/gen_site.py` a partir desses arquivos e de `themes/*.kdl`. As paletas, opções e layouts de tema no site sempre vêm dos arquivos de tema reais.

## Créditos

Feito com Zig, SDL3, [Dear ImGui](https://github.com/ocornut/imgui), dear_bindings, FreeType, fontconfig, libcurl, zlib, libwebp, Opus, stb_image, [Lua](https://www.lua.org), [libdave](https://github.com/discord/libdave) e [MLSpp](https://github.com/cisco/mlspp). O site usa Departure Mono, JetBrains Mono, Archivo, Fraunces e DM Mono, sob a SIL Open Font License.

## Licença

O SigmaCord usa a licença GPL-3.0. O código de terceiros em `third_party/` mantém a própria licença, no arquivo de licença de cada pasta.
