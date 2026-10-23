import SwiftUI

struct SettingsPage: View {
    @Environment(PrinterStore.self) private var store
    @Environment(LoginItem.self) private var loginItem

    @State private var name = ""
    @State private var host = ""
    @State private var code = ""
    @State private var editingConnection = false
    @State private var confirmForget = false
    @State private var cloudEmail = ""
    @State private var cloudPassword = ""
    @State private var cloudCode = ""

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Settings")

            group("Printers", symbol: "printer.dotmatrix.fill") {
                ForEach(store.sessions) { session in
                    printerRow(session)
                    Divider()
                }
                HStack {
                    Text(store.isConfigured ? "Bambu Bar watches all of them at once." : "No printer set up yet.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Printer…") { MainWindow.addPrinter() }
                }
            }

            if let config = store.config {
                group(store.hasMultiplePrinters ? config.name : "Printer", symbol: "printer.fill") {
                    row("Name") {
                        TextField("Name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onSubmit { store.rename(config.serial, to: name) }
                    }
                    row("Model") { Text("Bambu Lab \(config.modelName)").foregroundStyle(.secondary) }
                    row("Serial number") { Text(config.serial).foregroundStyle(.secondary).textSelection(.enabled) }
                    row("Status") {
                        HStack(spacing: 6) {
                            Circle().fill(store.isOnline ? Palette.accent : Palette.paused).frame(width: 7, height: 7)
                            Text(store.linkSummary).foregroundStyle(.secondary)
                        }
                    }
                    if editingConnection {
                        row("IP address") {
                            TextField("IP address", text: $host).textFieldStyle(.roundedBorder).frame(width: 220)
                        }
                        row("Access code") {
                            SecureField("Access code", text: $code).textFieldStyle(.roundedBorder).frame(width: 220)
                                .onSubmit(applyConnection)
                        }
                        HStack {
                            Spacer()
                            Button("Cancel") { editingConnection = false }
                            Button("Reconnect", action: applyConnection)
                                .buttonStyle(.borderedProminent)
                                .tint(Palette.accentDeep)
                                .disabled(host.isEmpty || code.count < 4)
                        }
                    } else {
                        row("IP address") {
                            HStack(spacing: 10) {
                                Text(config.host).foregroundStyle(.secondary).textSelection(.enabled)
                                Button("Change…") {
                                    host = config.host
                                    code = store.accessCode ?? ""
                                    editingConnection = true
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    Divider()
                    HStack {
                        Text("Bambu Bar follows the printer if its IP address changes.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Forget Printer…", role: .destructive) { confirmForget = true }
                    }
                }
            }

            accountGroup

            group("Menu bar", symbol: "menubar.rectangle") {
                if store.hasMultiplePrinters {
                    row("Printer in the menu bar") {
                        Picker("", selection: $store.menuBarSerial) {
                            Text("Automatic").tag(String?.none)
                            Divider()
                            ForEach(store.sessions) { Text($0.config.name).tag(Optional($0.id)) }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    if store.menuBarSerial == nil {
                        Text("Automatic shows whichever printer is busy (paused first, then printing), otherwise the one you last looked at.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                row("While printing, show") {
                    Picker("", selection: $store.menuBarStyle) {
                        ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                row("Open at login") {
                    Toggle("", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                        .toggleStyle(.switch).labelsHidden().tint(Palette.accentDeep)
                }
                if loginItem.status == .requiresApproval {
                    HStack {
                        Text("Allow Bambu Bar in System Settings → General → Login Items.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open System Settings") { loginItem.openSystemSettings() }.controlSize(.small)
                    }
                }
                if let error = loginItem.error {
                    Text(error).font(.system(size: 11.5)).foregroundStyle(Palette.failed)
                }
                Text("At login Bambu Bar starts in the menu bar only, without a Dock icon. Open it from the menu bar or Spotlight to see this window.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            group("Notifications", symbol: "bell.badge.fill") {
                toggle("Print finished", isOn: $store.notifyFinished)
                toggle("Print failed, canceled or an error", isOn: $store.notifyFailed)
                toggle("Print paused (filament runout, user)", isOn: $store.notifyPaused)
                toggle("Print started", isOn: $store.notifyStarted)
            }

            group("Controls", symbol: "slider.horizontal.3") {
                toggle("Ask before stopping a print", isOn: $store.confirmStop)
                Text("Printers that only take signed commands get pause, stop and speed changes through Bambu Cloud, signed by Bambu Studio's network plugin, so they need Bambu Studio installed and the Bambu account below. Status and the chamber light always go over the local network.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            group("Desktop widget", symbol: "widget.small") {
                HStack {
                    Text("See what each widget size shows, your printers as widgets, and how to add one.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Widgets") { MainWindow.show(.widgets) }
                }
            }
        }
        .onAppear { name = store.config?.name ?? "" }
        .onChange(of: store.config) { name = store.config?.name ?? "" }
        .alert("Forget \(store.printerName)?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { if let serial = store.config?.serial { store.forget(serial) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bambu Bar disconnects and removes the access code from your keychain. Print history stays.")
        }
    }

    private func printerRow(_ session: PrinterSession) -> some View {
        let isCurrent = session.id == store.current?.id
        return HStack(spacing: 12) {
            PrinterArt(status: session.status, model: session.config.modelName, dimmed: !session.isOnline, animated: false)
                .frame(width: 28, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.config.name).font(.system(size: 12.5, weight: .semibold))
                    if store.hasMultiplePrinters && session.id == store.menuBarSession?.id {
                        Image(systemName: "menubar.rectangle")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help("Shown in the menu bar")
                    }
                }
                Text("Bambu Lab \(session.config.modelName) · \(session.config.host)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                SessionDot(session: session)
                Text(session.shortState).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            if store.hasMultiplePrinters {
                Button(isCurrent ? "Showing" : "Show") { store.select(session.id) }
                    .controlSize(.small)
                    .disabled(isCurrent)
            }
        }
    }

    @ViewBuilder
    private var accountGroup: some View {
        let cloud = BambuCloud.shared
        group("Bambu account", symbol: "person.crop.circle") {
            switch cloud.step {
            case .signedIn:
                if let session = cloud.session {
                    row("Signed in as") {
                        Text(session.name == session.email ? session.email : "\(session.name) (\(session.email))")
                            .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if let config = store.config {
                    row(store.hasMultiplePrinters ? "\(config.name) camera" : "Camera") {
                        if cloud.device(serial: config.serial) != nil {
                            Label("On this account", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                        } else if cloud.devices.isEmpty {
                            Text("—").foregroundStyle(.secondary)
                        } else {
                            Label("Not on this account", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.paused)
                        }
                    }
                }
                Divider()
                HStack {
                    Text("Used only for the live camera.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Sign Out") { cloud.signOut() }
                }
            case .signedOut:
                row("Email") {
                    TextField("Email", text: $cloudEmail).textFieldStyle(.roundedBorder).frame(width: 220)
                        .textContentType(.username)
                }
                row("Password") {
                    SecureField("Optional", text: $cloudPassword).textFieldStyle(.roundedBorder).frame(width: 220)
                        .textContentType(.password)
                        .onSubmit(signIn)
                }
                HStack(alignment: .top) {
                    Text("Leave the password empty and Bambu emails you a code.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Sign In", action: signIn)
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accentDeep)
                        .disabled(cloud.busy || !cloudEmail.contains("@"))
                }
            case .code(let email), .tfa(let email, _):
                let tfa = if case .tfa = cloud.step { true } else { false }
                Text(tfa ? "Enter the code from your authenticator app for \(email)." : "Bambu sent a code to \(email).")
                    .font(.system(size: 12.5))
                row(tfa ? "2FA code" : "Code") {
                    TextField("123456", text: $cloudCode).textFieldStyle(.roundedBorder).frame(width: 220)
                        .textContentType(.oneTimeCode)
                        .onSubmit(submitCode)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { cloud.cancelSignIn(); cloudCode = "" }
                    Button("Verify", action: submitCode)
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accentDeep)
                        .disabled(cloud.busy || cloudCode.trimmingCharacters(in: .whitespaces).count < 4)
                }
            }
            if cloud.busy {
                ProgressView().controlSize(.small)
            }
            if let error = cloud.error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(Palette.failed)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if cloud.step != .signedIn {
                Text("The camera streams through Bambu Cloud, the way Bambu Studio and Bambu Handy show it, so it needs the account the printer is bound to. Bambu Bar sends the sign-in only to Bambu and keeps it in your keychain; status and controls stay on your network.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func signIn() {
        let cloud = BambuCloud.shared
        guard !cloud.busy, cloudEmail.contains("@") else { return }
        Task {
            await cloud.start(email: cloudEmail, password: cloudPassword)
            if cloud.step == .signedIn { cloudPassword = "" }
        }
    }

    private func submitCode() {
        let cloud = BambuCloud.shared
        guard !cloud.busy else { return }
        let code = cloudCode
        Task {
            if case .tfa = cloud.step { await cloud.submitTfa(code) } else { await cloud.submitCode(code) }
            if cloud.step == .signedIn { cloudCode = ""; cloudPassword = "" }
        }
    }

    private func applyConnection() {
        guard var config = store.config, !host.isEmpty, code.count >= 4 else { return }
        config.host = host.trimmingCharacters(in: .whitespaces)
        store.connect(to: config, accessCode: code)
        editingConnection = false
    }

    private func group<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 12) { content() }
                .panel(radius: 16, padding: 16)
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 12.5))
            Spacer(minLength: 12)
            content().font(.system(size: 12.5))
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 12.5))
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().tint(Palette.accentDeep)
        }
    }
}

/// Approximates the desktop widget chrome around a widget view.
struct WidgetFrame<Content: View>: View {
    var width: CGFloat
    var height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(width: width, height: height)
            .background(WidgetBackdrop())
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .environment(\.colorScheme, .dark)
    }
}
