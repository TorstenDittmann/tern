# Agent API

Coding agents and scripts can drive Tern through a local JSON-RPC API. It's off by default: turn it on with **Enable Agent API** in the command palette (⌘K), or `defaults write dev.tern.browser agentAPI -bool true`.

- It listens only on a Unix socket, `~/Library/Application Support/Tern/agent.sock`, created `0600`. Connections from other users are refused, and no network port is opened. `TERN_SOCKET` overrides the path.
- Messages are JSON-RPC 2.0, one object per line. Calls that load a page take `wait` (`none`, `load` or `idle`) and `timeoutMs`.
  - **Browser:** `tern.hello`, `tern.metrics`, `commands.list`, `commands.run`, `windows.list`, `windows.open`, `history.search`, `history.clear`, and `tabs.list`, `open`, `activate`, `close`, `navigate`, `back`, `forward`, `reload`, `split` (`tabIds` with an optional `layout`: `columns`, `rows` or `grid`) and `pin`.
  - **Page:** `page.snapshot` returns the page as a compact outline, with a ref such as `e12` on every element you can act on. `page.click`, `type`, `press`, `select` and `scroll` act on those refs. `page.text` returns text, Markdown or HTML, `page.eval` runs JavaScript, `page.waitFor` waits for text, a selector or a URL, `page.screenshot` saves a PNG, and `page.audit` runs basic accessibility checks.
  - **Logs:** `console.read` returns what a page logged, including uncaught errors and unhandled rejections. `network.list` returns its fetch and XHR requests with status and timing. Each tab keeps the last 500 of each, and `since` (the `last` of an earlier read) pages through newer entries, oldest first, `limit` at a time. `clear` drops everything up to the last entry a read returned.
  - **Events:** `events.subscribe` streams `tab.updated`, `console.message` and `network.request` to that connection as JSON-RPC notifications.
- Clicks and key presses are real macOS events when the tab is on screen, so pages see trusted input. Background tabs fall back to DOM events. The page-side code runs in a private script world that pages can't see.
- A tab an agent is acting on gets a purple ring and an "Agent is driving" tag.
- Console and network capture wrap the page's own `console`, `fetch` and `XMLHttpRequest`, and run only while the API is on. Pages opened before you turn it on are captured after their next load.
- Agents can act on any tab by default. `defaults write dev.tern.browser agentOwnTabsOnly -bool true` limits them to the tabs they opened, and leaves other tabs read-only.

The `tern` command-line tool ships inside the app. Link it onto your path once:

```sh
ln -s /Applications/Tern.app/Contents/Helpers/tern /usr/local/bin/tern
```

```sh
tern hello
tern tabs open localhost:3000 --wait idle
tern tabs list --plain
tern tabs navigate https://example.com --tabId <id>
tern page snapshot                           # the page as an outline with refs
tern page type e3 "ada@example.com" --submit true
tern page click e7
tern page eval "document.title"
tern page screenshot shot.png
tern console read --level error              # what the page logged
tern network list --failedOnly true          # failed fetch/XHR requests
tern events subscribe console.message        # stream events as JSON lines
tern run toggleSplit                         # any command name from `tern commands list`
tern call tabs.reload '{"wait":"none"}'      # any method, raw JSON params
```

## MCP

`tern mcp` is a [Model Context Protocol](https://modelcontextprotocol.io) server on stdin and stdout, so MCP clients get the API as tools without any glue. For Claude Code:

```sh
claude mcp add tern -- /Applications/Tern.app/Contents/Helpers/tern mcp
```

The tools mirror the methods: `tabs_list`, `tabs_open`, `tabs_navigate`, `page_snapshot`, `page_click`, `page_type`, `page_eval`, `page_screenshot` (returned as an image), `console_read`, `network_list` and the rest. Each call connects to the socket on its own, so restarting Tern doesn't break the MCP session. Failed calls come back as tool errors the model can read.
