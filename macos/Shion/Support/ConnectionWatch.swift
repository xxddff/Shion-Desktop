import AppKit
import Network

/// Back from sleep, or on another network: the gateway does not wait out its backoff but tries
/// again at once (Gateway.reconnectNow), and a connection that seems up is checked first, since a
/// socket from before the sleep or from the old network is dead without knowing it. Needs no
/// permission. Not started in screenshot runs.
final class ConnectionWatch {
    static let shared = ConnectionWatch()

    private var monitor: NWPathMonitor?
    private var wake: (any NSObjectProtocol)?
    /// The network last seen: whether it is up, its interfaces and its routers. The first one, at
    /// start, is only remembered.
    private var network: String?

    private init() {}

    func start(_ gateway: Gateway) {
        guard monitor == nil else { return }
        wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak gateway] _ in
            MainActor.assumeIsolated {
                gateway?.reconnectNow()
            }
        }
        let monitor = NWPathMonitor()
        // called on the monitor's queue, not the main thread
        monitor.pathUpdateHandler = { @Sendable [weak self, weak gateway] path in
            let network = ConnectionWatch.describe(path)
            Task { @MainActor in
                self?.changed(to: network, gateway)
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.shion.network"))
        self.monitor = monitor
    }

    /// A network that came up, or another one: try now.
    private func changed(to network: String, _ gateway: Gateway?) {
        defer { self.network = network }
        guard let previous = self.network, previous != network, network.hasPrefix("up ") else { return }
        gateway?.reconnectNow()
    }

    nonisolated private static func describe(_ path: NWPath) -> String {
        let interfaces = path.availableInterfaces.map(\.name).joined(separator: ",")
        let routers = path.gateways.map { "\($0)" }.joined(separator: ",")
        return "\(path.status == .satisfied ? "up" : "down") \(interfaces) \(routers)"
    }
}
