import AppKit
import Foundation

/// Where to find the printer. The access code lives in the Keychain, not here.
struct PrinterConfig: Codable, Equatable {
    var host: String
    var serial: String
    var name: String
    /// SSDP model code ("N7" for the P2S).
    var modelCode: String

    var modelName: String { PrinterModels.name(for: modelCode, serial: serial) }
}

enum PrinterModels {
    static func name(for code: String, serial: String = "") -> String {
        switch code.uppercased() {
        case "N7": return "P2S"
        case "C11": return "P1P"
        case "C12": return "P1S"
        case "BL-P001": return "X1 Carbon"
        case "BL-P002": return "X1"
        case "C13", "BL-P003": return "X1E"
        case "N1", "A12", "A04": return "A1 mini"
        case "N2S", "A11": return "A1"
        case "O1D": return "H2D"
        case "O1E", "O2D": return "H2D Pro"
        case "O1C", "O1C2": return "H2C"
        case "O1S": return "H2S"
        case "N6": return "X2D"
        case "N9": return "A2L"
        default:
            switch serial.prefix(3) {
            case "22E": return "P2S"
            case "01P": return "P1S"
            case "01S": return "P1P"
            case "00M": return "X1 Carbon"
            case "03W": return "X1E"
            case "039": return "A1"
            case "030": return "A1 mini"
            case "093": return "H2S"
            case "094": return "H2D"
            default: return "Bambu Lab printer"
            }
        }
    }
}

/// Commands for the printer. The job commands (all but the light) are the ones printers with signed-command
/// firmware only take from Bambu's own apps, or from Bambu Bar via Bambu Cloud.
enum PrinterCommand {
    case pause, resume, stop
    case speed(SpeedLevel)
    case light(node: String, on: Bool)

    /// The request's top-level key.
    var key: String {
        if case .light = self { return "system" }
        return "print"
    }

    var body: [String: Any] {
        switch self {
        case .pause: return ["command": "pause", "param": ""]
        case .resume: return ["command": "resume", "param": ""]
        case .stop: return ["command": "stop", "param": ""]
        case .speed(let level): return ["command": "print_speed", "param": "\(level.rawValue)"]
        case .light(let node, let on):
            return ["command": "ledctrl", "led_node": node, "led_mode": on ? "on" : "off",
                    "led_on_time": 500, "led_off_time": 500, "loop_times": 0, "interval_time": 0]
        }
    }
}

/// Keeps one MQTT session to the printer alive: connects, re-requests a full report, merges the deltas
/// into a status, and reconnects with back-off when the printer drops off the network or the Mac sleeps.
@MainActor
final class PrinterConnection {
    enum Phase: Equatable {
        case idle
        case connecting
        case online
        case offline(String)
        case unauthorized
        case certificate(String)
    }

    var onPhase: ((Phase) -> Void)?
    var onStatus: ((PrinterStatus, ReportDocument) -> Void)?
    /// Any message from the printer, changed or not.
    var onHeartbeat: (() -> Void)?
    /// A command acknowledgement: command name, success, reason.
    var onAck: ((String, Bool, String?) -> Void)?

    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onPhase?(phase) } }
    }

    private var config: PrinterConfig?
    private var accessCode = ""
    private var insecure = false
    private var client: MQTTClient?
    private var document = ReportDocument()
    private var lastStatus: PrinterStatus?
    private var lastMessage = Date.distantPast
    private var lastPushall = Date.distantPast
    private var attempt = 0
    private var retry: Timer?
    private var watchdog: Timer?
    private var sequence = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnectSoon(after: 2) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        })
    }

    func start(_ config: PrinterConfig, accessCode: String, insecure: Bool = false) {
        stop()
        self.config = config
        self.accessCode = accessCode
        self.insecure = insecure
        attempt = 0
        open()
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
    }

    func stop() {
        retry?.invalidate()
        watchdog?.invalidate()
        retry = nil
        watchdog = nil
        closeClient()
        config = nil
        lastStatus = nil
        document.reset()
        phase = .idle
    }

    /// Asks for a full report now (after wake, or when the person clicks refresh).
    func refresh() {
        if phase == .online { requestFullReport() } else if config != nil { reconnectSoon(after: 0) }
    }

    // MARK: - Commands

    func send(_ command: PrinterCommand) { send([command.key: command.body], key: command.key) }

    private func send(_ message: [String: Any], key: String) {
        guard let config, let client, phase == .online else { return }
        sequence += 1
        var message = message
        if var body = message[key] as? [String: Any] {
            body["sequence_id"] = "\(sequence)"
            message[key] = body
        }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        client.publish("device/\(config.serial)/request", payload: data)
    }

    // MARK: - Session

    private func open() {
        guard let config else { return }
        closeClient()
        phase = .connecting
        // The watchdog measures silence from here, so it doesn't cut off an attempt that's still connecting.
        lastMessage = Date()
        let client = MQTTClient(.init(host: config.host, password: accessCode, serial: config.serial, insecure: insecure))
        client.onEvent = { [weak self, weak client] event in
            MainActor.assumeIsolated {
                guard let self, let client, client === self.client else { return }
                self.handle(event)
            }
        }
        self.client = client
        client.connect()
    }

    private func closeClient() {
        client?.onEvent = nil
        client?.disconnect()
        client = nil
    }

    private func handle(_ event: MQTTClient.Event) {
        guard let config else { return }
        switch event {
        case .connected:
            lastMessage = Date()
            client?.subscribe("device/\(config.serial)/report")
            sendRaw(["info": ["sequence_id": "0", "command": "get_version"]])
            requestFullReport()
            // Stay "connecting" until the first report arrives, so a silent broker doesn't look online.
        case .message(_, let payload):
            lastMessage = Date()
            onHeartbeat?()
            guard let json = Self.decode(payload) else { return }
            if let p = json["print"] as? [String: Any], let command = p["command"] as? String,
               command != "push_status", let result = p["result"] as? String {
                onAck?(command, result.lowercased() == "success", p["reason"] as? String)
            }
            if let s = json["system"] as? [String: Any], let command = s["command"] as? String,
               command == "ledctrl", let result = s["result"] as? String {
                onAck?(command, result.lowercased() == "success", s["reason"] as? String)
            }
            guard document.apply(json) else { return }
            guard document.hasFullReport || document.print["gcode_state"] != nil else { return }
            if phase != .online {
                // Back-off resets only once the printer is really talking, not on a CONNACK alone.
                attempt = 0
                phase = .online
            }
            publishStatus()
        case .disconnected(let failure):
            client = nil
            switch failure {
            case .refused(let code) where code == 4 || code == 5:
                // A wrong access code won't fix itself; wait for the person to change it.
                phase = .unauthorized
                return
            case .certificate(let reason):
                // A certificate that doesn't check out won't fix itself either; don't keep sending it the code.
                phase = .certificate(reason)
                return
            case .unreachable(let reason):
                phase = .offline(reason)
            case .timedOut:
                phase = .offline("The printer stopped answering.")
            case .closed, .malformed, .refused:
                phase = .offline("The connection to the printer closed.")
            }
            scheduleReconnect()
        }
    }

    private func publishStatus() {
        var status = ReportParser.status(from: document, hms: HMSCatalog.shared)
        if let last = lastStatus {
            // Keep the timestamp the remaining time was measured at, so the ETA doesn't drift between reports.
            var same = status
            same.updatedAt = last.updatedAt
            if same == last { return }
            if status.remainingMinutes == last.remainingMinutes && status.progress == last.progress && status.state == last.state {
                status.updatedAt = last.updatedAt
            }
        }
        lastStatus = status
        onStatus?(status, document)
    }

    private func requestFullReport() {
        lastPushall = Date()
        sendRaw(["pushing": ["sequence_id": "0", "command": "pushall"]])
    }

    private func sendRaw(_ message: [String: Any]) {
        guard let config, let client, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        client.publish("device/\(config.serial)/request", payload: data)
    }

    private func checkHealth() {
        guard config != nil else { return }
        let silence = Date().timeIntervalSince(lastMessage)
        switch phase {
        case .online:
            if silence > 95 {
                phase = .offline("The printer stopped sending updates.")
                reconnectSoon(after: 0)
            } else if silence > 60 || Date().timeIntervalSince(lastPushall) > 300 {
                requestFullReport()
            }
        case .connecting:
            if client != nil, silence > 25 { reconnectSoon(after: 0) }
        default:
            break
        }
    }

    private func scheduleReconnect() {
        let delays: [TimeInterval] = [2, 4, 8, 15, 30]
        let delay = delays[min(attempt, delays.count - 1)]
        attempt += 1
        reconnectSoon(after: delay)
    }

    private func reconnectSoon(after delay: TimeInterval) {
        guard config != nil else { return }
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.open() }
        }
    }

    private func suspend() {
        retry?.invalidate()
        closeClient()
    }

    /// Some firmware sends bytes that aren't valid UTF-8; fall back to Latin-1 rather than drop the report.
    private static func decode(_ data: Data) -> [String: Any]? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return json }
        guard let text = String(data: data, encoding: .isoLatin1), let utf8 = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: utf8) as? [String: Any]
    }
}
