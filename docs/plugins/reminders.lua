-- @name Reminders
-- @name:pt Lembretes
-- @description /remind 10m call back, /remind tomorrow 9am pay the bill, /remind every day 8:30 standup, or "Remind me" on a message. Notifies you when it's time, including after a restart.
-- @description:pt /remind 10m ligar de volta, /remind amanhã 9h pagar a conta, /remind todo dia 8:30 reunião, ou "Lembrar" numa mensagem. Avisa na hora certa, mesmo depois de reabrir o app.
-- @version 1.1.0
-- @capabilities menu, panel, storage, timers, notify, messages

local tr = sigma.tr
local MAX = 200
local DAY = 86400
local list = sigma.storage.get("list") or {}
local recent = {}
local next_id = sigma.storage.get("next") or 1
local pending = nil -- a mensagem do "Lembrar", esperando o tempo
local timer = nil

local function save()
  sigma.storage.set("list", list)
  sigma.storage.set("next", next_id)
end

-- "10m", "1h30m", "2d", "45s", "90 min".
local units = { s = 1, seg = 1, sec = 1, m = 60, min = 60, h = 3600, d = DAY, dia = DAY, dias = DAY, day = DAY, days = DAY }

local function parse_time(s)
  local total, found = 0, false
  for n, unit in s:gmatch("(%d+)%s*(%a+)") do
    local mult = units[unit:lower()]
    if not mult then return nil end
    total = total + tonumber(n) * mult
    found = true
  end
  if found and total > 0 and total <= 366 * DAY then return total end
end

-- Um horário: "15:30", "15h30", "9am", "9:30pm". "15h" sozinho é ambíguo (daqui a 15
-- horas?), então só vale como horário depois de "às", "amanhã" ou "todo dia".
local function parse_clock(word, loose)
  local h, mi, ampm = word:match("^(%d%d?):(%d%d)([ap]?m?)$")
  if not h then h, mi = word:match("^(%d%d?)h(%d%d)$") end
  if not h then
    h, ampm = word:match("^(%d%d?)([ap]m)$")
    mi = "0"
  end
  if not h and loose then
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

local function at_clock(h, mi, day_offset)
  local d = os.date("*t")
  d.hour, d.min, d.sec = h, mi, 0
  d.day = d.day + day_offset
  return os.time(d)
end

local TOMORROW = { ["amanhã"] = true, amanha = true, tomorrow = true }
local TODAY = { hoje = true, today = true }
local AT = { ["às"] = true, as = true, at = true }

-- Devolve quando (segundos desde 1970), o resto do texto e se repete todo dia.
-- nil = não entendeu.
local function parse_when(args)
  local words = {}
  for w in args:gmatch("%S+") do words[#words + 1] = w end
  local i = 1
  local function low(k) return (words[k] or ""):lower() end
  local function rest(k) return table.concat(words, " ", k) end
  local daily = false
  if (low(1) == "todo" and low(2) == "dia") or (low(1) == "every" and low(2) == "day") then
    daily = true
    i = 3
  elseif low(1) == "diario" or low(1) == "diário" or low(1) == "daily" then
    daily = true
    i = 2
  end
  local day
  if TOMORROW[low(i)] then
    day = 1
    i = i + 1
  elseif TODAY[low(i)] then
    day = 0
    i = i + 1
  end
  local loose = daily or day ~= nil
  if AT[low(i)] then
    loose = true
    i = i + 1
  end
  local h, mi = parse_clock(low(i), loose)
  if h then
    local due = at_clock(h, mi, day or 0)
    if due <= os.time() then
      if day == 0 then return nil end
      due = due + DAY
    end
    return due, rest(i + 1), daily
  end
  if loose then
    -- "amanhã" sozinho: a esta mesma hora.
    if day == 1 and not daily then return os.time() + DAY, rest(i), false end
    return nil
  end
  local seconds = parse_time(low(i))
  if not seconds then return nil end
  i = i + 1
  -- "1h 30m": o tempo pode vir em dois pedaços.
  if low(i):match("^%d+%a+$") and parse_time(low(i)) then
    seconds = seconds + parse_time(low(i))
    i = i + 1
  end
  return os.time() + seconds, rest(i), false
end

local function when(t)
  if os.date("%Y%m%d", t) == os.date("%Y%m%d") then return os.date("%H:%M", t) end
  return os.date(sigma.lang() == "pt" and "%d/%m %H:%M" or "%b %d %H:%M", t)
end

local render
local arm

local function fire(r, late)
  local text = r.text ~= "" and r.text or tr("Lembrete", "Reminder")
  if late then text = text .. tr(" (atrasado)", " (late)") end
  -- Foi a própria pessoa que pediu: aparece mesmo com a janela em foco.
  sigma.notify("⏰ " .. text, { desktop = true })
  table.insert(recent, 1, r)
  recent[11] = nil
end

local function by_due(a, b) return a.due < b.due end

local function check(late)
  local now = os.time()
  local i, fired = 1, false
  local again = {}
  while i <= #list do
    if list[i].due <= now then
      local r = table.remove(list, i)
      fire(r, late)
      fired = true
      if r.daily then
        -- Volta na próxima vez, sem correr atrás dos dias em que o app ficou fechado.
        local nxt = r.due + DAY
        while nxt <= now do nxt = nxt + DAY end
        again[#again + 1] = { id = r.id, due = nxt, text = r.text, daily = true, channel = r.channel, message = r.message }
      end
    else
      i = i + 1
    end
  end
  for _, r in ipairs(again) do list[#list + 1] = r end
  if #again > 0 then table.sort(list, by_due) end
  if fired then save() end
  arm()
  render()
end

-- Um temporizador só, para o próximo que vence.
arm = function()
  if timer then sigma.cancel(timer) end
  timer = nil
  local nearest
  for _, r in ipairs(list) do
    if not nearest or r.due < nearest then nearest = r.due end
  end
  if nearest then
    timer = sigma.after(math.max(nearest - os.time(), 0), function() check(false) end)
  end
end

local function add_at(due, text, channel, message, daily)
  if #list >= MAX then
    sigma.notify(tr("Lembretes demais: até 200", "Too many reminders: up to 200"))
    return false
  end
  local r = { id = next_id, due = due, text = text, channel = channel, message = message, daily = daily or nil }
  next_id = next_id + 1
  list[#list + 1] = r
  table.sort(list, by_due)
  save()
  arm()
  render()
  sigma.notify(tr("Vou lembrar às ", "I'll remind you at ") .. when(r.due))
  return true
end

local function add(seconds, text, m)
  return add_at(os.time() + seconds, text, m and m.channel.id, m and m.id)
end

local function cancel(id)
  for i, r in ipairs(list) do
    if r.id == id then
      table.remove(list, i)
      save()
      arm()
      render()
      return
    end
  end
end

local function row(r, past)
  local title = r.text ~= "" and r.text or tr("Lembrete", "Reminder")
  if r.daily then title = "🔁 " .. title end
  local actions
  if past then
    actions = { { label = tr("Mais 10 min", "10 more min"), key = "snooze" .. r.id, on_click = function()
      add_at(os.time() + 600, r.text, r.channel, r.message)
    end } }
  else
    actions = { { label = tr("Cancelar", "Cancel"), style = "danger", key = "cancel" .. r.id, on_click = function() cancel(r.id) end } }
  end
  return {
    title = title,
    subtitle = r.message and tr("Clique para ir até a mensagem", "Click to go to the message") or "",
    meta = when(r.due),
    key = (past and "old" or "r") .. r.id,
    on_click = r.message and function() sigma.jump(r.channel, r.message) end or nil,
    actions = actions,
  }
end

local function choose(seconds)
  local m = pending
  pending = nil
  add(seconds, m and m.text or "", m and m.msg or nil)
end

render = function()
  local tree = { title = tr("Lembretes", "Reminders") }
  if pending then
    tree[#tree + 1] = { type = "heading", text = tr("Lembrar desta mensagem", "Remind me about this message") }
    tree[#tree + 1] = { type = "text", text = pending.text, style = "muted" }
    tree[#tree + 1] = { type = "row",
      { type = "button", label = "10 min", key = "in10m", on_click = function() choose(600) end },
      { type = "button", label = "1 h", key = "in1h", on_click = function() choose(3600) end },
      { type = "button", label = "3 h", key = "in3h", on_click = function() choose(3 * 3600) end },
      { type = "button", label = tr("Amanhã", "Tomorrow"), key = "in1d", on_click = function() choose(DAY) end },
    }
    tree[#tree + 1] = { type = "input", key = "custom", placeholder = tr("Ou escreva: 20m, 1h30m, 15:30, amanhã 9h (Enter)", "Or type: 20m, 1h30m, 15:30, tomorrow 9am (Enter)"), clear = true,
      on_submit = function(v)
        local due = parse_when(v)
        -- "90 min": com o espaço.
        local span = not due and parse_time(v)
        if span then due = os.time() + span end
        if due then
          local m = pending
          pending = nil
          add_at(due, m and m.text or "", m and m.msg.channel.id, m and m.msg.id)
        else
          sigma.notify(tr("Não entendi esse tempo", "I didn't get that time"))
        end
      end }
    tree[#tree + 1] = { type = "row",
      { type = "button", label = tr("Deixar para lá", "Never mind"), key = "pending-off", on_click = function() pending = nil; render() end },
    }
    tree[#tree + 1] = { type = "separator" }
  end
  local items = {}
  for _, r in ipairs(list) do items[#items + 1] = row(r, false) end
  tree[#tree + 1] = { type = "list", key = "list", items = items,
    empty = tr("Nenhum lembrete. Use /remind 10m texto, ou botão direito numa mensagem.", "No reminders. Use /remind 10m text, or right-click a message.") }
  if #recent > 0 then
    tree[#tree + 1] = { type = "heading", text = tr("Já avisados", "Already fired") }
    local old = {}
    for _, r in ipairs(recent) do old[#old + 1] = row(r, true) end
    tree[#tree + 1] = { type = "list", key = "recent", items = old }
  end
  sigma.panel.set(tree)
end

sigma.command("/remind", function(args)
  local due, text, daily = parse_when(args)
  if not due then
    sigma.notify(tr("Use assim: /remind 10m ligar de volta", "Use it like this: /remind 10m call back"))
    return
  end
  add_at(due, text or "", nil, nil, daily)
end)

sigma.command("/reminders", function()
  render()
  sigma.panel.open()
end)

local function summary(m)
  local text = m.content:gsub("%s+", " ")
  if #text > 120 then
    local cut = 120
    while cut > 0 and (text:byte(cut + 1) or 0) & 0xC0 == 0x80 do cut = cut - 1 end
    text = text:sub(1, cut) .. "…"
  end
  return m.author.name .. ": " .. text
end

sigma.menu("message", { pt = "Lembrar desta mensagem", en = "Remind me" }, function(m, choice)
  local seconds = tonumber(choice)
  if seconds then
    add(seconds, summary(m), m)
  else
    pending = { text = summary(m), msg = m }
    render()
    sigma.panel.open()
  end
end, { choices = {
  { value = "600", pt = "Em 10 minutos", en = "In 10 minutes" },
  { value = "3600", pt = "Em 1 hora", en = "In 1 hour" },
  { value = "10800", pt = "Em 3 horas", en = "In 3 hours" },
  { value = "86400", pt = "Amanhã", en = "Tomorrow" },
  { value = "custom", pt = "Outro tempo…", en = "Other time…" },
} })

-- Se a mensagem foi apagada, o lembrete fica, sem o texto dela.
sigma.on("delete", function(d)
  local changed = false
  for _, r in ipairs(list) do
    if r.message == d.id then
      r.text = tr("(a mensagem foi apagada)", "(the message was deleted)")
      r.message = nil
      changed = true
    end
  end
  if changed then
    save()
    render()
  end
end)

sigma.on("lang", function() render() end)

-- O que venceu com o app fechado avisa agora.
check(true)
