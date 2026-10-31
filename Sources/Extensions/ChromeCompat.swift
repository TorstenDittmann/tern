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
      const isThisPage = (tab) => {
        try { const url = new URL(tab.url); return url.origin === location.origin && url.pathname === location.pathname; } catch { return false; }
      };
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
        // Chrome answers undefined unless this page is itself in a tab, but from a popup WebKit answers with the active tab
        // (or null if there is none). Proton Pass takes that to mean it's in a tab and drops its popup's fixed size.
        const getCurrent = ns.tabs?.getCurrent;
        if (getCurrent) {
          const tabs = ns.tabs;
          try {
            Object.defineProperty(tabs, "getCurrent", { configurable: true, writable: true, enumerable: true, value(callback) {
              const tab = getCurrent.call(tabs).then((tab) => isThisPage(tab) ? tab : undefined);
              if (!callback) return tab;
              tab.then(callback, () => callback());
            } });
          } catch {}
        }
      }
    })();
    """

    /// Writes the script and points the manifest's background and content scripts at it (once; later calls only refresh
    /// the script). Leaves the extension as it is if its manifest can't be read as plain JSON.
    static func install(in folder: URL) {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        try? script.write(to: folder.appendingPathComponent(scriptName), atomically: true, encoding: .utf8)
        injectIntoPages(in: folder)

        var changed = false
        if var background = manifest["background"] as? [String: Any], patch(&background, in: folder) {
            manifest["background"] = background
            changed = true
        }
        if var scripts = manifest["content_scripts"] as? [[String: Any]], patch(&scripts) {
            manifest["content_scripts"] = scripts
            changed = true
        }
        guard changed, let out = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return }
        try? out.write(to: manifestURL, options: .atomic)
    }

    private static func patch(_ background: inout [String: Any], in folder: URL) -> Bool {
        if let worker = background["service_worker"] as? String {
            guard worker != workerName else { return false }
            // A module worker can't call importScripts, so it imports both instead.
            let isModule = background["type"] as? String == "module"
            let path = worker.hasPrefix("/") ? String(worker.dropFirst()) : worker
            let wrapper = isModule
                ? "import \(jsString("./" + scriptName));\nimport \(jsString("./" + path));\n"
                : "importScripts(\(jsString(scriptName)), \(jsString(worker)));\n"
            guard (try? wrapper.write(to: folder.appendingPathComponent(workerName), atomically: true, encoding: .utf8)) != nil else { return false }
            background["service_worker"] = workerName
            background["tern_original_service_worker"] = worker
            return true
        }
        if let scripts = background["scripts"] as? [String], scripts.first != scriptName {
            background["scripts"] = [scriptName] + scripts
            return true
        }
        return false
    }

    /// A content script swapping the globals stops `tabs.sendMessage` reaching it, as in the worker, so the script runs
    /// first in each of them too. Not in the page's own world, where there are no extension globals to pin.
    private static func patch(_ contentScripts: inout [[String: Any]]) -> Bool {
        var changed = false
        for index in contentScripts.indices {
            guard contentScripts[index]["world"] as? String != "MAIN",
                  let js = contentScripts[index]["js"] as? [String], js.first != scriptName else { continue }
            contentScripts[index]["js"] = [scriptName] + js
            changed = true
        }
        return changed
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
