import Foundation

/// The printer sends one full `print` report after `pushall`, then only the fields that changed.
/// `ReportDocument` keeps the merged picture.
struct ReportDocument {
    private(set) var print: [String: Any] = [:]
    /// From `get_version`: module name → (product name, software version).
    private(set) var modules: [String: (product: String, version: String)] = [:]
    private(set) var hasFullReport = false

    /// Merges one message from `device/<serial>/report`. Returns true if the print state changed.
    @discardableResult
    mutating func apply(_ message: [String: Any]) -> Bool {
        var changed = false
        if let p = message["print"] as? [String: Any] {
            let command = p["command"] as? String
            // Command acknowledgements echo the request back; only status pushes describe the printer.
            if command == nil || command == "push_status" {
                if (p["msg"] as? Int) == 0, p["gcode_state"] != nil {
                    // A full report replaces everything, so unplugged AMS units and cleared errors go away.
                    hasFullReport = true
                    print = p
                } else {
                    print = Self.merge(print, p)
                }
                changed = true
            }
        }
        if let info = message["info"] as? [String: Any], info["command"] as? String == "get_version",
           let list = info["module"] as? [[String: Any]] {
            for m in list {
                guard let name = m["name"] as? String else { continue }
                modules[name] = ((m["product_name"] as? String) ?? "", (m["sw_ver"] as? String) ?? "")
            }
            changed = true
        }
        return changed
    }

    mutating func reset() {
        print = [:]
        modules = [:]
        hasFullReport = false
    }

    /// Recursive merge. Arrays of objects carrying an `id` (or, for `lights_report`, a `node`) merge entry by
    /// entry; other arrays are replaced. The `device` extruder and nozzle `info` lists always arrive whole, so a
    /// hotend taken off the H2C rack has to disappear rather than linger.
    static func merge(_ base: [String: Any], _ delta: [String: Any]) -> [String: Any] {
        var out = base
        for (key, new) in delta {
            let idKey = key == "lights_report" ? "node" : "id"
            if let newDict = new as? [String: Any], let oldDict = out[key] as? [String: Any] {
                out[key] = merge(oldDict, newDict)
            } else if key != "info", let newArray = new as? [[String: Any]], let oldArray = out[key] as? [[String: Any]],
                      !newArray.isEmpty, newArray.allSatisfy({ $0[idKey] != nil }) {
                var merged = oldArray
                for item in newArray {
                    let id = "\(item[idKey]!)"
                    if let i = merged.firstIndex(where: { "\($0[idKey] ?? "")" == id }) {
                        merged[i] = merge(merged[i], item)
                    } else {
                        merged.append(item)
                    }
                }
                out[key] = merged
            } else {
                out[key] = new
            }
        }
        return out
    }
}

/// Turns the merged report into a `PrinterStatus`.
enum ReportParser {
    static func status(from doc: ReportDocument, hms: HMSCatalog) -> PrinterStatus {
        let p = doc.print
        var s = PrinterStatus()
        s.updatedAt = Date()
        s.state = JobState(gcodeState: string(p["gcode_state"]) ?? "IDLE")
        s.stageID = int(p["stg_cur"]) ?? int((p["stage"] as? [String: Any])?["_id"])
        if s.stageID == 0, string(p["print_type"]) == "idle", !s.state.isActive { s.stageID = 255 }
        s.taskID = [string(p["task_id"]), string(p["subtask_id"])].compactMap { $0 }.first { !$0.isEmpty && $0 != "0" }
        s.jobName = cleanJobName(string(p["subtask_name"]) ?? "", file: string(p["gcode_file"]) ?? "")
        s.progress = max(0, min(100, int(p["mc_percent"]) ?? 0))
        s.remainingMinutes = max(0, int(p["mc_remaining_time"]) ?? 0)
        s.layer = int(p["layer_num"]) ?? 0
        s.totalLayers = int(p["total_layer_num"]) ?? 0

        // Temperatures: the newer `device` block packs current (low 16 bits) and target (high 16 bits).
        let device = p["device"] as? [String: Any]
        parseExtruders(device, into: &s)
        if let active = s.activeExtruder {
            s.nozzle = active.temperature
        } else {
            s.nozzle = Temperature(current: double(p["nozzle_temper"]) ?? 0, target: double(p["nozzle_target_temper"]) ?? 0)
        }
        if let packed = int(((device?["bed"] as? [String: Any])?["info"] as? [String: Any])?["temp"]) ?? int(device?["bed_temp"]) {
            s.bed = unpack(packed)
        } else {
            s.bed = Temperature(current: double(p["bed_temper"]) ?? 0, target: double(p["bed_target_temper"]) ?? 0)
        }
        if let packed = int(((device?["ctc"] as? [String: Any])?["info"] as? [String: Any])?["temp"]) {
            s.chamber = unpack(packed).current
        } else if let t = double((p["info"] as? [String: Any])?["temp"]) ?? double(p["chamber_temper"]) {
            s.chamber = t
        }
        if let c = s.chamber, c <= 0 || c > 120 { s.chamber = nil }

        // Fans: the `airduct` parts already report percent; the legacy fields are 0-15.
        if let parts = (device?["airduct"] as? [String: Any])?["parts"] as? [[String: Any]], !parts.isEmpty {
            for part in parts {
                guard let id = int(part["id"]), let state = int(part["state"]) else { continue }
                let pct = max(0, min(100, state & 0xFF))
                switch id >> 4 {
                case 1: s.partFan = pct
                case 2: s.auxFan = pct
                case 3: s.exhaustFan = pct
                default: break
                }
            }
        } else {
            s.partFan = fan(p["cooling_fan_speed"])
            s.auxFan = fan(p["big_fan1_speed"])
            if let v = fan(p["big_fan2_speed"]), v > 0 { s.exhaustFan = v }
        }
        if s.partFan == nil { s.partFan = fan(p["cooling_fan_speed"]) }
        s.heatbreakFan = fan(p["heatbreak_fan_speed"])

        s.speed = SpeedLevel(rawValue: int(p["spd_lvl"]) ?? 2) ?? .standard
        if let lights = p["lights_report"] as? [[String: Any]] {
            let chamber = lights.filter { string($0["node"])?.hasPrefix("chamber_light") == true }
            if !chamber.isEmpty {
                s.chamberLightOn = chamber.contains { string($0["mode"]) != "off" }
                s.chamberLightNodes = chamber.compactMap { string($0["node"]) }
            }
        }
        if let stat = string(p["stat"]), let bits = UInt64(stat, radix: 16) {
            s.doorOpen = bits & 0x0080_0000 != 0
        }
        if let wifi = string(p["wifi_signal"]), let dbm = Int(wifi.replacingOccurrences(of: "dBm", with: "")) {
            s.wifiSignal = dbm
        }
        if let fun = string(p["fun"]), let bits = UInt64(fun, radix: 16) {
            s.controlsLocked = bits & 0x2000_0000 != 0
        }
        s.hasSDCard = p["sdcard"] as? Bool
        s.plateIndex = int(p["plate_idx"])
        if let ipcam = p["ipcam"] as? [String: Any], let url = string(ipcam["rtsp_url"]) {
            s.liveViewEnabled = url != "disable" && !url.isEmpty
        }
        if let n = s.activeExtruder?.nozzle {
            s.nozzleDiameter = n.diameter
            s.nozzleType = n.type
        } else {
            s.nozzleDiameter = double(p["nozzle_diameter"])
            s.nozzleType = string(p["nozzle_type"])
        }
        if let upgrade = p["upgrade_state"] as? [String: Any], int(upgrade["new_version_state"]) == 1 {
            s.updateAvailable = true
        }
        s.firmware = doc.modules["ota"]?.version

        parseFilament(p, device: device, doc: doc, into: &s)
        s.issues = issues(p, hms: hms, state: s.state)
        s.canceled = s.state == .failed && wasCanceled(doc)
        return s
    }

    // MARK: - Extruders

    /// `extruder.state` packs the extruder count in bits 0-3 and the active extruder in bits 4-7. Nozzle ids below
    /// 0x10 are the hotends mounted on the extruder with that id; 0x10 and up sit in the H2C rack.
    private static func parseExtruders(_ device: [String: Any]?, into s: inout PrinterStatus) {
        let root = device?["extruder"] as? [String: Any]
        let entries = (root?["info"] as? [[String: Any]]) ?? []
        let nozzles = (((device?["nozzle"] as? [String: Any])?["info"] as? [[String: Any]]) ?? []).compactMap { n -> NozzleInfo? in
            guard let id = int(n["id"]) else { return nil }
            return NozzleInfo(id: id, diameter: double(n["diameter"]), type: string(n["type"]).flatMap { $0.isEmpty ? nil : $0 })
        }
        let activeID = entries.count > 1 ? int(root?["state"]).map { ($0 >> 4) & 0xF } : nil
        s.extruders = entries.compactMap { e -> Extruder? in
            guard let id = int(e["id"]), let packed = int(e["temp"]) else { return nil }
            return Extruder(id: id, temperature: unpack(packed), nozzle: nozzles.first { $0.id == id },
                            isActive: activeID.map { $0 == id } ?? true)
        }.sorted { $0.id > $1.id }
        s.rackNozzles = nozzles.filter { $0.id >= 0x10 }.sorted { $0.id < $1.id }
    }

    // MARK: - Filament

    private static func parseFilament(_ p: [String: Any], device: [String: Any]?, doc: ReportDocument, into s: inout PrinterStatus) {
        let amsRoot = p["ams"] as? [String: Any]
        let units = (amsRoot?["ams"] as? [[String: Any]]) ?? []
        let existBits = string(amsRoot?["tray_exist_bits"]).flatMap { UInt64($0, radix: 16) }
        let rfidBits = string(amsRoot?["tray_is_bbl_bits"]).flatMap { UInt64($0, radix: 16) }
        s.ams = units.compactMap { u -> AMSUnit? in
            guard let id = int(u["id"]) else { return nil }
            let kind = amsKind(id: id, info: string(u["info"]), modules: doc.modules)
            let trays = (u["tray"] as? [[String: Any]]) ?? []
            let spools = trays.compactMap { t -> Spool? in
                guard let slot = int(t["id"]) else { return nil }
                let global = id >= 128 ? id : id * 4 + slot
                let bit = id >= 128 ? 16 + (id - 128) : id * 4 + slot
                var spool = spoolFrom(t, id: global, unit: id, slot: slot)
                if let existBits, existBits & (1 << UInt64(bit)) == 0 { spool.isLoaded = false }
                if let rfidBits { spool.isBambu = rfidBits & (1 << UInt64(bit)) != 0 && spool.isLoaded }
                if !spool.isLoaded { spool.material = ""; spool.name = ""; spool.remain = nil }
                return spool
            }.sorted { $0.slot < $1.slot }
            var humidity = int(u["humidity_raw"])
            if let h = humidity, h < 1 || h > 100 { humidity = nil }
            var level = int(u["humidity"])
            if let l = level, l < 1 || l > 5 { level = nil }
            var temp = double(u["temp"])
            if let t = temp, t <= 0 || t > 100 { temp = nil }
            return AMSUnit(id: id, kind: kind, humidity: humidity, humidityLevel: level.map { 6 - $0 }, temperature: temp,
                           dryingMinutesLeft: int(u["dry_time"]) ?? 0, spools: spools)
        }.sorted { $0.id < $1.id }

        let virtual = (p["vir_slot"] as? [[String: Any]])?.first ?? (p["vt_tray"] as? [String: Any])
        if let v = virtual {
            var ext = spoolFrom(v, id: Spool.externalID, unit: 255, slot: 0)
            ext.isLoaded = !(string(v["tray_type"]) ?? "").isEmpty
            ext.isBambu = ext.isLoaded && (string(v["tag_uid"]).map { !$0.allSatisfy { $0 == "0" } } ?? false)
            s.externalSpool = ext
        }

        // Active slot: the extruder's `snow` (unit << 8 | slot) on newer firmware, else `tray_now`.
        let extruders = ((device?["extruder"] as? [String: Any])?["info"] as? [[String: Any]]) ?? []
        let activeEntry = extruders.first { int($0["id"]) == s.activeExtruder?.id } ?? extruders.first
        if let snow = int(activeEntry?["snow"]), snow != 0xFFFF {
            let unit = snow >> 8, slot = snow & 0xFF
            if unit == 254 || unit == 255 {
                s.activeSpoolID = slot == 255 ? nil : Spool.externalID
            } else if unit >= 128 {
                s.activeSpoolID = unit
            } else {
                s.activeSpoolID = unit * 4 + (slot & 0x3)
            }
        } else if let now = int(amsRoot?["tray_now"]) {
            switch now {
            case 255: s.activeSpoolID = nil
            case 254: s.activeSpoolID = Spool.externalID
            default: s.activeSpoolID = now
            }
        }
        // Only meaningful while filament is actually in use.
        if !s.state.isActive && s.activeSpoolID != nil && s.activeSpool?.isLoaded != true { s.activeSpoolID = nil }
    }

    private static func spoolFrom(_ t: [String: Any], id: Int, unit: Int, slot: Int) -> Spool {
        let material = string(t["tray_type"]) ?? ""
        let state = int(t["state"])
        var loaded = !material.isEmpty
        if let state, state > 3 { loaded = state & 0x01 != 0 && state & 0x08 != 0 || state == 9 }
        let color = string(t["tray_color"]) ?? "00000000"
        let colors = (t["cols"] as? [String])?.filter { $0.count >= 6 } ?? []
        var remain = int(t["remain"])
        if let r = remain, r < 0 || r > 100 { remain = nil }
        let tag = string(t["tag_uid"]) ?? ""
        return Spool(id: id, unit: unit, slot: slot, material: material, name: string(t["tray_sub_brands"]) ?? "",
                     color: color, colors: colors.isEmpty ? [color] : colors, remain: remain, isLoaded: loaded,
                     isBambu: !tag.isEmpty && !tag.allSatisfy { $0 == "0" })
    }

    private static func amsKind(id: Int, info: String?, modules: [String: (product: String, version: String)]) -> AMSKind {
        if id >= 128 || modules["n3s/\(id)"] != nil { return .ht }
        if modules["n3f/\(id)"] != nil { return .pro2 }
        if modules["ams_f1/\(id)"] != nil { return .lite }
        if modules["ams/\(id)"] != nil { return .ams }
        if let info, let bits = UInt64(info, radix: 16) {
            switch bits & 0xF {
            case 2: return .lite
            case 3: return .pro2
            case 4: return .ht
            default: return .ams
            }
        }
        return .ams
    }

    // MARK: - Issues

    private static func issues(_ p: [String: Any], hms catalog: HMSCatalog, state: JobState) -> [PrinterIssue] {
        var out: [PrinterIssue] = []
        for entry in (p["hms"] as? [[String: Any]]) ?? [] {
            guard let attr = int(entry["attr"]), let code = int(entry["code"]) else { continue }
            let a = UInt32(truncatingIfNeeded: attr), c = UInt32(truncatingIfNeeded: code)
            if c & 0xFFFF < 0x4000 && c >> 16 == 0 { continue }
            let key = String(format: "%08X%08X", a, c)
            let pretty = String(format: "HMS_%04X_%04X_%04X_%04X", a >> 16, a & 0xFFFF, c >> 16, c & 0xFFFF)
            let severity = IssueSeverity(rawValue: Int(c >> 16)) ?? .common
            out.append(PrinterIssue(id: pretty, severity: severity,
                                    message: catalog.hmsText(key) ?? "The printer reported \(pretty).",
                                    wikiURL: HMSCatalog.wikiURL(for: pretty)))
        }
        if let error = int(p["print_error"]), error != 0 {
            let e = UInt32(truncatingIfNeeded: error)
            let key = String(format: "%08X", e)
            // 0300_400C and 0500_400E are the printer's echo of a user cancel, not a fault.
            if key != "0300400C" && key != "0500400E" {
                let pretty = String(format: "%04X_%04X", e >> 16, e & 0xFFFF)
                let level = (e & 0xF000) >> 12
                let severity: IssueSeverity = level == 0x4 ? .fatal : level == 0x8 ? .serious : .common
                if !out.contains(where: { $0.id.hasSuffix(pretty) }) {
                    out.append(PrinterIssue(id: pretty, severity: severity,
                                            message: catalog.errorText(key) ?? "The printer reported error \(pretty).",
                                            wikiURL: HMSCatalog.wikiURL(for: pretty)))
                }
            }
        }
        return out.sorted { $0.severity < $1.severity }
    }

    /// True when `print_error` is the code for a job the user cancelled.
    static func wasCanceled(_ doc: ReportDocument) -> Bool {
        guard let e = int(doc.print["print_error"]) else { return false }
        let key = String(format: "%08X", UInt32(truncatingIfNeeded: e))
        return key == "0300400C" || key == "0500400E"
    }

    // MARK: - Helpers

    /// Bambu Studio names jobs after the 3MF; strip path and extensions for display.
    static func cleanJobName(_ name: String, file: String) -> String {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty {
            n = (file as NSString).lastPathComponent
            if n.hasPrefix("plate_") { n = "" }
        }
        for ext in [".gcode.3mf", ".3mf", ".gcode"] where n.lowercased().hasSuffix(ext) {
            n = String(n.dropLast(ext.count))
        }
        // Bambu Studio turns spaces into underscores when it names the job after the project file.
        if !n.contains(" ") { n = n.replacingOccurrences(of: "_", with: " ") }
        return n
    }

    private static func unpack(_ packed: Int) -> Temperature {
        // Plain values (no target packed in) stay below 0x10000; a heater that's off reports target 0.
        Temperature(current: Double(packed & 0xFFFF), target: Double((packed >> 16) & 0xFFFF))
    }

    private static func fan(_ value: Any?) -> Int? {
        guard let raw = int(value) else { return nil }
        if raw <= 15 { return Int((Double(raw) / 15 * 100).rounded()) }
        return min(100, Int((Double(raw) / 255 * 100).rounded()))
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: return v
        case let v as Double: return Int(v)
        case let v as NSNumber: return v.intValue
        case let v as String: return Int(v) ?? Double(v).map { Int($0) }
        default: return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as NSNumber: return v.doubleValue
        case let v as String: return Double(v)
        default: return nil
        }
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let v as String: return v
        case let v as NSNumber: return v.stringValue
        default: return nil
        }
    }
}
