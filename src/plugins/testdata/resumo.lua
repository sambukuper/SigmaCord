-- resumo.lua: quem mais falou e onde, desde que o app abriu. Tudo fica na memória
-- e nada sai daqui: só lê as mensagens e mostra um aviso para você.
--   /resumo         o resumo (ou Ctrl+Alt+R)
--   /resumo zerar   começa a contar de novo
local total, minhas = 0, 0
local pessoas, canais = {}, {}
local desde = os.time()

sigma.on("message", function(msg)
  total = total + 1
  if msg.mine then
    minhas = minhas + 1
  else
    pessoas[msg.author.name] = (pessoas[msg.author.name] or 0) + 1
  end
  canais[msg.channel.name] = (canais[msg.channel.name] or 0) + 1
end)

local function maior(contagem)
  local nome, n = nil, 0
  for k, v in pairs(contagem) do
    if v > n then nome, n = k, v end
  end
  return nome, n
end

local function mostra()
  if total == 0 then
    sigma.notify("Nenhuma mensagem nova desde que o app abriu")
    return
  end
  local minutos = math.max(1, (os.time() - desde) // 60)
  local partes = { string.format("%d mensagens em %d min (%d suas)", total, minutos, minhas) }
  local quem, n = maior(pessoas)
  if quem then partes[#partes + 1] = "quem mais falou: " .. quem .. " (" .. n .. ")" end
  local onde, m = maior(canais)
  if onde then partes[#partes + 1] = "#" .. onde .. " (" .. m .. ")" end
  sigma.notify(table.concat(partes, " · "))
end

sigma.command("/resumo", function(args)
  if args == "zerar" then
    total, minhas, pessoas, canais, desde = 0, 0, {}, {}, os.time()
    sigma.notify("Contagem zerada")
    return
  end
  mostra()
end)
sigma.keybind("ctrl+alt+r", mostra)
