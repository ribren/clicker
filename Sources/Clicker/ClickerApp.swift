import SwiftUI

@main
struct ClickerApp: App {
    @StateObject private var model: AppModel

    init() {
        let snapshot = CommandLine.arguments.contains("--snapshot")
        _model = StateObject(wrappedValue: AppModel(snapshot: snapshot))
        if snapshot {
            Self.scheduleSnapshot()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            RemoteView()
                .environmentObject(model)
        } label: {
            Image(systemName: "appletvremote.gen4.fill")
        }
        .menuBarExtraStyle(.window)
    }

    /// `Clicker --snapshot out.png` renders the real UI with canned data to a
    /// PNG (for the README/marketing) and exits. IconStore's local-app icons
    /// load synchronously; warm them, give the run loop a beat, render.
    @MainActor
    private static func scheduleSnapshot() {
        _ = IconStore.shared.icon(for: "com.apple.TVWatchList")
        _ = IconStore.shared.icon(for: "com.apple.TVMusic")
        let output = CommandLine.arguments.last(where: { $0.hasSuffix(".png") }) ?? "clicker-snapshot.png"

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let view = RemoteView().environmentObject(AppModel(snapshot: true))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                fputs("snapshot render failed\n", stderr)
                exit(1)
            }
            do {
                try png.write(to: URL(fileURLWithPath: output))
                print("wrote \(output)")
                exit(0)
            } catch {
                fputs("snapshot write failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }
}
