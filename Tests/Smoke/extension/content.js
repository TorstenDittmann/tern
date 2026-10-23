const api = globalThis.browser ?? globalThis.chrome;
document.documentElement.dataset.ternExt = "injected";
api.runtime.sendMessage("count").then(
  n => { document.documentElement.dataset.ternCount = String(n); },
  e => { document.documentElement.dataset.ternCount = "error: " + e; }
);
