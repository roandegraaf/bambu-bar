import AppKit
import SwiftUI

/// About the app: version details for bug reports, how it works, privacy and credits.
struct AboutPage: View {
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 20) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bambu Bar").font(.system(size: 30, weight: .bold))
                    Text("Version \(AppInfo.version) (\(AppInfo.build))").foregroundStyle(.secondary)
                    Text("Your Bambu Lab printer, one click away in the menu bar.")
                        .font(.system(size: 13)).foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 4)

            section("This copy") {
                DetailRow(title: "Version", value: "\(AppInfo.version) (\(AppInfo.build))")
                DetailRow(title: "System", value: "\(AppInfo.system) · \(AppInfo.architecture)")
                DetailRow(title: "License", value: "MIT, free and open source")
                HStack {
                    Text("For bug reports").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button(copied ? "Copied" : "Copy Version Info", action: copy)
                        .controlSize(.small)
                }
            }

            section("How it works") {
                paragraph("Bambu Bar connects straight to your printer on the local network, the same way Bambu Studio does in LAN mode: an encrypted MQTT connection on port 8883, signed in with the printer's access code. The printer's certificate is checked against Bambu Lab's own certificate authority.")
                paragraph("The printer streams its status about once a second. Bambu Bar shows it in the menu bar, keeps a short history of your prints, and shares a snapshot with its widget through a private container on this Mac.")
            }

            section("Privacy") {
                paragraph("No analytics. Status and controls stay on your network: Bambu Bar talks directly to your printer, and the access code is stored in your keychain. Only the optional live camera goes through Bambu Cloud, with a Bambu account you sign in to.")
            }

            section("Credits") {
                paragraph("Protocol details and the English HMS error texts come from the open-source ha-bambulab project (MIT), with thanks to Bambuddy and bambu-cli for documenting the newer printers.")
                paragraph("Bambu Lab, Bambu Studio and P2S are trademarks of Bambu Lab. Bambu Bar is an independent project, not affiliated with or endorsed by Bambu Lab.")
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 10) { content() }
                .panel(radius: 16, padding: 16)
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppInfo.summary, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

enum AppInfo {
    private static let info = Bundle.main.infoDictionary ?? [:]
    static let version = info["CFBundleShortVersionString"] as? String ?? "dev"
    static let build = info["CFBundleVersion"] as? String ?? "dev"
    static let system: String = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
    }()
    static let architecture: String = {
        #if arch(arm64)
            "Apple Silicon"
        #else
            "Intel"
        #endif
    }()
    static var summary: String { "Bambu Bar \(version) (\(build)) · \(system) · \(architecture)" }
}
