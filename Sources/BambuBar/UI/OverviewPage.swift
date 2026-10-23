import SwiftUI

/// The window's main page: the job up front, then temperatures, filament, machine details and issues.
struct OverviewPage: View {
    @Environment(PrinterStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: store.printerName, subtitle: subtitle) {
                RefreshControl()
            }
            if let status = store.status, store.isOnline {
                JobHero(status: status, compact: false)
                if status.state.isActive {
                    PrintControls(status: status)
                        .frame(maxWidth: 520)
                    if status.controlsLocked {
                        lockedNote
                    }
                }
                ForEach(status.issues) { IssueBanner(issue: $0) }
                CameraCard()
                metrics(status)
                if !status.ams.isEmpty || status.externalSpool?.isLoaded == true {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Filament")
                        FilamentStrip(status: status)
                    }
                }
                machine(status)
            } else {
                ConnectionCard()
            }
        }
    }

    private var subtitle: String {
        guard let config = store.config else { return "" }
        var parts = ["Bambu Lab \(config.modelName)", config.host]
        if let fw = store.status?.firmware { parts.append("Firmware \(fw)") }
        return parts.joined(separator: " · ")
    }

    private var lockedNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
            Text("The printer only accepts pause, stop and speed changes from apps in **LAN Only** mode with **Developer Mode** on (printer screen → Settings → Network). Status and the chamber light work either way.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private func metrics(_ s: PrinterStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Temperatures & airflow")
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    TemperatureTile(title: "Nozzle", symbol: "flame.fill", temperature: s.nozzle, tint: Palette.nozzle, maxValue: 300)
                    TemperatureTile(title: "Bed", symbol: "heat.waves", temperature: s.bed, tint: Palette.bed, maxValue: 110)
                    TemperatureTile(title: "Chamber", symbol: "thermometer.medium", temperature: nil, plain: s.chamber, tint: Palette.chamber, maxValue: 65)
                    FanTile(status: s)
                }
            }
        }
    }

    private func machine(_ s: PrinterStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Printer")
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 9) {
                    DetailRow(title: "Speed", value: "\(store.speed.title) (\(store.speed.percent)%)", symbol: "speedometer")
                    DetailRow(title: "Nozzle", value: nozzleText(s), symbol: "pencil.tip")
                    DetailRow(title: "Door", value: s.doorOpen.map { $0 ? "Open" : "Closed" } ?? "—", symbol: "door.left.hand.closed")
                    DetailRow(title: "Chamber light", value: store.chamberLightOn ? "On" : "Off", symbol: "lightbulb")
                }
                .panel(radius: 16, padding: 13)
                VStack(spacing: 9) {
                    DetailRow(title: "Network", value: s.wifiSignal.map { "\(WiFi.describe($0)) (\($0) dBm)" } ?? "—", symbol: "wifi")
                    DetailRow(title: "Storage", value: s.hasSDCard == true ? "SD card inserted" : s.hasSDCard == false ? "No SD card" : "—", symbol: "sdcard")
                    DetailRow(title: "Live View", value: s.liveViewEnabled == true ? "On" : s.liveViewEnabled == false ? "Off" : "—", symbol: "video")
                    DetailRow(title: "Firmware", value: (s.firmware ?? "—") + (s.updateAvailable ? " · Update available" : ""), symbol: "cpu")
                }
                .panel(radius: 16, padding: 13)
            }
        }
    }

    private func nozzleText(_ s: PrinterStatus) -> String {
        var parts: [String] = []
        if let d = s.nozzleDiameter { parts.append(String(format: "%.1f mm", d)) }
        if let t = s.nozzleType { parts.append(NozzleType.describe(t)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

struct FanTile: View {
    var status: PrinterStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Image(systemName: "fan.fill").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle((status.partFan ?? 0) > 0 ? Palette.chamber : .secondary)
                    .rotationEffect(.degrees(0))
                Text("Fans").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            fan("Part", status.partFan)
            fan("Aux", status.auxFan)
            if let exhaust = status.exhaustFan { fan("Exhaust", exhaust) } else if let hotend = status.heatbreakFan { fan("Hotend", hotend) }
        }
        .panel(radius: 14, padding: 11)
    }

    private func fan(_ title: String, _ value: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Palette.chamber.opacity(0.85)).frame(width: geo.size.width * CGFloat(value ?? 0) / 100)
                }
            }
            .frame(height: 4)
            Text(value.map { "\($0)%" } ?? "–").font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
    }
}

enum NozzleType {
    /// "HS01" → "Hardened steel", "HH01" → "Hardened steel, high flow".
    static func describe(_ code: String) -> String {
        let upper = code.uppercased()
        guard upper.count >= 4 else {
            return upper.contains("HARDENED") ? "Hardened steel" : upper.contains("STAINLESS") ? "Stainless steel" : code
        }
        let chars = Array(upper)
        let material: String
        switch String(chars[2...3]) {
        case "00": material = "Stainless steel"
        case "01": material = "Hardened steel"
        case "05": material = "Tungsten carbide"
        default: material = code
        }
        switch chars[1] {
        case "U": return material + ", TPU high flow"
        case "H", "E": return material + ", high flow"
        default: return material
        }
    }
}
