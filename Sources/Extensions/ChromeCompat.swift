import Foundation

/// Chrome Web Store extensions are written for Chrome, and some touch Chrome APIs WebKit doesn't have as they start
/// (Proton Pass calls `runtime.onUpdateAvailable.addListener`, which throws and kills its service worker).
/// Before such an extension loads, its background and pages get a small script that fills those in as harmless no-ops.
/// Only store installs are changed: they're our own copy, while unpacked folders belong to the user.
enum ChromeCompat {
    static let scriptName = "tern-compat.js"
    static let workerName = "tern-background.js"

    static let script = """
    // Added by Tern: Chrome APIs that WebKit doesn't have, as no-ops, so extensions written for Chrome start.
    (() => {
      // Some extensions swap `chrome`/`browser` for a Proxy as "hardening" (Proton Pass does), after which WebKit stops
      // delivering messages to the worker. Pin the originals; assigning to them then quietly does nothing.
      for (const key of ["chrome", "browser"]) {
        const value = globalThis[key];
        if (!value) continue;
        try { Object.defineProperty(globalThis, key, { configurable: false, enumerable: true, get: () => value, set() {} }); } catch {}
      }
      // WebKit's API objects are wrappers it can collect and recreate, dropping anything added below, unless something holds them.
      globalThis.__ternKeep = [globalThis.chrome, globalThis.browser].flatMap((ns) => ns ? [ns, ns.runtime, ns.tabs, ns.windows] : []);
      const event = () => ({ addListener() {}, removeListener() {}, hasListener() { return false; }, hasListeners() { return false; } });
      const fill = (object, name, value) => {
        if (!object || object[name] !== undefined) return;
        try { Object.defineProperty(object, name, { value, configurable: true, writable: true, enumerable: true }); } catch {}
      };
      for (const ns of [globalThis.chrome, globalThis.browser]) {
        if (!ns) continue;
        fill(ns.runtime, "onUpdateAvailable", event());
        fill(ns.runtime, "onRestartRequired", event());
        fill(ns.runtime, "requestUpdateCheck", () => Promise.resolve({ status: "no_update" }));
        // No offscreen documents: creating one "works" but nothing answers, so callers fall back to their other paths.
        fill(ns, "offscreen", {
          createDocument: () => Promise.resolve(),
          closeDocument: () => Promise.resolve(),
          hasDocument: () => Promise.resolve(false),
          Reason: new Proxy({}, { get: (_, key) => String(key) }),
        });
      }
      // Chrome has already sized a popup to its page when the page's scripts run, so some popups (Proton Pass) read the
      // viewport and pin themselves to it. WebKit's popover is still small at that point, so in the toolbar popup the
      // root reports at least its own CSS size, which is what Chrome's viewport would have been.
      if (typeof document !== "undefined") {
        try {
          const manifest = globalThis.chrome.runtime.getManifest();
          const page = (manifest.action || manifest.browser_action || {}).default_popup;
          if (page && new URL(page, location.origin + "/").pathname === location.pathname) {
            for (const [prop, side] of [["clientWidth", "width"], ["clientHeight", "height"]]) {
              const real = Object.getOwnPropertyDescriptor(Element.prototype, prop);
              Object.defineProperty(Element.prototype, prop, {
                configurable: true,
                get() {
                  const value = real.get.call(this);
                  return this === document.documentElement ? Math.max(value, Math.round(this.getBoundingClientRect()[side])) : value;
                },
              });
            }
          }
        } catch {}
      }
    })();
    """

    /// Writes the script and points the manifest's background at it (once; later calls only refresh the script).
    /// Leaves the extension as it is if its manifest can't be read as plain JSON.
    static func install(in folder: URL) {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var background = manifest["background"] as? [String: Any] else { return }
        try? script.write(to: folder.appendingPathComponent(scriptName), atomically: true, encoding: .utf8)
        injectIntoPages(in: folder)

        if let worker = background["service_worker"] as? String {
            guard worker != workerName else { return }
            // A module worker can't call importScripts, so it imports both instead.
            let isModule = background["type"] as? String == "module"
            let path = worker.hasPrefix("/") ? String(worker.dropFirst()) : worker
            let wrapper = isModule
                ? "import \(jsString("./" + scriptName));\nimport \(jsString("./" + path));\n"
                : "importScripts(\(jsString(scriptName)), \(jsString(worker)));\n"
            guard (try? wrapper.write(to: folder.appendingPathComponent(workerName), atomically: true, encoding: .utf8)) != nil else { return }
            background["service_worker"] = workerName
            background["tern_original_service_worker"] = worker
        } else if let scripts = background["scripts"] as? [String] {
            guard scripts.first != scriptName else { return }
            background["scripts"] = [scriptName] + scripts
        } else {
            return
        }
        manifest["background"] = background
        guard let out = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return }
        try? out.write(to: manifestURL, options: .atomic)
    }

    /// Every HTML page in the extension (popup, options, and the rest) loads the script before its own.
    private static func injectIntoPages(in folder: URL) {
        let tag = "<script src=\"/\(scriptName)\"></script>"
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in files where ["html", "htm"].contains(url.pathExtension.lowercased()) {
            guard var html = try? String(contentsOf: url, encoding: .utf8), !html.contains(tag) else { continue }
            if let head = html.range(of: "<head\\b[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                html.insert(contentsOf: tag, at: head.upperBound)
            } else {
                html = tag + html
            }
            try? html.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: .withoutEscapingSlashes)) ?? Data("[\"\"]".utf8)
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }
}
