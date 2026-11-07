-- @name Timestamps
-- @name:pt Horários
-- @description /ts tomorrow 3pm, /ts friday 20:00, /ts 12/25 8pm or /ts in 2h put a time in the message box that each person sees in their own time zone. Pick the format below. It never sends anything: you still press Enter.
-- @description:pt /ts amanhã 15h, /ts sexta 20h, /ts 25/12 20h ou /ts em 2h põem na caixa de mensagem um horário que cada pessoa vê no próprio fuso. O formato você escolhe aqui embaixo. Nunca envia nada: quem aperta Enter é você.
-- @version 1.0.0
-- @capabilities composer, settings, storage, notify

local tr = sigma.tr
local style = sigma.storage.get("style") or "f"

local DAY = 86400
local units = { s = 1, seg = 1, sec = 1, m = 60, min = 60, h = 3600, d = DAY, dia = DAY, dias = DAY, day = DAY, days = DAY }

-- "2h", "1h30m", "45min".
local function parse_span(word)
  local total, found = 0, false
  for n, unit in word:gmatch("(%d+)(%a+)") do
    local mult = units[unit]
    if not mult then return nil end
    total = total + tonumber(n) * mult
    found = true
  end
  return found and total or nil
end

-- "15h", "15h30", "15:30", "3pm", "3:30pm".
local function parse_clock(word)
  local h, mi, ampm = word:match("^(%d%d?):(%d%d)([ap]?m?)$")
  if not h then h, mi = word:match("^(%d%d?)h(%d%d)$") end
  if not h then
    h, ampm = word:match("^(%d%d?)([ap]m)$")
    mi = "0"
  end
  if not h then
    h = word:match("^(%d%d?)h$")
    mi = "0"
  end
  if not h then return nil end
  h, mi = tonumber(h), tonumber(mi)
  if ampm == "pm" and h < 12 then h = h + 12 end
  if ampm == "am" and h == 12 then h = 0 end
  if h > 23 or mi > 59 then return nil end
  return h, mi
end

-- 1 = domingo, como em os.date("*t").wday.
local WEEK = {
  domingo = 1, dom = 1, sunday = 1, sun = 1,
  segunda = 2, seg = 2, monday = 2, mon = 2,
  ["terça"] = 3, terca = 3, ter = 3, tuesday = 3, tue = 3,
  quarta = 4, qua = 4, wednesday = 4, wed = 4,
  quinta = 5, qui = 5, thursday = 5, thu = 5,
  sexta = 6, sex = 6, friday = 6, fri = 6,
  ["sábado"] = 7, sabado = 7, sab = 7, saturday = 7, sat = 7,
}

-- "25/12" ou "25/12/2027" (mês antes do dia com o app em inglês).
local function parse_date(word)
  local a, b, y = word:match("^(%d%d?)/(%d%d?)/?(%d*)$")
  if not a then return nil end
  a, b = tonumber(a), tonumber(b)
  local day, month = a, b
  if sigma.lang() == "en" then day, month = b, a end
  if month < 1 or month > 12 or day < 1 or day > 31 then return nil end
  return day, month, y ~= "" and tonumber(y) or nil
end

-- O horário pedido: nil = não entendeu.
local function parse(args)
  local words = {}
  for w in args:lower():gmatch("%S+") do words[#words + 1] = w end
  local now = os.time()
  if #words == 0 then return now end
  -- "em 2h", "in 2h", "+2h".
  local first = words[1]
  if first == "em" or first == "in" then
    local span = words[2] and parse_span(words[2])
    return span and now + span or nil
  end
  if first:sub(1, 1) == "+" then
    local span = parse_span(first:sub(2))
    return span and now + span or nil
  end
  local d = os.date("*t", now)
  local i = 1
  local dated = false
  if first == "amanhã" or first == "amanha" or first == "tomorrow" then
    d.day = d.day + 1
    dated = true
    i = 2
  elseif first == "hoje" or first == "today" then
    dated = true
    i = 2
  elseif WEEK[first] then
    d.day = d.day + (WEEK[first] - d.wday) % 7
    dated = true
    i = 2
  else
    local day, month, year = parse_date(first)
    if day then
      d.day, d.month = day, month
      if year then d.year = year < 100 and 2000 + year or year end
      dated = true
      i = 2
    end
  end
  local h, mi
  if words[i] then
    h, mi = parse_clock(words[i])
    if not h or words[i + 1] then return nil end
    d.hour, d.min, d.sec = h, mi, 0
  elseif not dated then
    return nil
  end
  local t = os.time(d)
  -- Só o horário, e ele já passou hoje: é amanhã. Uma data sem ano que já passou é a do ano que vem.
  if t <= now and not dated then t = t + DAY end
  if t <= now and WEEK[first] then t = t + 7 * DAY end
  if t <= now and first:find("/", 1, true) and not first:match("/%d+/") then
    d.year = d.year + 1
    t = os.time(d)
  end
  return t
end

sigma.command("/ts", function(args)
  local t = parse(args)
  if not t then
    sigma.notify(tr("Use assim: /ts amanhã 15h, /ts sexta 20h, /ts 25/12 20h ou /ts em 2h", "Use it like this: /ts tomorrow 3pm, /ts friday 20:00, /ts 12/25 8pm or /ts in 2h"))
    return
  end
  sigma.insert("<t:" .. t .. ":" .. style .. ">")
  sigma.notify(os.date(sigma.lang() == "pt" and "%d/%m/%Y %H:%M" or "%b %d %Y %H:%M", t))
end)

local function options()
  sigma.settings.set({
    { type = "select", key = "style", label = tr("Formato", "Format"), value = style,
      options = {
        { value = "f", label = tr("Data e hora", "Date and time") },
        { value = "F", label = tr("Dia da semana, data e hora", "Weekday, date and time") },
        { value = "t", label = tr("Só a hora", "Time only") },
        { value = "d", label = tr("Data curta", "Short date") },
        { value = "D", label = tr("Data por extenso", "Long date") },
        { value = "R", label = tr("Quanto falta (em 2 horas)", "Time left (in 2 hours)") },
      },
      on_change = function(v)
        style = v
        sigma.storage.set("style", v)
      end },
  })
end

sigma.on("lang", options)
options()
