import AppKit
import SwiftUI

/// Borderless panel that can take keyboard focus without activating the app.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Spotlight-style floating text entry: press the keyboard button, type,
/// hit return, and the text lands on the Apple TV.
@MainActor
final class TypePanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private weak var session: RemoteSession?

    func show(session: RemoteSession) {
        self.session = session
        if panel == nil { build(session: session) }
        guard let panel else { return }
        position(panel)
        session.setPanelVisible(true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        session?.setPanelVisible(false)
    }

    private func build(session: RemoteSession) {
        let content = TypePanelView(
            session: session,
            onSubmit: { [weak self] text in
                self?.session?.send("text_set=\(text)")
                self?.hide()
            },
            onCancel: { [weak self] in self?.hide() }
        )

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true

        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        let size = host.fittingSize
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.contentView = effect
        p.delegate = self
        panel = p
    }

    /// Spotlight-ish placement: centered, upper third of the main screen.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: f.midX - size.width / 2,
            y: f.minY + f.height * 0.7 - size.height
        ))
    }

    /// Click anywhere else and it goes away, like Spotlight.
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

private struct TypePanelView: View {
    @ObservedObject var session: RemoteSession
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Image(systemName: "keyboard.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                TextField("Type on Apple TV…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24))
                    .focused($focused)
                    .onSubmit {
                        let sent = text
                        text = ""
                        guard !sent.isEmpty else { return }
                        onSubmit(sent)
                    }
            }
            Text(statusLine)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(width: 560, alignment: .leading)
        .onAppear {
            text = ""
            focused = true
        }
        .onExitCommand { onCancel() }
    }

    private var statusLine: String {
        if session.state != .connected {
            return "Not connected to the Apple TV"
        }
        if !session.keyboardActive {
            return "No text field is focused on the TV — open a search there first"
        }
        return "⏎ sends to the Apple TV · esc closes"
    }
}
