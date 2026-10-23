const api = globalThis.browser ?? globalThis.chrome;
async function update() {
  const tabs = await api.tabs.query({});
  await api.action.setBadgeText({ text: String(tabs.length) });
  return tabs.length;
}
api.tabs.onCreated.addListener(update);
api.tabs.onRemoved.addListener(update);
api.tabs.onActivated.addListener(update);
api.tabs.onUpdated.addListener(update);
// Reply with a promise: newer WebKit resolves sendMessage with undefined when
// a listener uses the `reply` callback and returns true.
api.runtime.onMessage.addListener(msg => {
  if (msg === "count") return update().catch(e => "error: " + e);
});
update();
