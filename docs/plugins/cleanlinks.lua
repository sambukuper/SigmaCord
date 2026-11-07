-- @name Clean links
-- @name:pt Links limpos
-- @description Removes tracking from the links you send (utm_*, fbclid, YouTube's si, Spotify's si and the like), so the other person gets just the address. Fixed rules the app applies when you send: the plugin doesn't see what you write and uses nothing while you type.
-- @description:pt Tira o rastreio dos links que você envia (utm_*, fbclid, o si do YouTube e do Spotify e afins), e a outra pessoa recebe só o endereço. São regras fixas que o app aplica ao enviar: o plugin não vê o que você escreve e não gasta nada enquanto você digita.
-- @version 1.0.0
-- @capabilities rewrite

sigma.rewrite({
  -- Campanhas e anúncios, em qualquer site.
  { strip_params = { "utm_*", "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
    "igshid", "igsh", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsCtaTracking", "vero_id", "vero_conv",
    "oly_anon_id", "oly_enc_id", "wickedid", "rb_clickid", "s_cid", "mkt_tok" } },
  -- Quem compartilhou, em cada site. Só o que é rastreio: o `t` do YouTube é o minuto do vídeo.
  { host = "youtube.com", strip_params = { "si", "feature", "pp" } },
  { host = "youtu.be", strip_params = { "si", "feature" } },
  { host = "spotify.com", strip_params = { "si", "context", "nd", "dlsi" } },
  { host = "x.com", strip_params = { "s", "t", "ref_src", "ref_url" } },
  { host = "twitter.com", strip_params = { "s", "t", "ref_src", "ref_url" } },
  { host = "tiktok.com", strip_params = { "_t", "_r", "is_from_webapp", "sender_device", "sender_web_id", "share_app_id", "share_item_id", "share_link_id", "timestamp", "u_code", "user_id", "tt_from" } },
  { host = "reddit.com", strip_params = { "share_id", "ref", "ref_source", "rdt", "ref_campaign" } },
  { host = "facebook.com", strip_params = { "mibextid", "fref", "ref", "rdid", "share_url", "__tn__", "__cft__*" } },
  { host = "linkedin.com", strip_params = { "trk", "trackingId", "lipi", "licu", "midToken", "midSig", "refId" } },
  { host = "amazon.com", strip_params = { "ref", "ref_", "pd_rd_*", "pf_rd_*", "content-id", "qid", "sr", "dib", "dib_tag" } },
  { host = "amazon.com.br", strip_params = { "ref", "ref_", "pd_rd_*", "pf_rd_*", "content-id", "qid", "sr", "dib", "dib_tag" } },
  { host = "aliexpress.com", strip_params = { "spm", "scm", "algo_*", "aff_*", "sk", "terminal_id" } },
  { host = "mercadolivre.com.br", strip_params = { "tracking_id" } },
})
