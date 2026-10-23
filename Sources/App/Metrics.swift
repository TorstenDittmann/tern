import AppKit
import Darwin
import WebKit

/// Launch timings and memory use, reported by `tern.metrics` and read by `make bench`.
@MainActor
enum Metrics {
    /// `make bench` runs Tern isolated: one window on this URL, no session restore or save, no extensions.
    static var benchmarkURL: URL? { ProcessInfo.processInfo.environment["TERN_BENCH_URL"].flatMap(URL.init(string:)) }
    static var isBenchmark: Bool { benchmarkURL != nil }

    private static var launched: Date?
    private static var windowShown: Date?
    private static var pageLoaded: Date?

    static func markLaunched() { if launched == nil { launched = Date() } }
    static func markWindowShown() { if windowShown == nil { windowShown = Date() } }
    static func markPageLoaded() { if pageLoaded == nil { pageLoaded = Date() } }

    /// Milliseconds from process start to each launch milestone (null until it happens).
    static func launch() -> [String: Any] {
        func since(_ date: Date?) -> Any {
            guard let date, let start = processStart else { return NSNull() }
            return (date.timeIntervalSince(start) * 1000).rounded()
        }
        return ["didFinishLaunchingMs": since(launched), "firstWindowMs": since(windowShown), "firstPageMs": since(pageLoaded)]
    }

    /// Physical footprint, in MB, of Tern and of each WebContent process its tabs use.
    static func memory() -> [String: Any] {
        var pids = Set<pid_t>()
        for tab in AppDelegate.shared.allTabs {
            if let pid = tab.webView.flatMap(webProcessID) { pids.insert(pid) }
        }
        let web = pids.sorted().compactMap { pid in footprintMB(pid).map { ["pid": Int(pid), "footprintMB": $0] } }
        let app = footprintMB(getpid()) ?? 0
        let webTotal = web.compactMap { $0["footprintMB"] as? Double }.reduce(0, +)
        return ["appMB": app, "webContentMB": webTotal, "totalMB": app + webTotal, "webProcesses": web]
    }

    private static var processStart: Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    private static func footprintMB(_ pid: pid_t) -> Double? {
        var usage = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return nil }
        return (Double(usage.ri_phys_footprint) / 1_048_576 * 10).rounded() / 10
    }

    /// WebKit doesn't expose the WebContent pid publicly; read the private property only if it exists.
    private static func webProcessID(_ webView: WKWebView) -> pid_t? {
        guard webView.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }
}
