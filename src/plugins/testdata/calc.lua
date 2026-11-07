-- calc.lua: calculadora. O sandbox não tem `load`, então a conta é lida à mão,
-- com um pequeno analisador recursivo: um bom modelo para plugins com sintaxe própria.
--   /calc 2 + 3 * 4      resposta só para você, num aviso
--   /conta (1 + 2) ^ 3   manda a conta e o resultado no canal
-- Entende + - * / % ^, parênteses, pi, sqrt(), abs(), floor(), ceil(), round()
-- e `ans` (o último resultado).
local ans = 0
local funcoes = {
  sqrt = math.sqrt,
  abs = math.abs,
  floor = math.floor,
  ceil = math.ceil,
  round = function(x) return math.floor(x + 0.5) end,
}

local function avaliar(texto)
  local i = 1
  local expressao

  local function pula()
    i = texto:find("%S", i) or #texto + 1
  end

  local function atomo()
    pula()
    local numero = texto:match("^%d+%.?%d*", i) or texto:match("^%.%d+", i)
    if numero then
      i = i + #numero
      return tonumber(numero)
    end
    if texto:sub(i, i) == "(" then
      i = i + 1
      local v = expressao()
      pula()
      if texto:sub(i, i) ~= ")" then error("faltou fechar o parêntese", 0) end
      i = i + 1
      return v
    end
    local nome = texto:match("^%a+", i)
    if not nome then error("não entendi a partir de \"" .. texto:sub(i) .. "\"", 0) end
    i = i + #nome
    if nome == "pi" then return math.pi end
    if nome == "ans" then return ans end
    local f = funcoes[nome]
    if not f then error("não conheço \"" .. nome .. "\"", 0) end
    return f(atomo())
  end

  local function unario()
    pula()
    if texto:sub(i, i) == "-" then
      i = i + 1
      return -unario()
    end
    local base = atomo()
    pula()
    if texto:sub(i, i) == "^" then
      i = i + 1
      return base ^ unario()
    end
    return base
  end

  local function termo()
    local v = unario()
    while true do
      pula()
      local op = texto:sub(i, i)
      if op ~= "*" and op ~= "/" and op ~= "%" then return v end
      i = i + 1
      local d = unario()
      if op ~= "*" and d == 0 then error("divisão por zero", 0) end
      if op == "*" then v = v * d elseif op == "/" then v = v / d else v = v % d end
    end
  end

  expressao = function()
    local v = termo()
    while true do
      pula()
      local op = texto:sub(i, i)
      if op ~= "+" and op ~= "-" then return v end
      i = i + 1
      if op == "+" then v = v + termo() else v = v - termo() end
    end
  end

  local v = expressao()
  pula()
  if i <= #texto then error("sobrou \"" .. texto:sub(i) .. "\"", 0) end
  return v
end

local function bonito(v)
  if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
  return (string.format("%.6f", v):gsub("0+$", ""):gsub("%.$", ""))
end

-- Devolve o resultado em texto, ou nil depois de avisar o que deu errado.
local function resolve(args)
  if args == "" then
    sigma.notify("Use assim: /calc 2 + 3 * 4")
    return nil
  end
  local ok, v = pcall(avaliar, args)
  if not ok then
    sigma.notify("Conta inválida: " .. tostring(v))
    return nil
  end
  ans = v
  return bonito(v)
end

sigma.command("/calc", function(args)
  local r = resolve(args)
  if r then sigma.notify(args .. " = " .. r) end
end)

sigma.command("/conta", function(args)
  local r = resolve(args)
  if r then sigma.send(nil, "`" .. args .. " = " .. r .. "`") end
end)
