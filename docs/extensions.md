# Extensions

Tern uses WebKit's public web extension API (`WKWebExtension`, macOS 15.4 and later). The **Extensions** menu lists three kinds:

- **Chrome Web Store** extensions. Open the store (**Get Extensions from the Chrome Web Store**), go to an extension, and press **Add to Tern** beside the address bar. Tern downloads the store's package from Google, unpacks it into `~/Library/Application Support/Tern/Extensions/Chrome Web Store`, and keeps the store ID as the extension's `runtime.id`, so sites that message it by that ID (Proton's sign-in, for example) reach it. Pressing it again on a later visit isn't offered yet; remove and re-add to update.
- **Safari Web Extensions** found inside apps in `/Applications` and `~/Applications`.
- **Unpacked** Chrome, Firefox, or Safari-style MV2 and MV3 extensions. Add them with **Load Unpacked Extension…**, or drop them into `~/Library/Application Support/Tern/Extensions`. They're loaded in place, so changes to the files apply on the next load.

Extensions are off until you turn them on, because each one's background page costs memory. Turning one on shows the permissions it asks for. Supported features include content scripts, background pages and service workers, `tabs`, `windows`, `storage`, toolbar actions with badges and popups, `commands`, `declarativeNetRequest` (for content blockers such as uBlock Origin Lite), and options pages.

**Native messaging.** A Safari extension's native messages go to its own app extension, the way Safari sends them. Chrome Web Store extensions can't reach a companion app yet.
