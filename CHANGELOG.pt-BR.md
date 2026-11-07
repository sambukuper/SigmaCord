# O que mudou em cada versão

## 0.7.0

**SigmaCord**
- Esta é a primeira versão com o nome SigmaCord. Tudo foi renomeado: a janela, a bandeja, o instalador, o binário (`sigmacord`), a pasta de configurações (`~/.config/sigmacord`, antes `~/.config/larpercord`), as variáveis de ambiente (`SIGMACORD_TOKEN`, antes `LARPER_TOKEN`) e a API dos plugins (`sigma.notify`, `sigma.send` e companhia, antes `larper.*`). Mova a pasta antiga `~/.config/larpercord` para `~/.config/sigmacord` para manter suas configurações, temas e plugins.

**Atalhos**
- Atalhos configuráveis: Configurações → Atalhos de teclado lista cada ação com a tecla dela; clicar e apertar outra combinação troca, e o × ao lado volta ao padrão. Se a tecla já era de outra ação, ela sai de lá.
- O mudo do microfone e o ensurdecer finalmente têm teclas, `Ctrl+Shift+M` e `Ctrl+Shift+D`, e os dois trocam como todo o resto.
- A paleta de comandos, a busca, as configurações, a tela cheia, o próximo tema, a caixa de entrada, as mensagens salvas e as ações de aba estão na mesma lista. Os fixos (Ctrl+Shift+P, zoom da interface, Alt+1…9, Alt+Enter) continuam como eram.
- A regra é a mesma que os plugins já tinham: letras e números pedem Ctrl, Alt ou Super, F1–F24 podem ir sozinhas, e enquanto você digita numa caixa de texto só atalhos com modificador disparam.

**Builds**
- Os dois binários das releases agora saem do GitHub Actions: o Linux portável e o Windows cruzado, cada um com atestado de build. Nada mais é compilado daqui; o script da release só baixa, confere e assina.

## 0.6.1

**Mais idiomas e telas**
- A interface tem versão em japonês, de nakayama900. Texto ainda sem tradução aparece em inglês.
- Texto em japonês, coreano e chinês agora aparece. As fontes só carregam quando uma letra precisa delas, e o idioma da interface escolhe a forma das letras.
- A interface segue a escala da tela no Windows e no X11, de Davyd Khanin. Ela não fica mais minúscula em 125% ou 150%.
- Configurações → Aparência tem o tamanho da interface, de 75 a 200%, e Ctrl + , Ctrl - e Ctrl 0 mudam de qualquer lugar.
- F11 e Alt+Enter ligam e desligam a tela cheia.
- Nomes de canais e pessoas em letras estilizadas (𝗠𝗲𝗺𝗲𝘀, ʀᴇɢʀᴀs) aparecem em letras comuns quando nenhuma fonte tem o desenho, em vez de `??????`. Configurações → Avançado lista as escritas que continuam sem fonte.

**Mais nítido**
- O texto pequeno ficou nítido. Tamanhos como 13,5 eram gerados em 14 e encolhidos como imagem, o que borrava quase todo texto cinza.
- O texto também encaixa nos pixels da tela em tamanhos como 125%.
- O texto secundário tem contraste mínimo em todos os temas, inclusive os da comunidade.
- Configurações → Avançado → Texto muda o peso do texto e como as letras encaixam nos pixels, na hora.
- Avatares, ícones e imagens ficam guardados no tamanho em que aparecem e são reduzidos com um filtro melhor. Antes, uma foto de 128 px era encolhida pela placa de vídeo sem filtro, o que serrilhava. Isso também gasta menos memória.
- As imagens não saem mais esticadas nem cortadas nas mensagens, nos embeds e na tela cheia, inclusive depois de redimensionar a janela.

**Chamadas**
- Corrigidas as rajadas de ruído alto, de Davyd Khanin. Alguns pacotes de voz vêm com padding, e o app mandava esses pacotes ainda cifrados para o decodificador.
- O começo de uma frase depois de uma pausa não sai mais alto do que deveria. Os quadros de silêncio agora passam pelo decodificador, e ele recomeça depois de uma pausa ou de um buraco grande.
- Configurações → Avançado tem um registro de depuração: ligue, faça o problema acontecer e mande o arquivo, sem terminal. Ele também anota saltos de volume e quantos pacotes vieram com padding.

**Novidades**
- A busca tem um painel lateral com filtros, ordem e páginas. Digitando, ela procura neste computador, e com Enter, no Discord.
- Encaminhar uma mensagem para outro canal.
- Entrar em um servidor por link ou código, e criar e editar convites nos menus do servidor e do canal.
- Seletor de GIFs ao lado do botão de emoji: em alta, busca e seus favoritos do Discord. O GIF anima com o mouse em cima.
- Copiar a imagem na tela cheia, e ampliar com a roda do mouse. Ctrl+V cola PNG, BMP, JPEG, GIF e WebP.
- Sair de um servidor pelo menu dele, com confirmação.
- O painel de mensagens fixadas mostra imagens, vídeos e prévias de link.
- Configurações → Chat pode baixar o FFmpeg no Windows para os vídeos tocarem no app, com aviso antes e SHA-256 conferido.
- Configurações → Desempenho tem limites para imagens, cada GIF e mensagens na memória.

**Correções**
- Quem está invisível não aparece mais online por um instante ao abrir o app. O status agora vai já na primeira conexão.
- Reconectar ficou mais calmo: uma conexão só conta como boa depois de um minuto. Um servidor que aceita e derruba não vira mais uma nova tentativa de login a cada poucos segundos.
- Segurar Shift+J ou Shift+K no modo Vim não varre mais os canais.
- Arrastar a barra de rolagem das mensagens não trava mais quando o mouse escapa dela ou quando mensagens antigas carregam.
- Um GIF que declara um tamanho enorme é recusado antes de decodificar, de svindler, para um arquivo pequeno não acabar com a sua memória.
- Temas sem o painel do usuário, como o Zen, têm um botão de configurações no cabeçalho.
- Instalado por um gerenciador de pacotes, o app avisa para atualizar por ele.

**Projeto**
- O SigmaCord agora usa a licença GPL-3.0.

## 0.6.0

**Plugins**
- A tradução agora tem opções: idioma de destino e de origem no cartão em Configurações → Plugins, e "Traduzir para…" no botão direito para uma mensagem só. Um 🌐 na barra da mensagem, e `/tr es olá` põe uma tradução na caixa de mensagem.
- Anti-golpe marca em vermelho os golpes clássicos de Discord nas mensagens dos outros: endereços que imitam o Discord ou a Steam, Nitro grátis falso com link, links encurtados com isca. Roda no seu computador, sem rede, e endereços oficiais nunca são marcados.
- Radar de CVE acha `CVE-2021-44228` nas mensagens e mostra embaixo a severidade, a nota CVSS e um resumo, do registro oficial. Cada número é pedido uma vez, e só depois de aprovar o host.
- Cartões do GitHub põem o título, o estado e as estrelas embaixo de `dono/repo#123` e de links do GitHub.
- O que perdi resume as mensagens não lidas de um canal: quantas de cada pessoa, menções a você, perguntas sem resposta, links e arquivos, com um clique até cada um.
- Também novos: Links limpos tira o rastreio dos links que você envia, e Links e arquivos lista o que foi compartilhado no canal.
- Lembretes entendem hora e data (`/remind amanhã 9h`, `/remind todo dia 8:30`), têm uma segunda lista no botão direito, e o que já avisou pode voltar em 10 minutos.
- Destaques mostra quantos você não viu, silencia um canal, acompanha edições e pode usar as notificações do sistema.
- Favoritos, o filtro de palavras, trechos, horários, estatísticas e os plugins de demonstração não vêm mais com o app: os dois primeiros viraram funções do próprio app. Quem tem continua usando, e um botão arquiva em `plugins/antigos/`. Nada é apagado.
- Um plugin incluído com versão nova mostra um botão de atualizar no cartão, e guarda o seu arquivo como `.bak`.
- Novo para quem faz plugins: opções no cartão (`sigma.settings`, `select`, `toggle`), segunda lista e botão na barra nos menus, sugestões na caixa de mensagem (`sigma.completions`), regras para o que você envia (`sigma.rewrite`), `sigma.copy`, `sigma.open`, um número na etiqueta do painel, notas em vermelho, os eventos `edit`, `dismiss` e `hosts`, um filtro `contains` que mantém as mensagens longe do Lua, e anexos, respostas, menções e a posição de leitura em `sigma.messages`.
- Um plugin atrasado perde mensagens em vez de segurar os outros, e o cartão dele diz isso. Cada plugin tem o próprio limite de notificações do sistema: um barulhento não come o aviso de um lembrete.
- O cartão avisa quando um plugin lê mensagens e também consegue mandar algo para fora.
- Fechar uma tradução com o × não faz mais o próximo "Traduzir" não fazer nada.

**Mensagens**
- Horários `<t:…>` aparecem como uma data ou "em 2 horas", no seu fuso, em vez do código.
- Em cima de um link, o cursor vira a mãozinha. A seleção de texto estava passando por cima dela.
- Arrastar a barra de rolagem das mensagens não seleciona mais o texto, e a alça de redimensionar não cobre mais a barra.
- Marcar como lida e como não lida agora sempre chega ao Discord. Com o status invisível, ficava só no seu computador e voltava na próxima conexão. O status não impede mais a confirmação de leitura; com a janela sem foco, ela continua não indo sozinha.

**Mais leve**
- Quadro que sai igual ao anterior não é desenhado de novo, então eventos da rede que não mudam nada na tela custam menos.
- Mexer o mouse sem botão apertado pede menos quadros.
- Depois de um minuto na bandeja ou minimizada, as imagens saem da memória, menos as pequenas que estavam na tela.
- Configurações → Desempenho mostra para onde vai a memória: imagens, mensagens, pessoas, servidores, fontes, driver e bibliotecas.

**Contas**
- A tela de login mostra todas as contas salvas como botões, venha de onde vier, com um aviso para usar conta secundária antes de colar um token.
- Quando o Discord recusa um token, o app esquece esse token em vez de tentar de novo a cada abertura. Se a sessão acabar com o app aberto, ele volta para a tela de login.

**Instalação**
- O download para Linux roda em distros de 2022 para cá (glibc 2.34), e não exige mais uma bem recente. SDL3, libcurl e OpenSSL agora vêm dentro dele, então o arquivo foi de cerca de 7 MB para cerca de 15 MB.
- O GitHub Actions compila o arquivo para Linux, abre em Ubuntu, Debian, Fedora, openSUSE e Arch, e publica um atestado que dá para conferir com `gh attestation verify`.
- O instalador do Linux dá ao atalho o ID da janela, para as barras que procuram o ícone desse jeito acharem. Rodar de novo troca o atalho antigo.

## 0.5.0

**Windows**
- O SigmaCord agora roda no Windows 10 e 11, a partir do mesmo código.
- Os tokens ficam no Gerenciador de Credenciais do Windows.

**Atualizações**
- Verifica se há versão nova ao abrir ou em Configurações → Atualizações.
- Um botão baixa, instala e reinicia. As atualizações são assinadas, e uma versão sem a assinatura certa não é instalada.
- Botão de reiniciar nas Configurações, e esta página.

**Voz**
- Supressão de ruído no microfone com RNNoise, ligada por padrão e trocável em plena call. Não roda com a tecla do aperte para falar solta.
- Menos engasgos e nada de estalos quando um pacote se perde ou chega fora de ordem; a folga de áudio cresce quando a rede engasga.
- As pessoas não somem mais por um instante quando alguém entra ou sai da call.
- Quando a rede trava, a voz se apaga em vez de cortar no meio da palavra, e volta sem estalo.
- A pausa da porta de ruído de alguém não é mais tratada como rede ruim, o que mantém o atraso do áudio baixo.
- A supressão de ruído usa menos CPU nas versões publicadas: ela escolhe o caminho mais rápido para o seu processador ao rodar.

**Bandeja**
- Fechar e reabrir não empilha mais ícones na bandeja. No Linux o ícone fica num processo pequeno à parte, que só existe com a janela escondida, e o GTK fica fora do app.

**Layout**
- Arraste a borda da lista de canais, da lista de membros ou dos painéis da tela dividida para mudar a largura. Duplo clique volta à largura do tema, e a sua escolha fica salva e vale nos outros temas.
- Conversa estreita continua funcionando: a caixa de busca sai antes dos botões.

**Mensagens**
- Etiqueta BOT ao lado do nome de bots e webhooks, com um ✓ nos bots verificados, nas mensagens, na lista de membros, nas DMs e nos perfis.
- Mensagens de webhook ficam com o nome e a foto com que cada uma foi enviada.
- Mensagens de bot no formato novo de componentes, que apareciam em branco. Encaminhadas e enquetes aparecem como cartões.
- O texto de embeds pode ser selecionado e copiado.
- Markdown do Discord: títulos, texto pequeno, citações, listas e links `[texto](url)`. Número de linha nos blocos de código.
- A seleção de texto dentro de um bloco de código agora aparece.
- Esc cancela a edição de uma mensagem.
- Botão direito ou do meio não dispara mais o clique normal de um botão. Na barra de ações da mensagem, por exemplo, ele adicionava a reação.
- Erros no código enquanto digita um bloco, opcional, com o servidor de linguagem que você escolher.

**Servidores e grupos**
- Editar um servidor (nome, descrição, ícone, banner) ou um grupo de DM (nome, ícone).
- Excluir threads.
- Banner do servidor no topo da lista de canais e nos cartões de convite.
- Clique no banner de um servidor para ver a imagem inteira, e o mesmo no banner de um perfil. Os menus do servidor e da pessoa também abrem o ícone ou a foto.
- Ícones de amigos, de grupo e do alfinete redesenhados.

**Plugins**
- Os plugins agora rodam numa thread só deles: um lento ou travado não engasga a interface, e é parado com o erro no cartão. Sem plugin ligado, a thread nem existe e nenhum Lua é carregado.
- Plugins novos que vêm com o app: favoritos, lembretes, destaques, filtro local, trechos, tradução e estatísticas do canal. Configurações → Plugins instala, sem mexer nos seus arquivos.
- Configurações → Plugins mostra um cartão para cada plugin, a partir de um cabeçalho no começo do arquivo: nome, descrição, versão, o que ele pede, erros e um jeito de abrir o painel, mesmo desligado.
- O que os plugins podem fazer agora: painéis numa lateral que se encaixa de qualquer lado, entradas no botão direito de mensagens e pessoas, selos, notas e recolher com "mostrar" embaixo das mensagens, dados próprios, temporizadores, notificações do sistema, mensagens carregadas, pular para uma mensagem e pôr texto na caixa de mensagem.
- HTTPS opcional para plugins, só para os hosts que você aprovar um a um, sem cookies, token nem cabeçalhos do Discord.
- Os arquivos que já estavam na pasta de plugins continuam funcionando, e os exemplos das versões antigas não são apagados.

**Mais leve**
- Executável menor, abertura mais rápida e menos memória.

## 0.4.0

Primeira versão pública: conexão real com o Discord, voz com criptografia de ponta a ponta, threads e fóruns, leitura sincronizada, busca, plugins em Lua e 11 temas.
