import SwiftUI

/// A rounded module like Control Center's: a faint fill and hairline that sit well on glass in light and dark.
struct PanelBackground: ViewModifier {
    var radius: CGFloat = 18
    var padding: CGFloat = 14
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(tint.map { $0.opacity(0.12) } ?? Color.primary.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.03)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                    )
            }
    }
}

extension View {
    func panel(radius: CGFloat = 18, padding: CGFloat = 14, tint: Color? = nil) -> some View {
        modifier(PanelBackground(radius: radius, padding: padding, tint: tint))
    }
}

/// Small uppercase heading above a group.
struct SectionLabel: View {
    var title: String
    var trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if let trailing {
                Text(trailing).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }
}

/// A temperature readout: value large, target small, a hairline gauge underneath.
/// One tile per extruder on dual-nozzle printers, otherwise a single "Nozzle" tile. Lays out as separate cells.
struct NozzleTiles: View {
    var status: PrinterStatus

    var body: some View {
        if status.hasMultipleExtruders {
            ForEach(status.extruders) { e in
                TemperatureTile(title: e.side, symbol: "flame.fill", temperature: e.temperature, tint: Palette.nozzle, maxValue: 300)
            }
        } else {
            TemperatureTile(title: "Nozzle", symbol: "flame.fill", temperature: status.nozzle, tint: Palette.nozzle, maxValue: 300)
        }
    }
}

struct TemperatureTile: View {
    var title: String
    var symbol: String
    var temperature: Temperature?
    var plain: Double? = nil
    var tint: Color
    var maxValue: Double = 300

    var body: some View {
        let current = temperature?.current ?? plain
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(heating ? tint : .secondary)
                    .symbolEffect(.pulse, options: .repeating, isActive: rising)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(current.map { "\(Int($0.rounded()))°" } ?? "–")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Text(targetText)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            GeometryReader { geo in
                let fraction = min(1, max(0, (current ?? 0) / maxValue))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(heating ? tint : Color.primary.opacity(0.3))
                        .frame(width: max(3, geo.size.width * fraction))
                    if let target = temperature?.target, target > 0 {
                        Capsule().fill(Color.primary.opacity(0.6))
                            .frame(width: 1.5, height: 7)
                            .offset(x: geo.size.width * min(1, target / maxValue) - 0.75)
                    }
                }
            }
            .frame(height: 3)
        }
        .panel(radius: 14, padding: 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(current.map { "\(Int($0)) degrees" } ?? "unknown"), \(targetText)")
    }

    private var heating: Bool { (temperature?.target ?? 0) > 0 }
    private var rising: Bool {
        guard let t = temperature, t.target > 0 else { return false }
        return t.current < t.target - 3
    }

    private var targetText: String {
        guard let t = temperature else { return plain == nil ? "No sensor" : "Read only" }
        if t.target <= 0 { return "Off" }
        if t.isAtTarget { return "At \(Int(t.target))°" }
        return t.current < t.target ? "Heating to \(Int(t.target))°" : "Cooling to \(Int(t.target))°"
    }
}

/// Round glass-like control used for the print controls.
struct ControlButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        ControlButtonBody(configuration: configuration, tint: tint, prominent: prominent)
    }
}

private struct ControlButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : tint)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(tint.gradient)
                          : tint == .primary ? AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06))
                          : AnyShapeStyle(tint.opacity(configuration.isPressed ? 0.22 : 0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(prominent ? 0 : 0.07), lineWidth: 0.75))
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// A row of label/value pairs for detail sections.
struct DetailRow: View {
    var title: String
    var value: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            }
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 12))
    }
}

/// Relative time like "3h ago", "yesterday".
func relativeTime(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

/// Asks the printer for a full report. The arrow spins until fresh data arrives, and the label says how
/// recent the data is, so it's clear what the button does and that it worked.
struct RefreshControl: View {
    @Environment(PrinterStore.self) private var store
    /// Icon only, for the menu bar panel's header.
    var compact = false

    @State private var spinning = false
    @State private var requestedAt: Date?

    var body: some View {
        HStack(spacing: 8) {
            if !compact {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(label(now: context.date))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            Button(action: refresh) {
                // The symbol effect stops with `spinning` (finishing its turn); a repeat-forever
                // rotation animation can't be cancelled and kept spinning after the refresh.
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate.clockwise.wholeSymbol, options: .repeat(.continuous), isActive: spinning)
            }
            .buttonStyle(HeaderIconStyle())
            .help("Ask the printer for a full status report")
            .disabled(!store.isConfigured)
        }
        .onChange(of: store.current?.lastHeard) { _, heard in
            // A reply after the request ends the spin.
            if spinning, let heard, let requestedAt, heard >= requestedAt { finish() }
        }
    }

    private func label(now: Date) -> String {
        if spinning { return "Refreshing…" }
        guard let heard = store.current?.lastHeard, store.isOnline else { return store.linkSummary }
        let seconds = Int(now.timeIntervalSince(heard))
        if seconds < 3 { return "Updated just now" }
        if seconds < 60 { return "Updated \(seconds)s ago" }
        return "Updated " + relativeTime(heard)
    }

    private func refresh() {
        guard !spinning else { return }
        requestedAt = Date()
        spinning = true
        store.refresh()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if spinning { finish() }
        }
    }

    private func finish() {
        spinning = false
    }
}
