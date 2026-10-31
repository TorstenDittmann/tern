# Keyboard

| Action | Shortcut |
|---|---|
| Command palette | ⌘K or ⇧⌘P |
| Tab picker | ⌘P or ⇧⌘A |
| Address bar | ⌘L |
| New tab / window | ⌘T / ⌘N |
| Close tab / window | ⌘W / ⇧⌘W |
| Reopen closed tab | ⇧⌘T |
| Duplicate tab | ⇧⌘D |
| Next / previous tab | ⌃⇥ / ⌃⇧⇥, ⇧⌘] / ⇧⌘[ |
| Move tab down / up | ⌥⇧⌘↓ / ⌥⇧⌘↑ |
| Go to tab 1–8 / last tab | ⌘1 – ⌘8 / ⌘9 |
| Split view on / off | ⇧⌘S or ⌘\\ |
| Split down (new tab below) | ⌃⌘S or ⌃⌘\\ |
| Split with a tab, page or address | ⌥⌘S or ⌥⌘\\ |
| Change split layout | ⌃⇧⌘S or ⌃⇧⌘\\ |
| Swap panes | ⌥⇧⌘S or ⇧⌘\\ |
| Focus pane left / right / above / below (→ and ↓ split when there is no pane) | ⌥⌘← / ⌥⌘→ / ⌥⌘↑ / ⌥⌘↓ |
| Filter tabs in the sidebar | ⌘E |
| Toggle sidebar | ⌘S |
| Back / forward | ⌘[ / ⌘] |
| Reload / ignoring cache / stop | ⌘R / ⇧⌘R / ⌘. |
| Find / next / previous | ⌘F / ⌘G / ⇧⌘G |
| Bookmark page / show bookmarks / show history | ⌘D / ⌥⌘B / ⌘Y |
| New private window | ⇧⌘N |
| Compact mode | ⇧⌘L |
| Reader / responsive design mode | ⌥⌘R / ⌃⌘R |
| Show downloads | ⇧⌘J |
| Print | ⌥⌘P |
| Mute or unmute tab | ⇧⌘M |
| Settings | ⌘, |
| Link hints (click links from the keyboard) | ⌘J |
| Peek at a link / keep it as a tab / in a split | ⌥-click / ⌘↩ / ⇧⌘↩ |
| Zoom in / out / actual size | ⌘= / ⌘- / ⌘0 |
| Web Inspector / console | ⌥⌘I / ⌥⌘C |
| Requests | ⌥⌘N |
| Copy URL / as Markdown link | ⇧⌘C / ⌥⇧⌘C |
| Edit key bindings | ⌥⌘, |

⌘-click or middle-click a link to open it in a background tab. Add ⇧ to switch to it.

## Custom bindings

Bindings live in `~/.config/tern/keymap.json`. Open it with **Tern ▸ Edit Key Bindings…**, and apply changes with **Tern ▸ Reload Key Bindings**. Map a chord to a command name, or to `null` to remove a default binding:

```json
{
  "ctrl+j": "nextTab",
  "ctrl+k": "previousTab",
  "cmd+s": null
}
```

Chords combine `cmd`, `shift`, `alt` and `ctrl` with a key. Key names include `tab`, `return`, `escape`, `space`, `left`/`right`/`up`/`down`, `f1`–`f12`, and `plus`. When the file is first created, it lists every command name.
