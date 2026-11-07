# Configurações e arquivos

Abra as configurações com `Ctrl+,`. As mudanças valem na hora e são salvas em `~/.config/sigmacord/settings.kdl`.

## As páginas

| Página | O que tem |
|---|---|
| **Minha conta** | Dados da conta e sair |
| **Privacidade** | Indicador de digitação, animação do Tenor e do Giphy, modo streamer, registro de mensagens, guardar mensagens no disco, limpar o cache e o proxy de rede |
| **Alertas e filtros** | Palavras de alerta, filtro de palavras, pessoas ignoradas e modo foco |
| **Aparência** | Modo (escuro, claro, seguir o sistema), tema com miniaturas e as opções dele, escala da fonte, modo compacto, avatares, relógio de 24 horas, status em anel, cor de destaque, cantos, cores personalizadas do tema, restaurar a largura dos painéis, lista de membros e barra de status |
| **Acessibilidade** | Reduzir movimento, cores dos cargos, sublinhar links |
| **Chat** | Reproduzir GIFs automaticamente, imagens de links, modo economia, sempre mostrar spoilers, prévia do markdown, abrir na primeira não lida |
| **Voz** | Microfone e saída, volumes, detecção de voz ou aperte para falar, teste do microfone, filtros e sons da call. Veja [Chamadas de voz](page:voice) |
| **Notificações** | Notificações na área de trabalho e piscar na barra de tarefas |
| **Atalhos de teclado** | A lista de atalhos e a navegação estilo vim |
| **Idioma** | Seguir o sistema, Português (Brasil) ou English (US) |
| **Avançado** | Modo desenvolvedor (IDs das mensagens, "Copiar ID") e recarregar temas ao salvar |
| **Desempenho** | RAM, CPU por quadro, CPU parado e mensagens por canal |
| **Plugins** | Um cartão para cada plugin (o que ele é e o que pede), ligar e desligar, erros, aprovação de hosts, o painel dele, Recarregar e Instalar os incluídos |
| **Sobre** | Versão e com o que foi feito |

## Escolhas de privacidade que valem conhecer

| Opção | Padrão | Efeito |
|---|---|---|
| Enviar indicador de digitação | ligado | Os outros veem "digitando…" enquanto você escreve |
| Animar GIFs do Tenor e do Giphy | desligado | Baixa do site deles, que vê o seu IP. Desligado, você recebe uma prévia parada pelo Discord |
| Modo streamer | desligado | Esconde o seu e-mail e o seu nome de usuário nas configurações |
| Registro de mensagens | desligado | As mensagens apagadas continuam visíveis, marcadas, e as edições guardam o original. Só local |
| Guardar mensagens no disco | ligado | As conversas abrem na hora e o `Ctrl+F` funciona offline. Só o seu usuário lê os arquivos |

## Arquivos no disco

`$XDG_CONFIG_HOME` e `$XDG_CACHE_HOME` substituem `~/.config` e `~/.cache` quando definidos.

| Caminho | O que é |
|---|---|
| `~/.config/sigmacord/settings.kdl` | Configurações, incluindo as opções e cores de cada tema |
| `~/.config/sigmacord/themes/*.kdl` | Seus temas |
| `~/.config/sigmacord/plugins/*.lua` | Seus plugins |
| `~/.config/sigmacord/plugins.kdl` | Quais plugins estão desligados, os hosts aprovados e o painel lateral |
| `~/.config/sigmacord/plugin-data/` | O que cada plugin guarda, por conta |
| `~/.config/sigmacord/drafts.kdl` | Rascunhos não enviados por canal (`chmod 600`) |
| `~/.config/sigmacord/saved-<conta>.json` | Mensagens salvas e anotações |
| `~/.config/sigmacord/accounts` | Contas guardadas: só ID, nome e foto |
| `~/.config/sigmacord/tokens/<ID>` | Tokens lembrados quando não há chaveiro (`chmod 600`) |
| `~/.config/sigmacord/token` | Arquivo de token opcional (`chmod 600`) |
| `~/.cache/sigmacord/messages` | Cache de mensagens: pastas 700, arquivos 600, 200 mensagens por canal, teto de 50 MB |
| `~/.cache/wal/colors` | Só leitura: a paleta do pywal, para os temas que a usam |

Para voltar ao padrão, feche o app e apague `~/.config/sigmacord/settings.kdl`.
