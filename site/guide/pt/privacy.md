# Privacidade e segurança

> [!WARNING]
> **Clientes de terceiros violam os Termos de Uso do Discord, e a sua conta pode ser banida.** Nada nesta página muda isso. As seções abaixo descrevem como o app trata os seus dados, não se o Discord vai aceitar.

## Seu token

- Ele nunca fica no código, em logs nem em mensagens de erro.
- É apagado da memória quando o app fecha.
- É guardado no chaveiro do sistema quando possível. Sem chaveiro, vai para um arquivo com `chmod 600`, e o app avisa se o arquivo puder ser lido por outros.
- Com "Lembrar" ligado, ele só é salvo depois que o Discord o aceita.
- `SIGMACORD_VOICE_DEBUG` e `SIGMACORD_DEBUG_MEDIA` nunca imprimem tokens nem chaves.

Ele só é enviado ao Discord.

## Confirmações de leitura

Como o cliente oficial, o app avisa o Discord do que você leu, no máximo uma vez por canal a cada 3 segundos. Sozinho, nada é enviado com a janela sem foco. Marcar como lido ou não lido à mão sempre vai, e o seu status não muda nada disso.

## O que fica no seu computador

| O quê | Onde | Controle |
|---|---|---|
| Cache de mensagens | `~/.cache/sigmacord/messages`, pastas 700, arquivos 600 | 200 mensagens por canal, teto de 50 MB. Dá para desligar e apagar em Configurações → Privacidade |
| Rascunhos | `drafts.kdl`, `chmod 600` | Enviar uma mensagem apaga o rascunho dela |
| Mensagens salvas e anotações | `saved-<conta>.json` | Até 500. Nada vai para o Discord |
| Palavras de alerta, filtros, pessoas ignoradas | `settings.kdl` | Ninguém é avisado |
| Registro de mensagens | Local, na tela | Desligado por padrão |

A lista completa está em [Configurações e arquivos](page:settings).

## O que passa pela rede

A única requisição que não vai para o Discord nem para os CDNs dele é a verificação de atualização: ao abrir o app (com "Verificar ao abrir" ligado) ou quando você aperta o botão, ele pergunta a última versão a `api.github.com`, sem nenhum dado da conta. Os downloads vêm do GitHub e são conferidos com uma lista assinada.

- **Discord**: gateway, REST e mídia.
- **Mídia externa, só quando você pede**: os GIFs animados do Tenor e do Giphy ficam desligados por padrão porque esses sites veem o seu IP. Desligado, você recebe uma prévia parada pelo proxy do Discord.
- Os links abrem no seu navegador.

Os downloads de mídia só vão para hosts permitidos, os redirecionamentos são conferidos, as imagens são limitadas a 8192 pixels por lado, e os downloads param em 32 MB para imagens e 64 MB para vídeo.

O app não tem telemetria nem análise de uso.

## Proxy

Configurações → Privacidade → Rede aceita `http`, `https`, `socks5` e `socks5h`. Para o Tor, use `socks5h://127.0.0.1:9050`.

Por padrão, o proxy vale para a mídia de fora do Discord. **Usar o proxy em tudo** também passa a API, as imagens, os vídeos e o gateway por ele (o gateway a partir da próxima conexão).

## Plugins

Os plugins rodam com a sua conta, então só use arquivos que você leu e entende. O sandbox limita o que eles podem fazer:

- Um plugin nunca vê o seu token nem o seu e-mail.
- Sem acesso a arquivos, programas nem sockets. `io`, `os.execute`, `os.remove`, `os.getenv`, `require`, `package`, `debug`, `coroutine`, `load`, `loadfile`, `dofile`, `collectgarbage` e `string.dump` não existem.
- Cerca de 5 milhões de instruções por chamada e 8 MB de memória por plugin, numa thread só deles.
- O `sigma.send` só funciona direto de um gesto naquele plugin (comando, atalho, botão ou entrada de menu dele), porque respostas automáticas transformariam a sua conta num self-bot.
- A única rede é o `sigma.http`: só HTTPS, para hosts que o plugin declara e você aprova um a um em Configurações → Plugins, sem cookies, token nem cabeçalhos do Discord. Nada sai antes de você aprovar. Um plugin com a capacidade `links` também pode abrir um endereço no navegador, quando você clica em algo dele, e o cartão dele diz isso.
- Os dados de um plugin ficam em `~/.config/sigmacord/plugin-data/`, separados por plugin e por conta, e só você lê. Os plugins que vêm com o app não guardam o texto de mensagens depois que elas são apagadas.

Os detalhes estão em [Plugins em Lua](page:plugins).

## Modo streamer

Esconde o seu e-mail e o seu nome de usuário nas configurações. Não esconde mais nada na tela.

## Relatando um problema

Abra uma issue no [GitHub](https://github.com/sambukuper/SigmaCord/issues). Se o problema envolve vazamento de token ou qualquer coisa sensível, não inclua tokens reais no relato.

## Se o Discord bloquear a sua conta

O Discord desativa contas ou força a troca de senha quando acha que a conta é um bot de spam ou foi invadida. Isso pode acontecer em qualquer cliente, mas clientes de terceiros costumam disparar mais. Já aconteceu com quem desenvolve este projeto, depois de um dia de testes. **Use uma conta secundária.**

Estes são os gatilhos que as pessoas costumam relatar, então faça isso pelo cliente oficial:

- entrar ou sair de servidores, o mais comum
- desconectar e reconectar com frequência, o que inclui reiniciar o app várias vezes
- abrir DMs com pessoas novas
- mexer na lista de amigos
- editar o perfil enquanto estiver conectado aqui

Se acontecer, redefina a senha pelo discord.com. Se a conta continuar bloqueada, [faça uma apelação aqui](https://support.discord.com/hc/en-us/requests/new?ticket_form_id=360000029731). O Discord não publica essas regras, então a lista vem da experiência de quem faz clientes de terceiros.

## Se o seu antivírus reclamar

A versão para Windows não é assinada, então o SmartScreen avisa. Um antivírus também pode chamá-la de ladrão de token do Discord, provavelmente porque um cliente de Discord está cheio das mesmas palavras que um ladrão tem, como "token" e "Authorization". Um sandbox deu essa nota à versão 0.5.0 por causa de uma regra de padrões, e o relatório de comportamento dele não mostrou acesso a credenciais e, no modo de demonstração, nenhuma conexão.

O token só vai para o Discord e fica no chaveiro do sistema ou, sem chaveiro, num arquivo privado. O código é público, então dá para ler ou compilar você mesmo. Baixe o SigmaCord só deste repositório.
