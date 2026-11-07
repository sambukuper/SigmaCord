# Estado e roadmap

O SigmaCord é um projeto jovem: versão 0.6.0, com o primeiro commit em 2 de novembro de 2026. Dá para usar, mas não está completo.

## O que funciona hoje

| Área | Estado | Detalhe |
|---|---|---|
| Mensagens, DMs, reações, respostas | **funciona** | Enviar, editar, excluir, histórico, menções |
| Imagens | **funciona** | Avatares e anexos, com cache de tamanho fixo |
| Vídeo na conversa | **funciona** | Anexos e links diretos. Precisa do FFmpeg do sistema |
| Caixa de entrada, mensagens salvas, busca offline | **funciona** | Tudo local, dá para desligar e apagar |
| Várias contas, proxy, plugins em Lua | **funciona** | |
| Threads e fóruns | **funciona** | Threads aninhadas, lista de posts dos fóruns, criar threads e posts, arquivadas |
| Emoji personalizado, figurinhas, autocompletar | **funciona** | Animados inclusive. O seletor avisa quando um emoji precisa de Nitro |
| Leitura, fixadas, links do Discord | **funciona** | Sincronizada com os seus outros aparelhos |
| Temas | **funciona** | 11 embutidos, cada um em claro e escuro, recarregam ao salvar |
| Voz | parcial | E2EE (DAVE), mixer, mudo, seletor de dispositivo, aperte para falar, filtro passa-altas, porta de ruído e supressão de ruído com RNNoise funcionam. O aperte para falar precisa da janela em foco, e nenhum teste automático cobre uma call de verdade |
| Permissões | parcial | Canais sem acesso ganham cadeado, voz sem permissão é bloqueada, e threads e fóruns conferem se você pode postar. Esses canais ainda aparecem, e a caixa de texto nos canais comuns, as reações e a lista de membros não consultam a permissão |
| Bandeja, atualizações | **funciona** | Fechar mantém na bandeja; atualização assinada nas Configurações. No Linux a bandeja precisa de painel StatusNotifier |
| Windows | parcial | Windows 10/11 do mesmo código. Mais novo que o Linux e menos usado |
| Notificações | parcial | Por `notify-send` no Linux e pela bandeja no Windows. O clique não abre o canal |
| Acessibilidade | parcial | Escala da fonte, reduzir movimento, paleta e navegação estilo vim. Sem foco visível e sem alto contraste |
| Primeiro uso | parcial | Tela de login e modo demonstração, sem apresentação do app |
| Plataformas | parcial | Linux e Windows. A versão para Linux exige glibc 2.34 ou mais nova. É usada todo dia no Arch com Hyprland, e aberta em contêineres de Ubuntu, Debian, Fedora, openSUSE e Arch, na demonstração, antes de cada versão. A versão para Windows só rodou no CI e num sandbox, em modo demonstração |
| Entrar em servidor por convite | falta | Convites viram um cartão e abrem no navegador |
| Compartilhar tela e câmera | falta | |

## Roadmap

**Feito**

- [x] Gateway real (WebSocket, heartbeat, reconexão) e REST respeitando o rate limit
- [x] RESUME de sessão e zlib-stream
- [x] Presenças, membros e eventos de servidor e canal
- [x] Imagens: avatares, anexos e emoji personalizado com cache de tamanho fixo
- [x] Voz: gateway de voz, UDP, Opus e DAVE/MLS
- [x] Configurações de voz: seletor de dispositivo, aperte para falar, filtros e sons da call
- [x] Threads e fóruns
- [x] Figurinhas, seletor de emoji completo e autocompletar
- [x] Leitura sincronizada com o Discord, mensagens fixadas, links do Discord no app
- [x] Motor de temas: gradientes, padrões, grão, vinheta, tipografia de display, formas e linhas, fundos procedurais

**A seguir**

- [ ] Abrir pelos servidores, canais e mensagens salvos, e sincronizar quando o Discord responder
- [ ] Rich Presence: mostrar o jogo que você está jogando, desligado por padrão
- [ ] Moderação: expulsar, banir, castigo, e silenciar e ensurdecer no servidor
- [ ] Atlas de texturas para avatares e emojis
- [ ] Configurar servidor e cargos
- [ ] Um editor de temas melhor
- [ ] Plugins mais versáteis e com mais poder
- [ ] Windows em um `.exe` só

**Para o app ficar completo**

- [ ] Permissões de verdade: esconder o que você não pode ver, desabilitar a caixa de texto e as reações, filtrar os membros
- [ ] Entrar em servidor por convite
- [ ] Notificações nativas via D-Bus com "abrir conversa"
- [ ] Voz: aperte para falar global e teste automático de call
- [ ] Acessibilidade e primeiro uso: foco visível, alto contraste, uma tela de boas-vindas

**Temas**

- [ ] Motor: sobreposição e ordem z, fontes e imagens que venham com o tema
- [ ] Galeria e editor: miniaturas reais, importar e exportar `.kdl`, um inspetor de componentes
- [ ] Componentes de tema escritos em Lua (sandbox)

**Mais para frente**

- [ ] Um backend por software (`wl_shm`, sem GPU), para chegar a cerca de 15–20 MB
