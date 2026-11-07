// Aplica o tema antes do primeiro desenho, para a página não piscar.
(function () {
  var name = "sigma", mode = "dark";
  try {
    name = localStorage.getItem("lc-theme") || name;
    mode = localStorage.getItem("lc-mode") || mode;
  } catch (e) {}
  var data = window.LC_DATA;
  if (!data.themes[name]) name = "sigma";
  if (mode !== "light") mode = "dark";
  window.LC_apply = function (n, m) {
    var t = data.themes[n], root = document.documentElement, toks = t[m];
    for (var k in toks) root.style.setProperty("--" + k, toks[k]);
    root.style.setProperty("--radius", (t.radius === 0 ? 0 : Math.max(t.radius - 2, 2)) + "px");
    root.dataset.theme = n;
    root.dataset.mode = m;
    root.dataset.display = t.display;
    root.dataset.fx = t.fx;
  };
  window.LC_apply(name, mode);
  try {
    var fx = /[?&]fx=(lite|full)/.exec(location.search);
    if (fx) window.LC_fx = fx[1];
    else if (localStorage.getItem("lc-fx")) window.LC_fx = localStorage.getItem("lc-fx");
  } catch (e) {}
  if (window.LC_fx === "lite") document.documentElement.classList.add("lite");
})();
