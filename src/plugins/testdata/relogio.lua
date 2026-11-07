-- relogio.lua: que horas são em outro lugar, e um cronômetro.
--   /hora              sua hora e as principais cidades, num aviso
--   /hora tokyo        só aquela cidade
--   /horario lisboa    manda a hora de lá no canal
--   /cronometro        inicia; de novo, para e mostra o tempo (ou Ctrl+Alt+T)
-- Os fusos são fixos (sem horário de verão): ajuste a tabela para a sua turma.
local fusos = {
  { "são paulo", -3 }, { "lisboa", 0 }, { "londres", 0 }, { "paris", 1 },
  { "new york", -5 }, { "los angeles", -8 }, { "dubai", 4 }, { "tokyo", 9 },
  { "sydney", 10 },
}
local resumo = { "new york", "lisboa", "tokyo" }

local function achar(nome)
  nome = nome:lower()
  for _, f in ipairs(fusos) do
    if f[1] == nome or f[1]:find(nome, 1, true) == 1 then return f[1], f[2] end
  end
end

local function horaEm(fuso)
  return os.date("!%H:%M", os.time() + fuso * 3600)
end

sigma.command("/hora", function(args)
  if args == "" then
    local partes = { "aqui " .. os.date("%H:%M") }
    for _, nome in ipairs(resumo) do
      local cidade, fuso = achar(nome)
      partes[#partes + 1] = cidade .. " " .. horaEm(fuso)
    end
    sigma.notify(table.concat(partes, " · "))
    return
  end
  local cidade, fuso = achar(args)
  if cidade then
    sigma.notify(cidade .. ": " .. horaEm(fuso))
  else
    sigma.notify("Não conheço \"" .. args .. "\". Acrescente no começo de relogio.lua")
  end
end)

sigma.command("/horario", function(args)
  local cidade, fuso = achar(args)
  if not cidade then
    sigma.notify("Use assim: /horario tokyo")
    return
  end
  sigma.send(nil, "🕒 Agora em " .. cidade .. ": **" .. horaEm(fuso) .. "**")
end)

local inicio = nil

local function cronometro()
  if not inicio then
    inicio = os.time()
    sigma.notify("⏱ Cronômetro valendo")
    return
  end
  local total = os.time() - inicio
  inicio = nil
  sigma.notify(string.format("⏱ %d min %02d s", total // 60, total % 60))
end

sigma.command("/cronometro", cronometro)
sigma.keybind("ctrl+alt+t", cronometro)
