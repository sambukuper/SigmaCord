-- alerta.lua: avisa quando alguém escreve uma das palavras abaixo.
-- Só avisa (sigma.notify); nunca responde sozinho.
local palavras = { "urgente", "socorro", "sigmacord" }

sigma.on("message", function(msg)
  if msg.mine then return end
  local texto = msg.content:lower()
  for _, palavra in ipairs(palavras) do
    if texto:find(palavra, 1, true) then
      local onde = msg.guild and ("#" .. msg.channel.name .. " em " .. msg.guild.name) or "DM"
      sigma.notify(msg.author.name .. " falou \"" .. palavra .. "\" (" .. onde .. ")")
      return
    end
  end
end)
