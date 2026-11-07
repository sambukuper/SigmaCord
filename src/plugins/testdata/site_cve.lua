-- O exemplo da página inicial do site (site/landing.html): os dois precisam ser iguais.
-- @name CVE notes
-- @capabilities messages, decorate, http
-- @hosts cveawg.mitre.org
sigma.on("message", function(msg)
  local id = msg.content:upper():match("CVE%-%d+%-%d+")
  if not id then return end
  sigma.http.get("https://cveawg.mitre.org/api/cve/" .. id, function(res)
    local cve = res.ok and sigma.json.decode(res.body)
    local cna = cve and cve.containers and cve.containers.cna
    if cna and cna.title then
      sigma.decorate(msg.id, { note = id .. ": " .. cna.title })
    end
  end)
end, { contains = { "cve-" } })
