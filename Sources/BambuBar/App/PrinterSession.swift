import Foundation
import Observation

/// One configured printer: its connection, live status and the commands in flight.
/// `PrinterStore` owns the sessions and handles what spans printers (history, notifications, widgets).
@MainActor
@Observable
final class PrinterSession: Identifiable {
    /// The serial number, which never changes for a session.
    nonisolated let id: String
    var config: PrinterConfig
    private(set) var phase: PrinterConnection.Phase = .idle
    private(set) var status: PrinterStatus?
    /// Commands sent but not yet reflected in a report, so the controls respond immediately.
    private(set) var pendingLight: Bool?
    private(set) var pendingSpeed: SpeedLevel?
    /// More codes to try if the printer rejects the current one (a slicer may hold an old and a new one).
    var fallbackCodes: [String] = []
    /// False until the first report after connecting, so state already in progress doesn't notify.
    var hasBaseline = false
    /// When the printer last sent anything, to the second ("Updated 3s ago").
    private(set) var lastHeard: Date?

    var onPhase: ((PrinterSession, PrinterConnection.Phase) -> Void)?
    var onStatus: ((PrinterSession, PrinterStatus?, PrinterStatus, Bool) -> Void)?
    var onAck: ((PrinterSession, String, Bool, String?) -> Void)?
    var onHeartbeat: ((PrinterSession) -> Void)?

    /// The Bambu Cloud session, for printers that only take signed job commands.
    @ObservationIgnored weak var cloud: CloudAgent?
    @ObservationIgnored private let connection = PrinterConnection()
    @ObservationIgnored private var demo: DemoDriver?
    @ObservationIgnored private var insecure = false
    @ObservationIgnored private var pendingTask: Task<Void, Never>?

    init(config: PrinterConfig) {
        id = config.serial
        self.config = config
        connection.onPhase = { [weak self] phase in self?.phaseChanged(phase) }
        connection.onStatus = { [weak self] status, doc in self?.received(status, canceled: ReportParser.wasCanceled(doc)) }
        connection.onAck = { [weak self] command, ok, reason in self?.acknowledged(command, ok: ok, reason: reason) }
        connection.onHeartbeat = { [weak self] in
            guard let self else { return }
            // Whole seconds are enough for the label and spare the UI an update per message.
            if self.lastHeard.map({ Date().timeIntervalSince($0) >= 1 }) ?? true { self.lastHeard = Date() }
            self.onHeartbeat?(self)
        }
    }

    // MARK: - Lifecycle

    func start(accessCode: String, alternatives: [String] = [], insecure: Bool) {
        self.insecure = insecure
        fallbackCodes = alternatives.filter { $0 != accessCode }
        status = nil
        hasBaseline = false
        connection.start(config, accessCode: accessCode, insecure: insecure)
    }

    /// Runs a simulated printer instead of a connection (`--demo`).
    func startDemo(_ scenario: DemoDriver.Scenario, variant: Int) {
        let driver = DemoDriver(scenario: scenario, variant: variant)
        driver.onStatus = { [weak self] status, canceled in self?.received(status, canceled: canceled) }
        driver.onPhase = { [weak self] phase in self?.phaseChanged(phase) }
        demo = driver
        driver.start()
    }

    /// Shows a scripted status, as if the printer had reported it (README frames).
    func showDemoStatus(_ status: PrinterStatus) {
        received(status, canceled: false)
    }

    func stop() {
        connection.stop()
        phase = .idle
    }

    func refresh() { connection.refresh() }

    /// Reconnects with the stored code, e.g. after the printer moved to a new IP address.
    func restart() {
        guard demo == nil, let code = Keychain.accessCode(for: config.serial) else { return }
        connection.start(config, accessCode: code, insecure: insecure)
    }

    // MARK: - Derived

    /// A live status is on hand: connected, or briefly reconnecting after a drop.
    var isOnline: Bool { status != nil && (phase == .online || phase == .connecting) }
    var chamberLightOn: Bool { pendingLight ?? status?.chamberLightOn ?? false }
    var speed: SpeedLevel { pendingSpeed ?? status?.speed ?? .standard }
    var accessCode: String? { Keychain.accessCode(for: config.serial) }

    var linkSummary: String {
        switch phase {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .online: return "Connected"
        case .offline: return "Offline"
        case .unauthorized: return "Access code rejected"
        case .certificate: return "Certificate not trusted"
        }
    }

    var linkDetail: String? {
        switch phase {
        case .offline(let reason): return reason
        case .unauthorized: return "Check the access code on the printer's screen (Settings → Network) and enter it again."
        case .certificate(let reason): return "The printer's TLS certificate couldn't be verified: \(reason)"
        default: return nil
        }
    }

    /// "Printing · 64%", "Ready", "Offline" — one line for menus and lists.
    var shortState: String {
        guard let s = status, isOnline else { return linkSummary }
        return s.state.isActive ? "\(s.state.title) · \(s.progress)%" : s.stateTitle
    }

    // MARK: - Commands

    @discardableResult
    func pause() -> CloudAgent.Problem? { if let demo { demo.pause(); return nil } else { return send(.pause) } }
    @discardableResult
    func resume() -> CloudAgent.Problem? { if let demo { demo.resume(); return nil } else { return send(.resume) } }
    @discardableResult
    func stopPrint() -> CloudAgent.Problem? { if let demo { demo.stop(); return nil } else { return send(.stop) } }

    /// The light isn't signature-gated, so it always goes over the local network; every chamber light node switches together.
    func toggleLight() {
        let on = !chamberLightOn
        pendingLight = on
        if let demo {
            demo.setLight(on)
        } else {
            for node in status?.chamberLightNodes ?? ["chamber_light"] { connection.send(.light(node: node, on: on)) }
        }
        clearPendingSoon()
    }

    @discardableResult
    func setSpeed(_ level: SpeedLevel) -> CloudAgent.Problem? {
        if let demo {
            demo.setSpeed(level)
        } else if let problem = send(.speed(level)) {
            return problem
        }
        pendingSpeed = level
        clearPendingSoon()
        return nil
    }

    /// A printer that refuses unsigned job commands gets them through Bambu Cloud, signed by Bambu's plugin.
    private func send(_ command: PrinterCommand) -> CloudAgent.Problem? {
        guard status?.controlsLocked == true else {
            connection.send(command)
            return nil
        }
        guard let cloud, cloud.serial == id else { return .unavailable("Bambu Cloud isn't connected to this printer.") }
        return cloud.send(command)
    }

    func acknowledged(_ command: String, ok: Bool, reason: String?) {
        if !ok { pendingLight = nil; pendingSpeed = nil }
        onAck?(self, command, ok, reason)
    }

    /// A command over Bambu Cloud may wait for the session to sign in first, so it gets longer to show up.
    private func clearPendingSoon() {
        let wait: Duration = status?.controlsLocked == true ? .seconds(25) : .seconds(6)
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.pendingLight = nil
            self?.pendingSpeed = nil
        }
    }

    // MARK: - Updates

    private func phaseChanged(_ phase: PrinterConnection.Phase) {
        if phase == .unauthorized, !fallbackCodes.isEmpty {
            // Try the slicer's other stored code before telling anyone.
            let next = fallbackCodes.removeFirst()
            Keychain.setAccessCode(next, for: config.serial)
            connection.start(config, accessCode: next, insecure: insecure)
            return
        }
        if phase == .online { fallbackCodes = [] }
        self.phase = phase
        onPhase?(self, phase)
    }

    private func received(_ new: PrinterStatus, canceled: Bool) {
        let old = status
        status = new
        lastHeard = Date()
        if let light = pendingLight, new.chamberLightOn == light { pendingLight = nil }
        if let level = pendingSpeed, new.speed == level { pendingSpeed = nil }
        onStatus?(self, old, new, canceled)
        hasBaseline = true
    }
}
