import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// First run: pick the printer Bambu Bar found on the network (or type its address). The access code comes from
/// Bambu Studio or OrcaSlicer when either knows the printer (on this Mac, or a settings file from another Mac);
/// otherwise it's typed in from the printer's screen.
struct SetupPage: View {
    @Environment(PrinterStore.self) private var store
    @Environment(Navigation.self) private var navigation

    @State private var host = ""
    @State private var serial = ""
    @State private var name = ""
    @State private var modelCode = "N7"
    @State private var code = ""
    @State private var selected: String?
    @State private var manual = false
    @State private var openAtLogin = true
    /// The one found printer is picked automatically once; after that only the person changes the selection.
    @State private var autoPicked = false
    /// Where the access code came from ("Bambu Studio"…), nil when typed.
    @State private var codeSource: String?
    @State private var alternativeCodes: [String] = []
    @State private var importNote: String?
    @State private var dropTargeted = false
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if adding {
                PageHeader(title: "Add a Printer", subtitle: "Bambu Bar watches every printer you add; pick which one the menu bar shows in Settings.") {
                    Button("Cancel") { navigation.addingPrinter = false }
                }
            } else {
                hero
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel("1  Choose your printer")
                    Spacer()
                    if newPrinters.isEmpty {
                        ProgressView().controlSize(.small)
                    }
                    Button("Search Again") { store.searchForPrinters() }
                        .controlSize(.small)
                }
                if newPrinters.isEmpty && !manual {
                    HStack(spacing: 10) {
                        Image(systemName: "wifi").foregroundStyle(.secondary)
                        Text("Looking for printers on this network. Printers announce themselves every few seconds; make sure yours is on and on the same network as this Mac.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .panel(radius: 14, padding: 12)
                }
                ForEach(newPrinters) { printer in
                    discoveredRow(printer)
                }
                ForEach(slicerOnlyPrinters) { printer in
                    discoveredRow(DiscoveredPrinter(serial: printer.serial, host: printer.host ?? "", name: printer.serial,
                                                    modelCode: "", firmware: nil, connectMode: nil, lastSeen: .distantPast))
                }
                DisclosureGroup("Enter address manually", isExpanded: $manual) {
                    VStack(spacing: 10) {
                        field("IP address", text: $host, prompt: "192.168.1.50")
                        field("Serial number", text: $serial, prompt: "22E…")
                        field("Name", text: $name, prompt: "My P2S")
                    }
                    .padding(.top, 8)
                }
                .font(.system(size: 12, weight: .medium))
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("2  Access code")
                if let codeSource {
                    foundCode(codeSource)
                } else {
                    codeEntry
                }
            }

            if !adding {
                Toggle(isOn: $openAtLogin) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Open Bambu Bar at login").font(.system(size: 12.5, weight: .medium))
                        Text("It starts quietly in the menu bar, without a Dock icon.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .tint(Palette.accentDeep)
            }

            HStack(spacing: 12) {
                Button(action: connect) {
                    HStack(spacing: 6) {
                        if store.phase == .connecting { ProgressView().controlSize(.small).tint(.white) }
                        Text(store.phase == .connecting ? "Connecting…" : "Connect")
                    }
                    .frame(width: 150)
                }
                .buttonStyle(ControlButtonStyle(tint: Palette.accentDeep, prominent: true))
                .frame(width: 150)
                .disabled(!canConnect)
                .keyboardShortcut(.defaultAction)
                if let detail = store.linkDetail {
                    Label(detail, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.paused)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear {
            store.reloadSlicerPrinters()
            adoptCandidate()
        }
        .onChange(of: store.slicerPrinters) { fillCodeFromSlicer() }
        .onChange(of: navigation.setupCandidate) { adoptCandidate() }
        .onChange(of: newPrinters.map(\.serial)) {
            if !autoPicked, host.isEmpty, newPrinters.count == 1, let only = newPrinters.first {
                autoPicked = true
                pick(only)
            }
        }
    }

    private var hero: some View {
        HStack(spacing: 24) {
            PrinterArt(status: .sample, animated: true)
                .frame(width: 150, height: 180)
                .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to Bambu Bar")
                    .font(.system(size: 28, weight: .bold))
                Text("Your printer's progress, temperatures and filament, one click away in the menu bar. Bambu Bar talks to the printer directly over your network, no account needed.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 4)
    }

    private var adding: Bool { store.isConfigured }

    /// Printers on the network that aren't set up yet.
    private var newPrinters: [DiscoveredPrinter] {
        store.discovered.filter { store.session($0.serial) == nil }
    }

    /// Printers a slicer knows (with an address) that haven't announced themselves on the network.
    private var slicerOnlyPrinters: [SlicerPrinter] {
        store.slicerPrinters.filter { p in
            p.host != nil && store.session(p.serial) == nil && !store.discovered.contains { $0.serial == p.serial }
        }
    }

    /// The code is already known: say where from, and offer to type one instead.
    private func foundCode(_ source: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.accent.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Found in \(source)").font(.system(size: 13, weight: .semibold))
                Text("Bambu Bar uses the access code saved there for this printer. It's kept in your keychain and only ever sent to the printer.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Type a Code Instead") {
                codeSource = nil
                code = ""
                alternativeCodes = []
                codeFocused = true
            }
            .controlSize(.small)
        }
        .panel(radius: 16, padding: 14, tint: Palette.accent)
    }

    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("8-character access code", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 15, design: .monospaced))
                        .frame(maxWidth: 260)
                        .focused($codeFocused)
                        .onSubmit(connect)
                    Text("On the printer's screen open **Settings → Network** (the Wi-Fi/LAN page) and read the **Access Code**. It's stored in your keychain and only ever sent to the printer.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 440, alignment: .leading)
                }
                Spacer()
            }
            Divider()
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .foregroundStyle(dropTargeted ? Palette.accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Bambu Studio on another Mac?").font(.system(size: 12, weight: .semibold))
                    Text(LocalizedStringKey(importNote ?? "Drop its **BambuStudio.conf** here, or its BambuStudio folder. It's in **Library → Application Support → BambuStudio** in that user's home folder."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Choose File…", action: chooseSettingsFile)
                    .controlSize(.small)
            }
        }
        .panel(radius: 16, padding: 14, tint: dropTargeted ? Palette.accent : nil)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { importSettings(url) }
            }
            return true
        }
    }

    private func chooseSettingsFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Bambu Studio's settings"
        panel.message = "Pick BambuStudio.conf, or the BambuStudio folder it's in."
        panel.prompt = "Use"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        // Library is hidden in Finder; open where the file lives.
        panel.showsHiddenFiles = true
        panel.directoryURL = SlicerImport.suggestedFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importSettings(url)
    }

    private func importSettings(_ url: URL) {
        let count = store.importSlicerSettings(from: url)
        if count == 0 {
            importNote = "No Bambu Studio or OrcaSlicer access codes found in \(url.lastPathComponent)."
            return
        }
        importNote = nil
        if serial.isEmpty, let first = store.slicerPrinters.first {
            if let found = store.discovered.first(where: { $0.serial == first.serial }) {
                pick(found)
            } else if let host = first.host {
                pick(DiscoveredPrinter(serial: first.serial, host: host, name: first.serial, modelCode: "", lastSeen: Date()))
            } else {
                serial = first.serial
            }
        }
        fillCodeFromSlicer()
        if codeSource == nil {
            importNote = "\(url.lastPathComponent) doesn't know \(serial.isEmpty ? "this printer" : serial). Pick another printer or type the code."
        }
    }

    /// Fills in the code a slicer has for the chosen printer.
    private func fillCodeFromSlicer() {
        guard !serial.isEmpty, let printer = store.slicerPrinter(serial: serial) else { return }
        guard codeSource != nil || code.isEmpty else { return }  // never overwrite a typed code
        code = printer.accessCodes[0]
        alternativeCodes = Array(printer.accessCodes.dropFirst())
        codeSource = printer.source
    }

    private func discoveredRow(_ printer: DiscoveredPrinter) -> some View {
        let isSelected = selected == printer.serial
        let knownCode = store.slicerPrinter(serial: printer.serial)
        return Button { pick(printer) } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(isSelected ? Palette.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(printer.name).font(.system(size: 13, weight: .semibold))
                    Text("Bambu Lab \(printer.modelName) · \(printer.host) · \(printer.serial)")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                if let knownCode {
                    Label(printer.lastSeen == .distantPast ? "From \(knownCode.source)" : "Code in \(knownCode.source)",
                          systemImage: "key.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Palette.accent.opacity(0.12)))
                }
                if let mode = printer.connectMode {
                    Text(mode.lowercased() == "lan" ? "LAN Only" : "Cloud")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel(radius: 14, padding: 12, tint: isSelected ? Palette.accent : nil)
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            TextField(title, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .onChange(of: text.wrappedValue) { selected = nil }
            Spacer()
        }
    }

    private func pick(_ printer: DiscoveredPrinter) {
        host = printer.host
        serial = printer.serial
        name = printer.name
        modelCode = printer.modelCode
        if codeSource != nil {
            // A code that came with another printer doesn't belong to this one.
            code = ""
            codeSource = nil
            alternativeCodes = []
        }
        fillCodeFromSlicer()
        DispatchQueue.main.async {
            selected = printer.serial
            codeFocused = codeSource == nil
        }
    }

    private func adoptCandidate() {
        if let candidate = navigation.setupCandidate {
            pick(candidate)
            navigation.setupCandidate = nil
        } else if !autoPicked, host.isEmpty, let first = newPrinters.first, newPrinters.count == 1 {
            autoPicked = true
            pick(first)
        }
    }

    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !serial.trimmingCharacters(in: .whitespaces).isEmpty
            && code.trimmingCharacters(in: .whitespaces).count >= 4 && store.phase != .connecting
    }

    private func connect() {
        guard canConnect else { return }
        let config = PrinterConfig(host: host.trimmingCharacters(in: .whitespaces),
                                   serial: serial.trimmingCharacters(in: .whitespaces).uppercased(),
                                   name: name.trimmingCharacters(in: .whitespaces).isEmpty ? serial : name,
                                   modelCode: modelCode)
        let firstPrinter = !adding
        store.connect(to: config, accessCode: code, alternatives: alternativeCodes)
        navigation.addingPrinter = false
        if firstPrinter && openAtLogin && !LoginItem.shared.isEnabled { LoginItem.shared.setEnabled(true) }
    }
}
