-- zoeira.lua: reescreve o texto antes de mandar.
--   /mock isso aqui      iSsO aQuI
--   /vapor aesthetic     ａｅｓｔｈｅｔｉｃ
--   /palmas isso sim     isso 👏 sim
--   /contrario abc       cba (entende acentos e emoji)
--   /spoiler o fim       ||o fim||
local function comando(nome, exemplo, transforma)
  sigma.command(nome, function(args)
    if args == "" then
      sigma.notify("Use assim: " .. nome .. " " .. exemplo)
      return
    end
    sigma.send(nil, transforma(args))
  end)
end

comando("/mock", "isso aqui", function(texto)
  local maiuscula = false
  return (texto:gsub("%a", function(letra)
    maiuscula = not maiuscula
    return maiuscula and letra:lower() or letra:upper()
  end))
end)

-- Letras "largas": mesmo caractere, deslocado na tabela Unicode.
comando("/vapor", "aesthetic", function(texto)
  local saida = {}
  for _, cp in utf8.codes(texto) do
    if cp >= 0x21 and cp <= 0x7E then cp = cp + 0xFEE0 end
    if cp == 0x20 then cp = 0x3000 end
    saida[#saida + 1] = utf8.char(cp)
  end
  return table.concat(saida)
end)

comando("/palmas", "isso sim", function(texto)
  return (texto:gsub("%s+", " 👏 "))
end)

comando("/contrario", "abc", function(texto)
  local saida = {}
  for _, cp in utf8.codes(texto) do table.insert(saida, 1, utf8.char(cp)) end
  return table.concat(saida)
end)

comando("/spoiler", "o fim do filme", function(texto)
  return "||" .. texto .. "||"
end)
