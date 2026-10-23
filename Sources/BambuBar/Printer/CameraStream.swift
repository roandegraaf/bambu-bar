import AppKit
import AVFoundation
import CoreMedia
import Foundation
import Observation

/// Bambu Studio on this Mac: its network plugins open the camera, so the camera needs it installed and run once.
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

/// The printer's live camera over Bambu's cloud, like Bambu Studio and Bambu Handy show it.
///
/// The `bambu-camera` helper (next to the app's executable) runs Bambu Studio's own network plugins to get
/// the stream and sends back H.264; this decodes it into `layer`. PrinterStore keeps it alive until the camera is turned off or the app quits.
@MainActor
@Observable
final class CameraStream {
    enum Phase: Equatable {
        case idle
        case starting(String)
        case live
        case failed(Problem)
    }

    enum Problem: Equatable {
        case needsStudio
        case signedOut
        case notOnAccount
        case rejected
        case busy
        case unavailable(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var videoSize: CGSize?

    @ObservationIgnored let layer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var dataFolder: URL?
    @ObservationIgnored private var packager: VideoPackager?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var target: (serial: String, firmware: String?)?
    @ObservationIgnored private var lastFrame = Date.distantPast
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var restarts = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static let clientIDKey = "cameraClientID"

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
    }

    var isRunning: Bool { process != nil }

    func start(serial: String, firmware: String?) {
        halt()
        target = (serial, firmware)
        restarts = 0
        observeSleep()
        launch()
    }

    func stop() {
        target = nil
        halt()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        phase = .idle
        videoSize = nil
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
                guard let self, self.target != nil else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    guard self.target != nil, self.process == nil else { return }
                    self.restarts = 0
                    self.launch()
                }
            }
        })
    }

    // MARK: - Helper process

    private func launch() {
        guard let target else { return }
        guard let studio = BambuStudioInstall.find() else { return fail(.needsStudio) }
        let cloud = BambuCloud.shared
        guard cloud.isSignedIn, !cloud.needsSignIn else { return fail(.signedOut) }
        if !cloud.devices.isEmpty, cloud.device(serial: target.serial) == nil { return fail(.notOnAccount) }
        guard let userInfo = cloud.pluginUserInfo() else { return fail(.signedOut) }
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "bambu-camera") else {
            return fail(.unavailable("The camera helper is missing from the app."))
        }

        generation += 1
        let generation = generation
        phase = .starting("Starting…")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BambuBar-camera-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let conf = #"{"app":{"country_code":"US","language":"en_US","region":"US"}}"#
            try Data(conf.utf8).write(to: folder.appendingPathComponent("BambuStudio.conf"))
        } catch {
            return fail(.unavailable("Couldn't prepare the camera: \(error.localizedDescription)"))
        }
        dataFolder = folder

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let settings: [(String, String)] = [
            ("plugin_dir", studio.pluginFolder.path),
            ("cert_dir", studio.certFolder.path),
            ("data_dir", folder.path),
            ("dev_id", target.serial),
            ("dev_ver", target.firmware ?? ""),
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

        let packager = VideoPackager(layer: layer)
        packager.onStatus = { [weak self] json in
            DispatchQueue.main.async { self?.received(status: json, generation: generation) }
        }
        packager.onPicture = { [weak self] size in
            DispatchQueue.main.async { self?.picture(size: size, generation: generation) }
        }
        let reader = FrameReader(packager: packager)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { reader.consume(data) }
        }
        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async { self?.exited(code: code, generation: generation) }
        }

        do {
            try process.run()
        } catch {
            return fail(.unavailable("The camera helper didn't start: \(error.localizedDescription)"))
        }
        stdin.fileHandleForWriting.write(Data(config.utf8))
        self.process = process
        input = stdin.fileHandleForWriting
        self.packager = packager
        lastFrame = Date()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStall() }
        }
    }

    /// Ends the helper and its session without changing what's shown.
    private func halt() {
        generation += 1
        watchdog?.invalidate()
        watchdog = nil
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
        packager = nil
        if let folder = dataFolder {
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { try? FileManager.default.removeItem(at: folder) }
        }
        dataFolder = nil
        layer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
    }

    private func fail(_ problem: Problem) {
        halt()
        phase = .failed(problem)
    }

    private func received(status json: Data, generation: Int) {
        guard generation == self.generation,
              let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let state = object["state"] as? String else { return }
        let detail = object["detail"] as? String ?? ""
        switch state {
        case "loading": phase = .starting("Starting…")
        case "signing_in": phase = .starting("Signing in to Bambu…")
        case "connecting": phase = .starting("Connecting to the printer…")
        case "minting": if phase != .live { phase = .starting("Asking Bambu for the camera…") }
        case "opening": if phase != .live { phase = .starting("Opening the camera…") }
        case "streaming": if phase != .live { phase = .starting("Waiting for the first picture…") }
        case "error:auth": fail(.rejected)
        case "error:busy": fail(.busy)
        default:
            if state.hasPrefix("error:") { fail(.unavailable(detail.isEmpty ? "The camera didn't open." : detail)) }
        }
    }

    private func picture(size: CGSize, generation: Int) {
        guard generation == self.generation else { return }
        lastFrame = Date()
        restarts = 0
        if videoSize != size { videoSize = size }
        if phase != .live { phase = .live }
    }

    private func exited(code: Int32, generation: Int) {
        guard generation == self.generation else { return }
        if case .failed = phase { return }
        process = nil
        fail(.unavailable(code == 0 ? "The camera stream ended." : "The camera helper stopped (\(code))."))
    }

    /// The helper re-opens a dropped stream itself; this catches one that stalls without an error.
    private func checkStall() {
        guard process != nil else { return }
        let silence = Date().timeIntervalSince(lastFrame)
        let limit: TimeInterval = phase == .live ? 20 : 120
        guard silence > limit else { return }
        guard restarts < 3 else { return fail(.unavailable("The camera stopped sending pictures.")) }
        restarts += 1
        halt()
        launch()
    }

    /// `~/Library/Logs/Bambu Bar`: the helper's trace of the last session (no tokens or camera links).
    private static var logFolder: URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Bambu Bar")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Bambu Studio sends one stable id per installation with every camera session.
    private static var clientID: String {
        if let id = UserDefaults.standard.string(forKey: clientIDKey) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: clientIDKey)
        return id
    }
}

/// Splits the helper's output into frames: [type u8][length u32 BE][payload].
private final class FrameReader: @unchecked Sendable {
    private var buffer = Data()
    private let packager: VideoPackager

    init(packager: VideoPackager) { self.packager = packager }

    func consume(_ data: Data) {
        buffer.append(data)
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 5 {
            let length = Int(buffer[offset + 1]) << 24 | Int(buffer[offset + 2]) << 16 | Int(buffer[offset + 3]) << 8 | Int(buffer[offset + 4])
            guard buffer.endIndex - offset - 5 >= length else { break }
            let type = buffer[offset]
            let payload = buffer.subdata(in: (offset + 5)..<(offset + 5 + length))
            offset += 5 + length
            packager.handle(type: type, payload: payload)
        }
        buffer.removeSubrange(buffer.startIndex..<offset)
    }
}

/// Turns the stream's H.264 (Annex B, or length-prefixed) into sample buffers for the display layer.
private final class VideoPackager: @unchecked Sendable {
    var onStatus: ((Data) -> Void)?
    var onPicture: ((CGSize) -> Void)?

    private let layer: AVSampleBufferDisplayLayer
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var needsKeyframe = true
    private var lastReport = Date.distantPast

    init(layer: AVSampleBufferDisplayLayer) { self.layer = layer }

    func handle(type: UInt8, payload: Data) {
        switch type {
        case UInt8(ascii: "S"): onStatus?(payload)
        case UInt8(ascii: "I") where payload.count >= 20: parameters(from: payload.dropFirst(20))
        case UInt8(ascii: "V") where payload.count > 9: video(Data(payload.dropFirst(9)))
        default: break
        }
    }

    private func parameters(from format: Data) {
        guard !format.isEmpty else { return }
        if format.first == 1, format.count > 7 {
            parseAVCC(Data(format))
        } else {
            for nal in Self.units(Data(format)) { remember(nal) }
        }
    }

    /// An `avcC` record: version, profile, compat, level, length size, SPS count + list, PPS count + list.
    private func parseAVCC(_ record: Data) {
        let bytes = [UInt8](record)
        var i = 5
        guard i < bytes.count else { return }
        let spsCount = Int(bytes[i] & 0x1F); i += 1
        for _ in 0..<spsCount {
            guard i + 2 <= bytes.count else { return }
            let n = Int(bytes[i]) << 8 | Int(bytes[i + 1]); i += 2
            guard i + n <= bytes.count else { return }
            remember(Data(bytes[i..<(i + n)])); i += n
        }
        guard i < bytes.count else { return }
        let ppsCount = Int(bytes[i]); i += 1
        for _ in 0..<ppsCount {
            guard i + 2 <= bytes.count else { return }
            let n = Int(bytes[i]) << 8 | Int(bytes[i + 1]); i += 2
            guard i + n <= bytes.count else { return }
            remember(Data(bytes[i..<(i + n)])); i += n
        }
    }

    private func remember(_ nal: Data) {
        guard let header = nal.first else { return }
        switch header & 0x1F {
        case 7 where nal != sps: sps = nal; format = nil
        case 8 where nal != pps: pps = nal; format = nil
        default: return
        }
        makeFormat()
    }

    private func makeFormat() {
        guard format == nil, let sps, let pps else { return }
        var description: CMFormatDescription?
        sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                                                                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                    nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        format = description
        needsKeyframe = true
    }

    private func video(_ data: Data) {
        var block = Data()
        var keyframe = false
        for nal in Self.units(data) {
            guard let header = nal.first else { continue }
            switch header & 0x1F {
            case 7, 8: remember(nal)
            case 9: break
            default:
                if header & 0x1F == 5 { keyframe = true }
                var length = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &length) { block.append(contentsOf: $0) }
                block.append(nal)
            }
        }
        guard let format, !block.isEmpty else { return }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            needsKeyframe = true
        }
        if needsKeyframe {
            guard keyframe else { return }
            needsKeyframe = false
        }
        guard let sample = Self.sampleBuffer(block, format: format) else { return }
        renderer.enqueue(sample)
        let now = Date()
        if now.timeIntervalSince(lastReport) > 1 {
            lastReport = now
            let size = CMVideoFormatDescriptionGetDimensions(format)
            onPicture?(CGSize(width: Int(size.width), height: Int(size.height)))
        }
    }

    private static func sampleBuffer(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// NAL units of an access unit: Annex B start codes if present, else 4-byte big-endian lengths.
    static func units(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        let n = bytes.count
        guard n >= 4 else { return [] }
        let annexB = (bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 1) || (bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 1)
        var units: [Data] = []
        if annexB {
            var starts: [(code: Int, payload: Int)] = []
            var i = 0
            while i + 2 < n {
                if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                    let code = i > 0 && bytes[i - 1] == 0 ? i - 1 : i
                    starts.append((code, i + 3))
                    i += 3
                } else {
                    i += 1
                }
            }
            for (index, start) in starts.enumerated() {
                let end = index + 1 < starts.count ? starts[index + 1].code : n
                if end > start.payload { units.append(Data(bytes[start.payload..<end])) }
            }
        } else {
            var i = 0
            while i + 4 <= n {
                let length = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
                i += 4
                guard length > 0, i + length <= n else { break }
                units.append(Data(bytes[i..<(i + length)]))
                i += length
            }
        }
        return units
    }
}
