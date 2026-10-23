import AppKit

/// Tracks which tabs an agent is driving, so the UI can ring them and show "Agent connected".
/// A tab counts as driven for a few seconds after each agent action on it.
@MainActor
final class AgentActivity {
    static let shared = AgentActivity()
    static let changed = Notification.Name("TernAgentActivityChanged")

    private static let linger: TimeInterval = 4
    private var timers: [UUID: Timer] = [:]

    /// True while an agent drives any tab or keeps an event subscription open.
    var isActive: Bool { !timers.isEmpty || AgentServer.shared.hasSubscribers }

    func touch(_ tab: Tab) {
        timers[tab.id]?.invalidate()
        timers[tab.id] = Timer.scheduledTimer(withTimeInterval: Self.linger, repeats: false) { [weak self, weak tab] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let tab { self.end(tab) }
            }
        }
        guard !tab.isAgentDriving else { return }
        tab.isAgentDriving = true
        tab.owner?.tabDidChange(tab)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func end(_ tab: Tab) {
        timers.removeValue(forKey: tab.id)?.invalidate()
        guard tab.isAgentDriving else { return }
        tab.isAgentDriving = false
        tab.owner?.tabDidChange(tab)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func endAll() {
        AppDelegate.shared.allTabs.filter(\.isAgentDriving).forEach(end)
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func subscribersChanged() {
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
