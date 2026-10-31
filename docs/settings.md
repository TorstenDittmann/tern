# Settings

**Settings…** (⌘,) has two panes:

- **General:** the search engine (DuckDuckGo, Google, Bing, Brave Search, Kagi, Ecosia, Startpage, or a custom URL with `%s`), how long idle background tabs wait before they're suspended (or never), the agent API switch, and Clear History.
- **Shortcuts:** every command and its shortcut. Click a shortcut and press the new keys; esc cancels and ⌫ removes it. A shortcut that's already taken moves to the new command. Changes are saved to `~/.config/tern/keymap.json`, which you can still edit by hand. **Restore Defaults** undoes them all.

The same values can be set from the terminal:

```sh
defaults write dev.tern.browser searchTemplate "https://www.google.com/search?q=%s"   # default: DuckDuckGo
defaults write dev.tern.browser suspendAfter 600                                     # seconds; -1 for never; default 900
```
