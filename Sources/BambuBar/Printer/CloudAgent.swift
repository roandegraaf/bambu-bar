import AppKit
import Foundation
import Observation

/// Bambu Studio on this Mac: its network plugins reach the printer through Bambu Cloud, so they need it installed and run once.
struct BambuStudioInstall {
    var pluginFolder: URL
    var certFolder: URL
    var version: String

    static func find() -> BambuStudioInstall? {
        let plugins = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BambuStudio/plugins")
        guard ["libbambu_networking.dylib", "libBambuSource.dylib"].allSatisfy({
            FileManager.default.fileExists(atPath: plugins.appendingPathComponent($0).path)
        }) else { return nil }
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.bambulab.bambu-studio")
            ?? URL(fileURLWithPath: "/Applications/BambuStudio.app")
        let certs = app.appendingPathComponent("Contents/Resources/cert")
        guard FileManager.default.fileExists(atPath: certs.appendingPathComponent("slicer_base64.cer").path) else { return nil }
        let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "02.08.04.57"
        return BambuStudioInstall(pluginFolder: plugins, certFolder: certs, version: version)
    }
}

/// One Bambu Cloud session for a printer, the way Bambu Studio and Bambu Handy reach it.
///
/// The `bambu-camera` helper (next to the app's executable) runs Bambu Studio's own network plugins, which sign
/// print commands, so printers that refuse unsigned commands over the local network still take pause, stop and
/// speed changes from here. The same session carries the live camera.
@MainActor
@Observable
final class CloudAgent {
    enum Phase: Equatable {
        case idle
        case starting(String)
        case ready
        case failed(Problem)
    }

    enum Problem: Equatable {
        case needsStudio
        case signedOut
        case notOnAccount
        case rejected
        case unavailable(String)

        /// What to tell someone whose pause, stop or speed change can't be sent.
        var commandMessage: String {
            switch self {
            case .needsStudio:
                return "This printer only takes signed commands. Install Bambu Studio and open it once: Bambu Bar signs them with its network plugin."
            case .signedOut:
                return "This printer only takes signed commands, sent through Bambu Cloud. Sign in to your Bambu account in Settings."
            case .notOnAccount:
                return "This printer isn't on the signed-in Bambu account, so Bambu Bar can't send it signed commands."
            case .rejected:
                return "Bambu didn't accept the saved sign-in. Sign in again in Settings to control this printer."
            case .unavailable(let reason):
                return "Couldn't reach the printer through Bambu Cloud: \(reason)"
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var serial: String?

    /// Camera states from the helper, without the "camera:" prefix, with their detail.
    @ObservationIgnored var onCameraState: ((String, String) -> Void)?
    /// The printer's answer to a command sent here: command, success, reason.
    @ObservationIgnored var onAck: ((String, Bool, String?) -> Void)?
    /// The session ended with commands still unanswered.
    @ObservationIgnored var onCommandsLost: ((Problem) -> Void)?
    @ObservationIgnored let video = VideoSink()

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var dataFolder: URL?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sequence = 30_000
    @ObservationIgnored private var unanswered: Set<String> = []
    @ObservationIgnored private var crashes: [Date] = []
    /// Set while the camera is wanted, so a relaunched helper picks it up again.
    @ObservationIgnored private var cameraFirmware: String??
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static let clientIDKey = "cameraClientID"

    var isRunning: Bool { process != nil }

    /// Why this Mac can't open a cloud session for the printer right now, checked without starting one.
    static func blocker(serial: String) -> Problem? {
        guard BambuStudioInstall.find() != nil else { return .needsStudio }
        let cloud = BambuCloud.shared
        guard cloud.isSignedIn, !cloud.needsSignIn else { return .signedOut }
        if !cloud.devices.isEmpty, cloud.device(serial: serial) == nil { return .notOnAccount }
        return nil
    }

    func start(serial: String) {
        halt()
        self.serial = serial
        observeSleep()
        launch()
    }

    func stop() {
        serial = nil
        cameraFirmware = nil
        unanswered = []
        halt()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        phase = .idle
    }

    /// Publishes a command to the printer; the helper holds it until the session is ready.
    /// Relaunches a session that ended. Returns why it can't be sent, or nil.
    func send(_ command: PrinterCommand) -> Problem? {
        guard let serial else { return .unavailable("Bambu Cloud isn't connected.") }
        if process == nil { start(serial: serial) }
        if case .failed(let problem) = phase { return problem }
        sequence += 1
        var body = command.body
        body["sequence_id"] = "\(sequence)"
        unanswered.insert("\(sequence)")
        guard let data = try? JSONSerialization.data(withJSONObject: [command.key: body]),
              let json = String(data: data, encoding: .utf8) else { return .unavailable("Couldn't encode the command.") }
        write("send \(json)")
        return nil
    }

    func startCamera(firmware: String?) {
        cameraFirmware = .some(firmware)
        write("camera \(firmware ?? "")")
    }

    func stopCamera() {
        cameraFirmware = nil
        write("nocamera")
    }

    private func write(_ line: String) {
        input?.write(Data((line.replacingOccurrences(of: "\n", with: "") + "\n").utf8))
    }

    /// The cloud session doesn't survive sleep; stop before it and start over after waking.
    private func observeSleep() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.halt()
                self?.phase = .starting("Waiting for the network…")
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.serial != nil else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    guard self.serial != nil, self.process == nil else { return }
                    self.launch()
                }
            }
        })
    }

    // MARK: - Helper process

    private func launch() {
        guard let serial else { return }
        if let problem = Self.blocker(serial: serial) { return fail(problem) }
        guard let studio = BambuStudioInstall.find(), let userInfo = BambuCloud.shared.pluginUserInfo() else { return fail(.signedOut) }
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "bambu-camera") else {
            return fail(.unavailable("The Bambu Cloud helper is missing from the app."))
        }

        generation += 1
        let generation = generation
        phase = .starting("Starting…")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BambuBar-cloud-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let conf = #"{"app":{"country_code":"US","language":"en_US","region":"US"}}"#
            try Data(conf.utf8).write(to: folder.appendingPathComponent("BambuStudio.conf"))
        } catch {
            return fail(.unavailable("Couldn't prepare Bambu Cloud: \(error.localizedDescription)"))
        }
        dataFolder = folder

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let settings: [(String, String)] = [
            ("plugin_dir", studio.pluginFolder.path),
            ("cert_dir", studio.certFolder.path),
            ("data_dir", folder.path),
            ("dev_id", serial),
            ("client_version", studio.version),
            ("os_version", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
            ("country", "US"),
            ("cli_id", Self.clientID),
            ("log_file", Self.logFolder.appendingPathComponent("camera.log").path),
            ("dump_file", UserDefaults.standard.bool(forKey: "cameraDump") ? Self.logFolder.appendingPathComponent("camera.h264").path : ""),
            ("user_info", userInfo),
        ]
        let config = settings.map { "\($0.0)=\($0.1.replacingOccurrences(of: "\n", with: ""))\n" }.joined() + "\n"

        let stdin = Pipe(), stdout = Pipe()
        let process = Process()
        process.executableURL = helper
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = ProcessInfo.processInfo.environment["BAMBU_CAMERA_VERBOSE"] == nil ? FileHandle.nullDevice : FileHandle.standardError

        let video = video
        let reader = FrameReader { [weak self] type, payload in
            switch type {
            case UInt8(ascii: "S"), UInt8(ascii: "A"):
                DispatchQueue.main.async { self?.received(type: type, json: payload, generation: generation) }
            default:
                video.deliver(type: type, payload: payload)
            }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { reader.consume(data) }
        }
        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            let crashed = proc.terminationReason == .uncaughtSignal
            DispatchQueue.main.async { self?.exited(code: code, crashed: crashed, generation: generation) }
        }

        do {
            try process.run()
        } catch {
            return fail(.unavailable("The Bambu Cloud helper didn't start: \(error.localizedDescription)"))
        }
        stdin.fileHandleForWriting.write(Data(config.utf8))
        self.process = process
        input = stdin.fileHandleForWriting
        if let firmware = cameraFirmware {
            onCameraState?("starting", "")
            write("camera \(firmware ?? "")")
        }
    }

    /// Ends the helper and its session without changing the phase.
    private func halt() {
        generation += 1
        if let process {
            // Closing stdin tells the helper to quit at once; the kill is in case the plugin hangs it.
            try? input?.close()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        process = nil
        input = nil
        if let folder = dataFolder {
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { try? FileManager.default.removeItem(at: folder) }
        }
        dataFolder = nil
    }

    private func fail(_ problem: Problem) {
        halt()
        phase = .failed(problem)
        dropUnanswered(problem)
    }

    private func dropUnanswered(_ problem: Problem) {
        guard !unanswered.isEmpty else { return }
        unanswered = []
        onCommandsLost?(problem)
    }

    private func received(type: UInt8, json: Data, generation: Int) {
        guard generation == self.generation,
              let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return }
        if type == UInt8(ascii: "A") {
            guard let command = object["command"] as? String, let result = object["result"] as? String else { return }
            unanswered.remove(object["sequence_id"] as? String ?? "")
            let reason = (object["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            onAck?(command, result.lowercased().hasPrefix("succe"), reason)
            return
        }
        guard let state = object["state"] as? String else { return }
        let detail = object["detail"] as? String ?? ""
        if state.hasPrefix("camera:") {
            onCameraState?(String(state.dropFirst(7)), detail)
            return
        }
        switch state {
        case "loading": phase = .starting("Starting…")
        case "signing_in": phase = .starting("Signing in to Bambu…")
        case "connecting": phase = .starting("Connecting to Bambu Cloud…")
        case "ready": phase = .ready
        case "error:auth": fail(.rejected)
        default:
            if state.hasPrefix("error:") { fail(.unavailable(detail.isEmpty ? "Bambu Cloud didn't connect." : detail)) }
        }
    }

    /// Bambu's camera library is occasionally killed by macOS while it loads its streaming frameworks
    /// (a code-signing page fault inside dyld); a fresh helper gets past it, so a crash is retried a few times.
    private func exited(code: Int32, crashed: Bool, generation: Int) {
        guard generation == self.generation else { return }
        if case .failed = phase { return }
        process = nil
        let reason = code == 0 ? "The Bambu Cloud session ended." : "The Bambu Cloud helper stopped (\(code))."
        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < 120 }
        guard crashed, crashes.count < 3 else { return fail(.unavailable(reason)) }
        crashes.append(now)
        halt()
        dropUnanswered(.unavailable("The Bambu Cloud helper restarted. Try again in a moment."))
        phase = .starting("Reconnecting…")
        let attempt = self.generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.generation == attempt, self.serial != nil else { return }
            self.launch()
        }
    }

    /// `~/Library/Logs/Bambu Bar`: the helper's trace of the last session (no tokens or camera links).
    private static var logFolder: URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Bambu Bar")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Bambu Studio sends one stable id per installation with every cloud session.
    private static var clientID: String {
        if let id = UserDefaults.standard.string(forKey: clientIDKey) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: clientIDKey)
        return id
    }
}

/// Where the helper's video frames go, from its reader thread; the camera sets a handler while it's on.
final class VideoSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UInt8, Data) -> Void)?

    func set(_ handler: ((UInt8, Data) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    func deliver(type: UInt8, payload: Data) {
        lock.withLock { handler }?(type, payload)
    }
}

/// Splits the helper's output into frames: [type u8][length u32 BE][payload].
private final class FrameReader: @unchecked Sendable {
    private var buffer = Data()
    private let onFrame: (UInt8, Data) -> Void

    init(onFrame: @escaping (UInt8, Data) -> Void) { self.onFrame = onFrame }

    func consume(_ data: Data) {
        buffer.append(data)
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 5 {
            let length = Int(buffer[offset + 1]) << 24 | Int(buffer[offset + 2]) << 16 | Int(buffer[offset + 3]) << 8 | Int(buffer[offset + 4])
            guard buffer.endIndex - offset - 5 >= length else { break }
            let type = buffer[offset]
            let payload = buffer.subdata(in: (offset + 5)..<(offset + 5 + length))
            offset += 5 + length
            onFrame(type, payload)
        }
        buffer.removeSubrange(buffer.startIndex..<offset)
    }
}
