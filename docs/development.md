# Development

## Build and run

Requirements: macOS 15.4 or later, Xcode 16.3 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
git clone https://github.com/TorstenDittmann/tern.git
cd tern
make run       # generate the Xcode project, build Debug, launch
make release   # optimized build: build/Build/Products/Release/Tern.app
make smoke     # end-to-end test (see below)
```

To work in Xcode, run `make project` and open `Tern.xcodeproj`. The project file is generated from `project.yml`, so edit that file rather than the Xcode project.

## Project layout

| Path | Contents |
|---|---|
| `Sources/Core` | WebKit setup (`BrowserEngine`), the `Tab` model (lazy web view, suspend and restore, downloads), session saving, and tab suspension |
| `Sources/UI` | Window controller (tabs and split view), sidebar, top bar and address field, content panes, command palette, theme, and the new-tab page |
| `Sources/Input` | Commands, chord parsing, and the keymap |
| `Sources/Agent` | The agent API: socket server, JSON-RPC dispatch, and the methods |
| `Sources/CLI` | The `tern` command-line client and MCP server, embedded at `Tern.app/Contents/Helpers/tern` |
| `Sources/Extensions` | Extension discovery and loading, and the bridges WebKit uses to see tabs and windows |
| `Sources/App` | App delegate, menus, the smoke test, and launch and memory metrics |
| `Scripts` | `bench.py`, which `make bench` runs |
| `site` | The landing page: a prerendered SvelteKit app, deployed with orch (`site/orch.pkl`) |
| `Tests/Smoke` | Local test pages and a small MV3 extension used by `make smoke` |

## Testing

`make smoke` builds Tern, serves `Tests/Smoke/site` on `localhost:8765`, and drives the real app with real windows and web views. It covers:

- key binding parsing and address-bar input
- opening, closing, and reordering tabs, and reopening closed ones
- suspending a tab and restoring it with its history
- split view
- an unpacked MV3 extension: content script injection, background messaging, `tabs.query`, and the badge
- the agent API, driven through the real `tern` CLI: opening, navigating, splitting and closing tabs, errors, `agentOwnTabsOnly`, and on a test form, snapshots, typing, selecting, clicking, key presses, eval, Markdown, the audit, screenshots and stale refs; console and network logs and the event stream; and `tern mcp` end to end

The test never touches your saved session or your extensions, and it exits non-zero on failure.

## Performance

- **Lazy tabs.** A restored tab is just a URL, a title, and WebKit's saved history state. A web view is created only when you open the tab, so restoring 200 tabs costs about as much as restoring one.
- **Tab suspension.** Background tabs idle for 15 minutes drop their web view and keep their history and scroll position. On a memory-pressure warning, every background tab is suspended. Tabs playing audio or using the camera or microphone are left alone, as are both halves of a visible split.
- **Shared WebKit state.** One data store and one configuration for every tab, so WebKit can reuse its processes and caches.
- **AppKit on the hot paths.** The tab list is a cell-reusing `NSTableView`, web views resize through autoresizing masks rather than constraints, and progress bars are drawn with layers only.
- **Shortcuts handled before the page.** Shortcuts are matched in a local event monitor, so pages can't capture ⌘L or ⌃⇥.

### Benchmarks

`make bench` builds a Release Tern and measures it through the agent API, using the same local test site as `make smoke`:

- **Launch:** five launches, timed from process start to the first window and to the first page finishing its load (median).
- **Memory:** Tern's footprint plus its WebContent processes with one tab, then again after opening ten more, as MB per extra tab.
- **Tab switch** and **palette open:** 30 samples each, as median and p95. Each one is timed in the app until Tern has redrawn its windows. Page content composites in WebKit's own process and isn't included.

Each launch is isolated, as in the smoke test: one window, and no saved session or extensions. Results go to `build/bench/results.json`. `make bench SAVE=1` also saves them as a baseline, and later runs show the change against it. `tern call tern.metrics` returns the same launch and memory numbers from a running Tern.

## Known limitations

- No prebuilt, signed releases yet. Builds are ad-hoc signed and unsandboxed (scanning `/Applications` for extensions requires that).
- The ⌥⌘I and ⌥⌘C shortcuts open the Web Inspector through a private WebKit API, which the Mac App Store doesn't allow. The right-click **Inspect Element** item uses public API.
- Extension permissions are granted all at once when you turn an extension on. Per-site grants are planned.

## Website

The landing page in `site/` is a prerendered SvelteKit app. Its screenshots go through `@sveltejs/enhanced-img`, which generates AVIF and WebP at several sizes, so keep the source images in `site/src/lib/assets` at full resolution.

```sh
cd site
bun install --frozen-lockfile
bun run dev
```

`bun run build` type-checks the site and writes it to `dist`. `site/orch.pkl` deploys that to `tern.torsten.work`, and every push to `main` that touches `site/` runs `.github/workflows/website-deploy.yml`.

The workflow reads the `ORCH_CLUSTER` and `ORCH_VERSION` repository variables and needs orch to trust this repository once:

```sh
orch github trust TorstenDittmann/tern --app tern --branch main --environment production --domain tern.torsten.work
```

To deploy by hand from `site/`:

```sh
bun run build
orch deploy -f orch.pkl --wait
```
