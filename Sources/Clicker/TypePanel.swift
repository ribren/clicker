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
            onDone: { [weak self] in self?.hide() }
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
    let onDone: () -> Void

    @State private var text = ""
    @State private var pendingSend: DispatchWorkItem?
    @State private var suppressNextChange = false
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
                        flush()
                        onDone()
                    }
                Button(action: clearBoth) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear here and on the Apple TV")
            }
            Text(statusLine)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(width: 560, alignment: .leading)
        .onChange(of: text) { _, newValue in
            if suppressNextChange {
                suppressNextChange = false
                return
            }
            // Live typing: coalesce bursts so fast typing sends ~8/s, not 1:1.
            pendingSend?.cancel()
            let work = DispatchWorkItem {
                if newValue.isEmpty {
                    session.send("text_clear")
                } else {
                    session.send("text_set=\(newValue)")
                }
            }
            pendingSend = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
        .onAppear {
            if !text.isEmpty {
                // Leftover from last time: reset quietly, don't clear the TV.
                suppressNextChange = true
                text = ""
            }
            focused = true
        }
        .onExitCommand {
            flush()
            onDone()
        }
    }

    /// Push whatever is pending right now (return/esc shouldn't lose the tail).
    private func flush() {
        pendingSend?.cancel()
        pendingSend = nil
        if !text.isEmpty {
            session.send("text_set=\(text)")
        }
    }

    /// The (x): wipe the local field AND the TV's field, resetting the sync.
    private func clearBoth() {
        pendingSend?.cancel()
        pendingSend = nil
        suppressNextChange = true
        text = ""
        session.send("text_clear")
        focused = true
    }

    private var statusLine: String {
        if session.state != .connected {
            return "Not connected to the Apple TV"
        }
        if !session.keyboardActive {
            return "No text field is focused on the TV — open a search there first"
        }
        return "Typing live on the Apple TV · ⏎ or esc closes"
    }
}
