# Conectar a sua conta

> [!WARNING]
> **Usar uma conta de usuário fora do cliente oficial viola os Termos de Uso do Discord, e a conta pode ser banida.** Use por sua conta e risco, de preferência com uma conta secundária. Nada neste projeto elimina esse risco.

## Como o app encontra o seu token

O token nunca fica no código, e nunca vai para logs nem mensagens de erro. Ele também é apagado da memória quando o app fecha. O app procura nesta ordem:

1. **O chaveiro do sistema** (recomendado):
   ```bash
   secret-tool store --label='SigmaCord' service sigmacord   # cole o token quando pedir
   ```
2. A variável de ambiente `SIGMACORD_TOKEN`.
3. O arquivo `~/.config/sigmacord/token`, que precisa ter `chmod 600`. Se outros usuários conseguirem ler, o app avisa.

## A tela de login

Sem token, o app abre a tela de login (`--login` força). Você pode colar um token ou escolher **Explorar o modo demonstração**, e a tela tem o próprio link de ajuda. Com **Lembrar neste computador** ligado, o token só é salvo depois que o Discord o aceita.

## Várias contas

Clique no seu próprio nome para abrir o menu de contas. Ele lista as contas guardadas com nome e foto, e a troca vale na hora. **Adicionar conta** volta à tela de login sem esquecer as outras.

A tela de login também lista as contas guardadas, então dá para entrar em outra se uma sessão acabar. Quando o Discord recusa um token, o app esquece esse token em vez de tentar de novo a cada abertura.

| O quê | Onde |
|---|---|
| Cada token lembrado | Uma entrada própria do chaveiro (`service sigmacord-account account <ID>`). Sem chaveiro: `~/.config/sigmacord/tokens/<ID>` com `chmod 600` |
| A lista de contas (só ID, nome e foto) | `~/.config/sigmacord/accounts` |

A entrada do chaveiro da primeira seção continua valendo para a conta que já estava nela.

## Sair

Configurações → **Sair**. Para forçar o modo demonstração mesmo com um token salvo, rode `sigmacord --demo`.

## O que passa pela rede

Com um token, o app fala com o gateway e a API REST do Discord, e com os servidores de mídia do Discord para as imagens. Veja [Privacidade e segurança](page:privacy) para os detalhes, incluindo o proxy opcional.
