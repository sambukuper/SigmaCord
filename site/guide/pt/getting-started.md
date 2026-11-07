# Primeiros passos

O SigmaCord é um cliente de Discord nativo para Linux e Windows, escrito em Zig. Você pode rodar sem conta: `--demo` abre o **modo demonstração**, com servidores e pessoas falsos, sem conectar em nada. Sem token configurado, o app abre a tela de login, que também oferece a demonstração.

> [!WARNING]
> **Clientes de terceiros violam os Termos de Uso do Discord**, e a sua conta pode ser banida. Use uma conta real por sua conta e risco, de preferência uma secundária. Este projeto não tem relação com a Discord Inc.

## O que você precisa

| | |
|---|---|
| Sistema operacional | Linux (testado todo dia no Arch com Hyprland) ou Windows 10/11 |
| Compilador | Zig 0.17 |
| Bibliotecas | SDL3, FreeType, fontconfig, libcurl (com suporte a WebSocket, 7.86 ou mais nova), zlib, libwebp, Opus, OpenSSL |
| Fontes recomendadas | Inter, JetBrains Mono e Noto Color Emoji. O fontconfig escolhe substitutas se faltar alguma |
| Opcional | FFmpeg 7, 8 ou 9 (libavformat 61–63) para tocar vídeo dentro do app. Qualquer outra versão é ignorada e os vídeos abrem no navegador |

## Instalar

**Baixar:** [Linux](https://github.com/sambukuper/SigmaCord/releases/latest/download/sigmacord-linux-x86_64) · [Windows](https://github.com/sambukuper/SigmaCord/releases/latest/download/sigmacord-windows-x86_64.zip) · [todas as versões](https://github.com/sambukuper/SigmaCord/releases). No Linux, marque o arquivo com `chmod +x` e rode. No Windows, descompacte e abra o `sigmacord.exe`; ele ainda não tem assinatura de código, então o Windows pode avisar na primeira vez.

A versão para Linux roda em distros de 2022 para cá (glibc 2.34 ou mais nova). SDL3, libcurl e OpenSSL vêm dentro dela. FreeType, fontconfig, libwebp, Opus e zlib vêm do sistema, e uma distro de desktop costuma já ter. Antes de cada versão, ela é aberta em contêineres de Ubuntu 22.04 e 24.04, Debian 12 e 13, Fedora, openSUSE e Arch, na demonstração e sem GPU.

O GitHub Actions compila esse arquivo a partir do código deste repositório. Com o GitHub CLI dá para conferir: `gh attestation verify sigmacord-linux-x86_64 --repo sambukuper/SigmaCord`.

Ou use um script:

No Linux (em `~/.local`, sem sudo):

```bash
curl -fsSL https://raw.githubusercontent.com/sambukuper/SigmaCord/main/install.sh | sh
```

No Windows, no PowerShell (para o seu usuário, sem administrador):

```powershell
irm https://raw.githubusercontent.com/sambukuper/SigmaCord/main/install.ps1 | iex
```

Os dois conferem o download com o `SHA256SUMS`. No Linux o script lista as bibliotecas do sistema que faltam. Depois disso o app se atualiza em Configurações → Atualizações.

A tabela acima vale para quem compila do código, abaixo.

## Compilar e rodar

```bash
# Arch Linux
sudo pacman -S zig sdl3 freetype2 fontconfig curl zlib libwebp opus openssl \
    inter-font ttf-jetbrains-mono noto-fonts-emoji

git clone https://github.com/sambukuper/SigmaCord
cd SigmaCord

zig build -Doptimize=ReleaseFast
./zig-out/bin/sigmacord --demo
```

O resto já está no repositório: Dear ImGui, Lua, stb_image, libdave, MLSpp e nlohmann/json estão copiados em `third_party/`, então o build não baixa nada.

## Seus primeiros cinco minutos

1. Aperte `F2` algumas vezes. Cada toque troca o arquivo de tema inteiro.
2. Aperte `Ctrl+K` e digite `tema`, ou o nome de um canal. Essa é a paleta de comandos, e quase tudo está nela.
3. Aperte `Ctrl+,` para abrir as configurações. Olhe a página Aparência, onde cada tema tem as próprias opções.
4. Clique com o botão direito numa mensagem, num usuário, num canal e num servidor. Tudo tem um menu.
5. Copie um tema e edite com o app aberto:

```bash
mkdir -p ~/.config/sigmacord/themes
cp themes/orbital.kdl ~/.config/sigmacord/themes/mine.kdl
$EDITOR ~/.config/sigmacord/themes/mine.kdl
```

Troque a linha `theme "orbital"` por `theme "mine"`, escolha-o com `F2` ou na paleta, e cada salvamento recarrega a janela. Se você errar, um aviso mostra `arquivo:linha:coluna` e a versão anterior continua na tela. [Escrevendo temas](page:themes) tem a linguagem inteira.

## Próximos passos

- [Conectar a sua conta](page:account), se você aceita o risco.
- [Tour de recursos](page:features), para ver o que tem lá dentro.
- [Atalhos e linha de comando](page:shortcuts), com todas as teclas e opções.
