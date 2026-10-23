import AVFoundation
import SwiftUI

/// Displays the app-owned camera session; leaving this view keeps the stream connected.
struct CameraCard: View {
    @Environment(PrinterStore.self) private var store
    private var cameraOn: Bool { store.cameraOn }
    private var stream: CameraStream { store.cameraStream }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Camera", trailing: trailing)
            ZStack {
                Color.black
                if cameraOn {
                    CameraLayerView(layer: stream.layer)
                        .opacity(stream.phase == .live ? 1 : 0)
                }
                overlay
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75))
            .overlay(alignment: .topTrailing) {
                if cameraOn && stream.phase == .live {
                    Button { store.cameraOn = false } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(CameraChipStyle())
                        .help("Turn the camera off")
                        .padding(10)
                }
            }
            .environment(\.colorScheme, .dark)
        }
        .onAppear { store.syncCamera() }
    }

    private var aspect: CGFloat {
        guard let size = stream.videoSize, size.height > 0 else { return 16 / 9 }
        return size.width / size.height
    }

    private var trailing: String? {
        guard cameraOn, stream.phase == .live, let size = stream.videoSize else { return nil }
        return "Live · \(Int(size.height))p via Bambu Cloud"
    }

    @ViewBuilder
    private var overlay: some View {
        if !cameraOn {
            VStack(spacing: 10) {
                Button { store.cameraOn = true } label: {
                    Image(systemName: "play.fill").font(.system(size: 20)).frame(width: 54, height: 54)
                }
                .buttonStyle(CameraPlayStyle())
                Text("Show the live camera").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                Text("Stays connected until you turn it off or quit Bambu Bar.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
        } else {
            switch stream.phase {
            case .idle:
                EmptyView()
            case .live:
                EmptyView()
            case .starting(let step):
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(step).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                }
            case .failed(let problem):
                failure(problem)
            }
        }
    }

    private func failure(_ problem: CameraStream.Problem) -> some View {
        let (symbol, title, detail) = describe(problem)
        return VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.white.opacity(0.55))
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            Text(detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                switch problem {
                case .signedOut, .rejected:
                    Button("Sign In…") { MainWindow.show(.settings) }
                case .needsStudio:
                    Button("Get Bambu Studio") { NSWorkspace.shared.open(URL(string: "https://bambulab.com/en/download/studio")!) }
                default:
                    Button("Try Again") { store.syncCamera(restart: true) }
                }
                Button("Turn Off") { store.cameraOn = false }
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(20)
    }

    private func describe(_ problem: CameraStream.Problem) -> (String, String, String) {
        switch problem {
        case .needsStudio:
            return ("shippingbox", "Bambu Studio is needed",
                    "The camera opens through Bambu Studio's network plugin. Install Bambu Studio and open it once so it downloads the plugin.")
        case .signedOut:
            return ("person.crop.circle.badge.questionmark", "Sign in to see the camera",
                    "The camera streams through Bambu Cloud, so it needs the Bambu account this printer is bound to. Sign in under Settings → Bambu account.")
        case .notOnAccount:
            return ("person.crop.circle.badge.exclamationmark", "Not on this Bambu account",
                    "This printer isn't bound to the signed-in Bambu account. Sign in with the account the printer uses in Bambu Handy.")
        case .rejected:
            return ("person.crop.circle.badge.xmark", "Bambu signed you out",
                    "Bambu didn't accept the saved sign-in. Sign in again under Settings → Bambu account.")
        case .busy:
            return ("video.slash", "Camera in use",
                    "Another app is already watching this printer's camera (Bambu Studio or Bambu Handy). Close it there and try again.")
        case .unavailable(let reason):
            return ("video.slash", "The camera didn't open", reason)
        }
    }


}

private struct CameraLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> NSView {
        let view = LayerHost()
        view.wantsLayer = true
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class LayerHost: NSView {
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.sublayers?.forEach { $0.frame = bounds }
            CATransaction.commit()
        }
    }
}

private struct CameraPlayStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.28 : 0.18)))
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.75))
            .contentShape(Circle())
    }
}

private struct CameraChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Circle().fill(.black.opacity(configuration.isPressed ? 0.7 : 0.5)))
            .contentShape(Circle())
    }
}
