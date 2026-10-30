import Foundation

/// Chrome Web Store extensions are written for Chrome, and some touch Chrome APIs WebKit doesn't have as they start
/// (Proton Pass calls `runtime.onUpdateAvailable.addListener`, which throws and kills its service worker).
/// Before such an extension loads, its background gets a small script that fills those in as harmless no-ops.
/// Only store installs are changed: they're our own copy, while unpacked folders belong to the user.
enum ChromeCompat {
    static let scriptName = "tern-compat.js"
    static let workerName = "tern-background.js"

    static let script = """
    // Added by Tern: Chrome APIs that WebKit doesn't have, as no-ops, so extensions written for Chrome start.
    (() => {
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

    private static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: .withoutEscapingSlashes)) ?? Data("[\"\"]".utf8)
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }
}
