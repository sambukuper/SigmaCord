# Atalhos e linha de comando

## Teclado

| Ação | Teclas |
|---|---|
| Mutar / desmutar o microfone | `Ctrl+Shift+M` |
| Ensurdecer / voltar a ouvir | `Ctrl+Shift+D` |
| Paleta de comandos | `Ctrl+K` |
| Paleta, ações primeiro | `Ctrl+Shift+P` |
| Buscar mensagens | `Ctrl+F` |
| Configurações | `Ctrl+,` |
| Próximo tema | `F2` |
| Tema anterior | `Shift+F2` |
| Próxima aba | `Ctrl+Tab` |
| Aba anterior | `Ctrl+Shift+Tab` |
| Ir para a aba N | `Alt+1…9` |
| Fechar aba | `Ctrl+W` |
| Caixa de entrada | `Ctrl+I` |
| Mensagens salvas | `Ctrl+Shift+S` |
| Abrir canal em nova aba | `Ctrl+Clique` |
| Fechar aba com o mouse | Clique do meio |
| Editar a sua última mensagem | `↑` na caixa vazia |
| Cancelar uma resposta ou edição | `Esc` |
| Copiar o texto selecionado | `Ctrl+C` |
| Nova linha na caixa de texto | `Shift+Enter` |
| Autocompletar na caixa de texto | `@`, `#`, `:ab` ou `/`, depois as setas e `Tab` ou `Enter` |
| Aperte para falar | A tecla ou o botão do mouse que você escolher em Configurações → Voz |

Tudo de "Mutar / desmutar o microfone" até "Fechar aba" é um atalho configurável: troque em Configurações → Atalhos de teclado (clique na tecla, aperte outra combinação; o × ao lado volta ao padrão, o quadradinho liga e desliga o atalho, e letras e números pedem Ctrl, Alt ou Super). Um interruptor faz todos valerem fora da janela também — no Windows e no Linux com X11 eles passam a funcionar em qualquer programa (no Wayland ficam só na janela); vem desligado, porque uma tecla global é tomada de todos os outros programas. O resto da tabela é fixo.

O botão direito funciona em mensagens, usuários, canais e servidores.

## Navegação estilo vim

Vem desligada. Ligue em Configurações → Atalhos de teclado. As teclas funcionam enquanto a caixa de texto não está em foco.

| Ação | Teclas |
|---|---|
| Rolar para baixo / para cima | `j` / `k` |
| Topo / fim da conversa | `gg` / `G` |
| Meia página para baixo / para cima | `Ctrl+d` / `Ctrl+u` |
| Próximo / anterior canal | `J` / `K` |
| Voltar para a caixa de texto | `i` ou `Enter` |
| Sair da caixa de texto, mantendo o texto | `Esc` |
| Busca (paleta) | `/` |

## Linha de comando

```bash
sigmacord [options]
```

| Opção | O que faz |
|---|---|
| `--theme NAME` | começa com esse tema |
| `--list-themes` | lista os temas embutidos e sai |
| `--mode MODE` | `claro` (ou `light`) ou `escuro`, ignorando as suas configurações |
| `--lang LANG` | `pt` ou `en`, ignorando as suas configurações |
| `--demo` | usa os dados de demonstração mesmo com token |
| `--login` | mostra a tela de login, ignorando o token salvo |
| `--settings` | abre direto nas configurações |
| `--no-live` | desliga as mensagens automáticas do modo demonstração |
| `--shot FILE.png` | salva uma captura de tela quando a tela se acalma e sai |
| `--stats` | mostra o tempo até o primeiro quadro |
| `--qa` | roda o teste automático da interface, com capturas de tela em `qa-out/` |
| `--voice-test GUILD CHANNEL` | entra num canal de voz por 25 s, sempre mudo (precisa de `SIGMACORD_TOKEN`) |
| `--help` | mostra o texto de uso |

## Variáveis de ambiente

| Variável | O que faz |
|---|---|
| `SIGMACORD_TOKEN` | o token da conta (veja [Conectar a sua conta](page:account)) |
| `SIGMACORD_RENDERER` | escolhe o backend de renderização do SDL: `opengl`, `vulkan`, `gpu` ou `software` |
| `SIGMACORD_HIDDEN` | abre com a janela oculta. O app não desenha nada enquanto ela está oculta, então a memória mede bem menos do que com uma janela de verdade |
| `SIGMACORD_BENCH` | redesenha sem parar, para medir o custo de um quadro |
| `SIGMACORD_VOICE_DEBUG` | imprime o que acontece numa call (opcodes, códigos de fechamento, DAVE). Nunca imprime tokens nem chaves |
| `SIGMACORD_DEBUG_MEDIA` | registra por que uma imagem não carregou |
| `SIGMACORD_NO_FFMPEG` | finge que o FFmpeg não está instalado |
| `SIGMACORD_EGL_ALL` | desliga o truque que pula drivers EGL desnecessários |
| `SIGMACORD_SCENE` | monta uma cena para as capturas de tela da documentação |
| `SIGMACORD_RECORD`, `SIGMACORD_RECORD_FRAMES` | grava a tela de login como quadros numa pasta |
| `SIGMACORD_FLOOD` | manda N mudanças de presença por segundo no modo demonstração (teste de carga) |

`XDG_CONFIG_HOME` e `XDG_CACHE_HOME` são respeitadas, e ajudam a rodar com uma configuração limpa.
