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
api.runtime.onMessage.addListener((msg, sender, reply) => {
  if (msg === "count") { update().then(n => reply(n), e => reply("error: " + e)); return true; }
});
update();
