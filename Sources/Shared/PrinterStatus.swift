import Foundation

/// What the printer is doing, folded from `print.gcode_state`.
enum JobState: String, Codable, Equatable, Sendable {
    case idle, preparing, printing, paused, finished, failed

    init(gcodeState: String) {
        switch gcodeState.uppercased() {
        case "PREPARE", "SLICING": self = .preparing
        case "RUNNING": self = .printing
        case "PAUSE": self = .paused
        case "FINISH": self = .finished
        case "FAILED": self = .failed
        default: self = .idle
        }
    }

    /// A job is on the plate and not over yet.
    var isActive: Bool { self == .preparing || self == .printing || self == .paused }

    var title: String {
        switch self {
        case .idle: return "Ready"
        case .preparing: return "Preparing"
        case .printing: return "Printing"
        case .paused: return "Paused"
        case .finished: return "Finished"
        case .failed: return "Failed"
        }
    }
}

/// The four motion profiles (`spd_lvl`).
enum SpeedLevel: Int, Codable, CaseIterable, Identifiable, Sendable {
    case silent = 1, standard, sport, ludicrous

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .silent: return "Silent"
        case .standard: return "Standard"
        case .sport: return "Sport"
        case .ludicrous: return "Ludicrous"
        }
    }
    /// Nominal speed relative to Standard, as Bambu Studio shows it.
    var percent: Int {
        switch self {
        case .silent: return 50
        case .standard: return 100
        case .sport: return 124
        case .ludicrous: return 166
        }
    }
    var symbol: String {
        switch self {
        case .silent: return "tortoise.fill"
        case .standard: return "figure.walk"
        case .sport: return "figure.run"
        case .ludicrous: return "hare.fill"
        }
    }
}

struct Temperature: Codable, Equatable, Sendable {
    var current: Double
    /// Zero when the heater is off.
    var target: Double

    var isHeating: Bool { target > 0 }
    /// Within a couple of degrees of the target.
    var isAtTarget: Bool { target > 0 && abs(current - target) <= 2 }
}

struct NozzleInfo: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var diameter: Double?
    var type: String?
}

/// One hotend. On dual-nozzle printers id 0 is the right extruder and id 1 the left.
struct Extruder: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var temperature: Temperature
    var nozzle: NozzleInfo?
    var isActive: Bool

    var side: String { id == 1 ? "Left" : "Right" }
}

/// One filament slot: an AMS tray or the external spool holder.
struct Spool: Codable, Equatable, Identifiable, Sendable {
    /// Global slot number: `unit * 4 + slot` for AMS units 0-3, `128 + n` for AMS HT, 254 for the external spool.
    var id: Int
    var unit: Int
    var slot: Int
    /// "PLA", "PETG"…; empty when the slot is empty or unknown.
    var material: String
    /// "PLA Matte"…; empty for third-party spools.
    var name: String
    /// `RRGGBBAA`.
    var color: String
    /// More than one entry for multicolour spools.
    var colors: [String]
    /// Percent remaining, nil when the printer can't tell (non-RFID spools).
    var remain: Int?
    var isLoaded: Bool
    var isBambu: Bool

    static let externalID = 254

    var isExternal: Bool { id == Self.externalID }
    var remainText: String {
        if !isLoaded { return "Empty" }
        if let remain { return "\(remain)%" }
        return "—"
    }
    var displayName: String { name.isEmpty ? material : name }
    /// "A1", "A2"… like the printer's screen; "Ext" for the external spool.
    var label: String {
        if isExternal { return "Ext" }
        if unit >= 128 { return "HT\(unit - 127)" }
        let letter = String(UnicodeScalar(UInt8(65 + min(unit, 25))))
        return "\(letter)\(slot + 1)"
    }
}

enum AMSKind: String, Codable, Sendable {
    case ams, lite, pro2, ht

    var title: String {
        switch self {
        case .ams: return "AMS"
        case .lite: return "AMS Lite"
        case .pro2: return "AMS 2 Pro"
        case .ht: return "AMS HT"
        }
    }
}

struct AMSUnit: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var kind: AMSKind
    /// Relative humidity in percent (`humidity_raw`), when the unit reports it.
    var humidity: Int?
    /// 1 (dry) to 5 (wet), Bambu Studio's scale.
    var humidityLevel: Int?
    var temperature: Double?
    var dryingMinutesLeft: Int
    var spools: [Spool]

    /// "AMS A", "AMS 2 Pro B"…
    var title: String {
        if id >= 128 { return "\(kind.title) \(id - 127)" }
        return "\(kind.title) \(String(UnicodeScalar(UInt8(65 + min(id, 25)))))"
    }
}

enum IssueSeverity: Int, Codable, Comparable, Sendable {
    case fatal = 1, serious, common, info

    static func < (a: IssueSeverity, b: IssueSeverity) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .fatal: return "Error"
        case .serious: return "Warning"
        case .common: return "Notice"
        case .info: return "Info"
        }
    }
}

/// A Health Management System message or the current print error.
struct PrinterIssue: Codable, Equatable, Identifiable, Sendable {
    /// `HMS_0300_0100_0001_0007` or `0700_8006`.
    var id: String
    var severity: IssueSeverity
    var message: String
    var wikiURL: URL?
}

/// Everything Bambu Bar shows about the printer, derived from the merged MQTT report.
struct PrinterStatus: Codable, Equatable, Sendable {
    var state: JobState = .idle
    var stageID: Int?
    var jobName: String = ""
    var progress: Int = 0
    var remainingMinutes: Int = 0
    var layer: Int = 0
    var totalLayers: Int = 0
    /// The active extruder's temperature.
    var nozzle = Temperature(current: 0, target: 0)
    /// Every extruder, left to right; empty on firmware without the `device.extruder` block.
    var extruders: [Extruder] = []
    /// Spare hotends parked in the H2C nozzle rack.
    var rackNozzles: [NozzleInfo] = []
    var bed = Temperature(current: 0, target: 0)
    var chamber: Double?
    /// Fan speeds in percent.
    var partFan: Int?
    var auxFan: Int?
    var exhaustFan: Int?
    var heatbreakFan: Int?
    var speed: SpeedLevel = .standard
    var chamberLightOn: Bool?
    /// The LED nodes that make up the chamber light (H2 printers report a second one, `chamber_light2`).
    var chamberLightNodes: [String]?
    var doorOpen: Bool?
    var wifiSignal: Int?
    var ams: [AMSUnit] = []
    var externalSpool: Spool?
    var activeSpoolID: Int?
    var issues: [PrinterIssue] = []
    /// The printer refuses unsigned print commands (Developer Mode off).
    var controlsLocked: Bool = false
    var firmware: String?
    var nozzleDiameter: Double?
    var nozzleType: String?
    var liveViewEnabled: Bool?
    var hasSDCard: Bool?
    var plateIndex: Int?
    var updateAvailable: Bool = false
    /// The printer's id for the current job (`task_id`, else `subtask_id`).
    var taskID: String?
    /// The job ended because someone stopped it (print_error 0300_400C), not because of a fault.
    var canceled: Bool = false
    /// When this status was last refreshed from the printer.
    var updatedAt = Date()

    /// "Canceled" for a job someone stopped, otherwise the state's own title.
    var stateTitle: String { state == .failed && canceled ? "Canceled" : state.title }

    var stageText: String? {
        guard let stageID, stageID != 255, stageID != -1 else { return nil }
        return Self.stageNames[stageID]
    }

    /// The line under the job name: "Heating hotend", "Paused: filament runout", "Layer 170 of 305"…
    var detailText: String {
        switch state {
        case .printing:
            if let stageText, stageID != 0 { return stageText }
            if totalLayers > 0 { return "Layer \(layer) of \(totalLayers)" }
            return "Printing"
        case .preparing:
            return stageText ?? "Preparing"
        case .paused:
            if let stageText, stageText.hasPrefix("Paused") { return stageText }
            return "Paused"
        case .finished: return "Finished"
        case .failed: return canceled ? "Canceled" : issues.first?.message ?? "Print failed"
        case .idle: return stageText ?? "Ready to print"
        }
    }

    var activeSpool: Spool? {
        guard let activeSpoolID else { return nil }
        if activeSpoolID == Spool.externalID { return externalSpool }
        return ams.lazy.flatMap(\.spools).first { $0.id == activeSpoolID }
    }

    var allSpools: [Spool] { ams.flatMap(\.spools) + (externalSpool.map { [$0] } ?? []) }

    var hasMultipleExtruders: Bool { extruders.count > 1 }

    var activeExtruder: Extruder? { extruders.first(where: \.isActive) ?? extruders.min { $0.id < $1.id } }

    var mostSevereIssue: PrinterIssue? { issues.min { $0.severity < $1.severity } }

    /// Estimated completion, from the remaining minutes at `updatedAt`.
    var estimatedEnd: Date? {
        guard state.isActive, remainingMinutes > 0 else { return nil }
        return updatedAt.addingTimeInterval(TimeInterval(remainingMinutes * 60))
    }

    /// Progress expected at `date`, extrapolated linearly over the remaining time. Lets widgets advance between updates.
    func projectedProgress(at date: Date) -> Double {
        let now = Double(progress) / 100
        guard state == .printing, let end = estimatedEnd, end > updatedAt else { return now }
        let fraction = min(1, max(0, date.timeIntervalSince(updatedAt) / end.timeIntervalSince(updatedAt)))
        return min(0.99, now + (1 - now) * fraction)
    }

    static let stageNames: [Int: String] = [
        0: "Printing", 1: "Auto bed leveling", 2: "Preheating heatbed", 3: "Vibration compensation",
        4: "Changing filament", 5: "M400 pause", 6: "Paused: filament ran out", 7: "Heating hotend",
        8: "Calibrating extrusion", 9: "Scanning bed surface", 10: "Inspecting first layer",
        11: "Identifying build plate", 12: "Calibrating Micro Lidar", 13: "Homing toolhead",
        14: "Cleaning nozzle tip", 15: "Checking extruder temperature", 16: "Paused by user",
        17: "Paused: front cover fell off", 18: "Calibrating Micro Lidar", 19: "Calibrating flow ratio",
        20: "Paused: nozzle temperature fault", 21: "Paused: heatbed temperature fault", 22: "Unloading filament",
        23: "Paused: skipped steps", 24: "Loading filament", 25: "Calibrating motor noise",
        26: "Paused: AMS offline", 27: "Paused: heatbreak fan too slow", 28: "Paused: chamber temperature fault",
        29: "Cooling chamber", 30: "Paused by G-code", 31: "Motor noise showoff",
        32: "Paused: nozzle clumping", 33: "Paused: cutter error", 34: "Paused: first layer error",
        35: "Paused: nozzle clog", 36: "Measuring motion precision", 37: "Enhancing motion precision",
        38: "Measuring motion accuracy", 39: "Calibrating nozzle offset", 40: "High-temperature bed leveling",
        41: "Checking quick-release lever", 42: "Checking door and top cover", 43: "Calibrating laser",
        44: "Checking platform", 45: "Checking BirdsEye camera", 46: "Calibrating BirdsEye camera",
        47: "Bed leveling, phase 1", 48: "Bed leveling, phase 2", 49: "Heating chamber",
        50: "Cooling heatbed", 51: "Printing calibration lines", 52: "Checking material",
        53: "Calibrating Live View camera", 54: "Waiting for heatbed temperature", 55: "Checking material position",
        56: "Calibrating cutter offset", 57: "Measuring surface", 58: "Thermal preconditioning",
        59: "Homing blade holder", 60: "Calibrating camera offset", 61: "Calibrating blade holder",
        62: "Hotend pick-and-place test", 63: "Waiting for chamber temperature", 64: "Preparing hotend",
        65: "Calibrating clumping detection", 66: "Purifying chamber air", 67: "Measuring rotary attachment",
        68: "Moving to purge chute", 69: "Cooling nozzle", 70: "Centering toolhead",
        71: "Arc fitting", 72: "Detecting hotend type", 73: "Detecting build plate alignment",
        74: "Checking heatbed for objects", 75: "Checking heatbed underside", 76: "Pre-extruding",
        77: "Preparing AMS",
    ]
}

/// The last job the printer ran, kept so an idle printer can still say how its last print went.
struct JobRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var startedAt: Date
    var endedAt: Date?
    var outcome: Outcome
    var totalLayers: Int
    var filamentColor: String?
    var filamentMaterial: String?
    /// The printer's task id, to tell two jobs with the same name apart.
    var taskID: String?
    /// Which printer ran it.
    var printerSerial: String?

    enum Outcome: String, Codable, Sendable {
        case running, finished, failed, canceled
        /// The app wasn't running when it ended, so how it ended isn't known.
        case ended

        var title: String {
            switch self {
            case .running: return "In progress"
            case .finished: return "Finished"
            case .failed: return "Failed"
            case .canceled: return "Canceled"
            case .ended: return "Ended"
            }
        }
    }

    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}
