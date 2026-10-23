import AppKit
import AVFoundation
import CoreMedia
import Foundation
import Observation
import VideoToolbox

/// The printer's live camera over Bambu Cloud, like Bambu Studio and Bambu Handy show it.
///
/// It rides on the `CloudAgent` session: the helper sends back H.264, which this decodes once and shows on every
/// attached `screens` layer. PrinterStore keeps it alive until the camera is turned off or the app quits.
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

        init(_ problem: CloudAgent.Problem) {
            switch problem {
            case .needsStudio: self = .needsStudio
            case .signedOut: self = .signedOut
            case .notOnAccount: self = .notOnAccount
            case .rejected: self = .rejected
            case .unavailable(let reason): self = .unavailable(reason)
            }
        }
    }

    private(set) var videoSize: CGSize?
    private(set) var isActive = false
    private var cameraPhase: Phase = .idle

    @ObservationIgnored let screens = CameraScreens()
    @ObservationIgnored private let agent: CloudAgent
    @ObservationIgnored private var firmware: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastFrame = Date.distantPast
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var restarts = 0

    init(agent: CloudAgent) {
        self.agent = agent
        agent.onCameraState = { [weak self] state, detail in self?.received(state: state, detail: detail) }
    }

    /// The cloud session's progress until it's ready, then the camera's own.
    var phase: Phase {
        guard isActive else { return .idle }
        switch agent.phase {
        case .idle: return .starting("Starting…")
        case .starting(let step): return .starting(step)
        case .failed(let problem): return .failed(Problem(problem))
        case .ready: return cameraPhase
        }
    }

    func start(firmware: String?) {
        stop()
        isActive = true
        self.firmware = firmware
        restarts = 0
        openCamera()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStall() }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        generation += 1
        watchdog?.invalidate()
        watchdog = nil
        agent.video.set(nil)
        agent.stopCamera()
        cameraPhase = .idle
        videoSize = nil
        screens.clear()
    }

    /// A fresh decoder and a new camera request on the running session.
    private func openCamera() {
        generation += 1
        let generation = generation
        let packager = VideoPackager(screens: screens)
        packager.onPicture = { [weak self] size in
            DispatchQueue.main.async { self?.picture(size: size, generation: generation) }
        }
        agent.video.set { type, payload in packager.handle(type: type, payload: payload) }
        cameraPhase = .starting("Asking Bambu for the camera…")
        lastFrame = Date()
        agent.startCamera(firmware: firmware)
    }

    private func fail(_ problem: Problem) {
        watchdog?.invalidate()
        watchdog = nil
        agent.video.set(nil)
        agent.stopCamera()
        cameraPhase = .failed(problem)
    }

    private func received(state: String, detail: String) {
        guard isActive else { return }
        switch state {
        case "starting":
            cameraPhase = .starting("Asking Bambu for the camera…")
            lastFrame = Date()
        case "minting": if cameraPhase != .live { cameraPhase = .starting("Asking Bambu for the camera…") }
        case "opening": if cameraPhase != .live { cameraPhase = .starting("Opening the camera…") }
        case "streaming": if cameraPhase != .live { cameraPhase = .starting("Waiting for the first picture…") }
        case "error:busy": fail(.busy)
        default:
            if state.hasPrefix("error:") { fail(.unavailable(detail.isEmpty ? "The camera didn't open." : detail)) }
        }
    }

    private func picture(size: CGSize, generation: Int) {
        guard generation == self.generation, isActive else { return }
        lastFrame = Date()
        restarts = 0
        if videoSize != size { videoSize = size }
        if cameraPhase != .live { cameraPhase = .live }
    }

    /// The helper re-opens a dropped stream itself; this catches one that stalls without an error.
    private func checkStall() {
        guard isActive, agent.phase == .ready else {
            lastFrame = Date()
            return
        }
        let silence = Date().timeIntervalSince(lastFrame)
        let limit: TimeInterval = cameraPhase == .live ? 20 : 120
        guard silence > limit else { return }
        guard restarts < 3 else { return fail(.unavailable("The camera stopped sending pictures.")) }
        restarts += 1
        openCamera()
    }
}

/// Every view showing the camera has its own display layer; they all get the same decoded frames.
/// The latest frame is kept so a view that opens mid-stream shows a picture at once instead of waiting for a keyframe.
final class CameraScreens: @unchecked Sendable {
    private let lock = NSLock()
    private let layers = NSHashTable<AVSampleBufferDisplayLayer>.weakObjects()
    private var latest: CVPixelBuffer?

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        let frame = lock.withLock {
            layers.add(layer)
            return latest
        }
        if let frame { Self.show(frame, on: layer) }
    }

    func detach(_ layer: AVSampleBufferDisplayLayer) {
        lock.withLock { layers.remove(layer) }
    }

    func show(_ frame: CVPixelBuffer) {
        let targets = lock.withLock {
            latest = frame
            return layers.allObjects
        }
        for layer in targets { Self.show(frame, on: layer) }
    }

    func clear() {
        lock.withLock { latest = nil }
    }

    private static func show(_ frame: CVPixelBuffer, on layer: AVSampleBufferDisplayLayer) {
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
        guard let sample = sampleBuffer(frame) else { return }
        renderer.enqueue(sample)
    }

    private static func sampleBuffer(_ frame: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame,
                                                           formatDescriptionOut: &format) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

/// Turns the stream's H.264 (Annex B, or length-prefixed) into decoded frames for `CameraScreens`.
private final class VideoPackager: @unchecked Sendable {
    var onPicture: ((CGSize) -> Void)?

    private let screens: CameraScreens
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var decoder: VTDecompressionSession?
    private var needsKeyframe = true
    private var lastReport = Date.distantPast

    init(screens: CameraScreens) { self.screens = screens }

    deinit {
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
    }

    func handle(type: UInt8, payload: Data) {
        switch type {
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
        resetDecoder()
    }

    private func resetDecoder() {
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        decoder = nil
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
        if needsKeyframe {
            guard keyframe else { return }
            needsKeyframe = false
        }
        guard let sample = Self.sampleBuffer(block, format: format) else { return }
        decode(sample, format: format)
    }

    private func decode(_ sample: CMSampleBuffer, format: CMVideoFormatDescription) {
        if decoder == nil {
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
            var session: VTDecompressionSession?
            VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                         imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session)
            decoder = session
        }
        guard let decoder else { return }
        var frameFailed = false
        let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard status == noErr, let image else { frameFailed = true; return }
            self?.decoded(image)
        }
        if status != noErr || frameFailed { resetDecoder() }
    }

    private func decoded(_ frame: CVPixelBuffer) {
        screens.show(frame)
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 1 else { return }
        lastReport = now
        onPicture?(CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame)))
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
