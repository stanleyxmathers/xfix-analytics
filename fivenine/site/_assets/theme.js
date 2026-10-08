// Тема до отрисовки страницы. Выбор хранится в fn-theme (light | dark | system),
// итоговая тема дублируется в xfix-theme — её читают дашборды.
(function () {
  var pref = 'light';
  try { pref = localStorage.getItem('fn-theme') || localStorage.getItem('xfix-theme') || 'light'; } catch (e) {}
  var dark = pref === 'dark' || (pref === 'system' && window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches);
  var t = dark ? 'dark' : 'light';
  document.documentElement.setAttribute('data-theme', t);
  try { localStorage.setItem('xfix-theme', t); } catch (e) {}
})();
