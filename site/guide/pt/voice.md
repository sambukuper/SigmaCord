# Chamadas de voz

O SigmaCord entra em canais de voz de verdade do Discord, com criptografia de ponta a ponta. Tudo que é de voz roda numa thread própria, criada só quando você entra numa call. Fora de uma call, o módulo não usa CPU e o app não inicializa o áudio, a não ser que você abra Configurações → Voz, que lê o microfone para o medidor enquanto estiver aberta.

## Usando

Clique num canal de voz para entrar. O painel acima do seu usuário mostra a call, com mudo, ensurdecer e desconectar. Você também pode sair por "Sair da call", clicando com o botão direito no canal de voz. Quem está falando ganha um anel em volta do avatar.

O **mixer** dá a cada pessoa o próprio volume.

![O mixer da call](shot:f-voz)

O painel também mostra o ping, a qualidade da conexão por cor e quando você está transmitindo, e avisa se o microfone não abrir ou se o servidor te mutou ou ensurdeceu. Mudo e surdo dos outros aparecem na lista da call.

Os canais em que você não tem permissão para conectar aparecem com cadeado, e o app nem tenta.

## Configurações → Voz

- **Microfone e saída**: lembrados pelo nome, voltam ao padrão se sumirem, e dá para trocar no meio de uma call.
- **Volumes, nível do microfone ao vivo** e **Testar microfone**, que toca de volta o que você fala, com os filtros. Use fones.
- **Detecção de voz**: limiar ajustável sobre o medidor, ou **Sensibilidade automática**, que aprende o ruído de fundo.
- **Aperte para falar**: uma tecla ou um botão do mouse. Só funciona com a janela em foco, e o envio segue por um instante depois de soltar, para não cortar a última palavra.
- **Filtros**: um passa-altas que tira o ronco abaixo de 90 Hz e uma porta de ruído. Cada um pode ser desligado.
- **Supressão de ruído**: Desligada ou RNNoise, ligada por padrão e trocável em plena call. Roda no seu computador, atrasa o microfone em 20 ms e custa de 2% a 3,5% de um núcleo num Core i5 de 2011 com o microfone aberto, e menos em processadores mais novos. Desligada, no mudo ou com a tecla do aperte para falar solta, não custa nada.
- **Sons da call**: bipes curtos ao entrar, sair, mutar e desmutar, que podem ser desligados.

![A página de configurações de voz](shot:f-vozcfg)

## Como funciona

| Camada | O que usa |
|---|---|
| Sinalização | Gateway de voz v8 por WebSocket, com heartbeat (`seq_ack`) e RESUME quando a conexão cai |
| Conexão | IP discovery (pacote de 74 bytes) e Select Protocol por UDP |
| Criptografia de transporte | RTP com `aead_xchacha20_poly1305_rtpsize` |
| Criptografia de ponta a ponta | DAVE sobre MLS, pela libdave e pelo MLSpp |
| Codec | Opus a 48 kHz estéreo, 20 ms por pacote. Pacotes perdidos viram o packet-loss concealment do Opus |
| Áudio | O SDL3 mistura. Cada pessoa é um `SDL_AudioStream` no mesmo dispositivo de saída, e o volume dela é o ganho do stream. O microfone é um stream lido a cada 20 ms |

Alguns detalhes que deram trabalho para acertar:

- O opcode de "falando" (op 5) sai uma vez quando a sessão abre, e de novo ao retomar. Ele não liga e desliga a cada frase, porque assim o servidor descartava o começo de cada uma.
- O relógio do RTP continua andando com o tempo real enquanto você está calado, para quem recebe não descartar os seus pacotes depois de uma pausa.
- A folga contra o jitter só entra no começo de cada fala e dentro das pausas de quem fala. Aplicá-la sempre que a fila esvaziava causava buracos audíveis.
- O relógio RTP separa a pausa de quem fala de um pacote atrasado: o número de sequência só anda com pacote, o relógio anda sempre. A porta de ruído fechando não é rede ruim.
- Quando uma fila vai secar, a ocultação do Opus preenche e vai a zero, então uma parada nunca corta no meio da onda. Áudio que não continua de onde parou começa do último valor tocado.
- `zig build voz-rede` passa Opus de verdade por redes ruins simuladas e compara a lógica de reprodução, contando buracos e estalos. `SIGMACORD_VOZ_FALA` escolhe um arquivo de fala e `SIGMACORD_VOZ_WAV` grava a saída para ouvir.
- Quem já está numa call pode chegar antes de o DAVE existir, então essas pessoas são guardadas e adicionadas quando ele começa.

## Limites hoje

- O aperte para falar só funciona com a janela em foco, porque o SDL não tem atalho global portável.
- A supressão de ruído cuida de ruído constante. Teclado e pancadas podem passar, e outras vozes continuam.
- Sem compartilhamento de tela, câmera nem transmissão.
- Sem teste automático para uma call de verdade. O QA cobre a interface e as configurações, com um dispositivo de áudio falso.

## Depuração

```bash
SIGMACORD_VOICE_DEBUG=1 sigmacord
```

Isso imprime opcodes, códigos de fechamento e eventos do DAVE, além do nível do microfone e dos quadros enviados. Nunca imprime o token nem chaves.

Para testar só a conexão, o `--voice-test` entra num canal por 25 segundos, **sempre mudo**:

```bash
SIGMACORD_TOKEN=... sigmacord --voice-test GUILD_ID CHANNEL_ID
```

O protocolo segue a documentação de voz do Discord e a [documentação do protocolo DAVE](https://daveprotocol.com).
