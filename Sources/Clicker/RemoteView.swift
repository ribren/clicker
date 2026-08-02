import SwiftUI

// MARK: - Palette (itsytv-style: light gray card, charcoal buttons)

private enum Palette {
    static let panel = Color(red: 0.851, green: 0.851, blue: 0.859)
    static let button = Color(red: 0.16, green: 0.16, blue: 0.175)
    static let buttonHover = Color(red: 0.25, green: 0.25, blue: 0.27)
    static let pad = Color(red: 0.188, green: 0.188, blue: 0.203)
    static let padInner = Color(red: 0.137, green: 0.137, blue: 0.15)
    static let ink = Color(white: 0.13)
    static let inkSecondary = Color(white: 0.42)
}

/// One spacing unit everywhere: between buttons, and from buttons to the
/// panel edge. Panel width falls out of button size + gaps.
private enum Layout {
    static let button: CGFloat = 66
    static let gap: CGFloat = 20
    static let contentWidth: CGFloat = button * 2 + gap          // 152
    static let panelWidth: CGFloat = contentWidth + gap * 2      // 192
    static let rockerHalf: CGFloat = (button * 2 + gap) / 2      // 76
    static let padSize: CGFloat = contentWidth                   // 152
    static let nowPlayingHeight: CGFloat = 104
    // clickpad + button grid + now-playing card + gaps between them
    static let bodyHeight: CGFloat =
        padSize + 16 + (button * 3 + gap * 2) + 16 + nowPlayingHeight
}

// MARK: - Button styles & shared controls

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Charcoal circle button (the Siri Remote button grid + header grid button).
private struct DarkButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = Layout.button
    var fontSize: CGFloat = 18
    var active = false
    var activeColor: Color = .accentColor
    var shortcut: KeyboardShortcut?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(active ? activeColor : (hovering ? Palette.buttonHover : Palette.button))
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .keyboardShortcut(shortcut)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Small light utility button (header row). `active` flips it dark while a
/// toggled state (like the apps drawer) is on.
private struct LightButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 24
    var fontSize: CGFloat = 10
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(active ? .white : Palette.ink)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(
                        active
                            ? AnyShapeStyle(Palette.button)
                            : AnyShapeStyle(Color.white.opacity(hovering ? 0.75 : 0.45))
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Chevron arrow on the clickpad — subtle until hovered.
private struct DialGlyph: View {
    let symbol: String
    var shortcut: KeyboardShortcut?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.55))
                .frame(width: 46, height: 46)
                .background(Circle().fill(.white.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .keyboardShortcut(shortcut)
        .onHover { hovering = $0 }
    }
}

/// Tall charcoal +/− volume rocker; height matches two grid buttons + gap.
private struct VolumeRocker: View {
    let send: (String) -> Void
    @State private var hoverUp = false
    @State private var hoverDown = false

    var body: some View {
        VStack(spacing: 0) {
            Button { send("volume_up") } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: Layout.button, height: Layout.rockerHalf)
                    .background(hoverUp ? Palette.buttonHover : Palette.button)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .onHover { hoverUp = $0 }
            .help("Volume up")

            Button { send("volume_down") } label: {
                Image(systemName: "minus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: Layout.button, height: Layout.rockerHalf)
                    .background(hoverDown ? Palette.buttonHover : Palette.button)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .onHover { hoverDown = $0 }
            .help("Volume down")
        }
        .clipShape(Capsule())
    }
}

// MARK: - Scroll-wheel routing

/// Turns trackpad/mouse scrolling over the panel into d-pad commands:
/// scroll down → "down", up → "up", sideways → "left"/"right".
/// Stays out of the way while the apps drawer (a real ScrollView) is open.
@MainActor
final class ScrollRouter: ObservableObject {
    var isEnabled: () -> Bool = { false }
    var send: (String) -> Void = { _ in }

    private var monitor: Any?
    private var accX: CGFloat = 0
    private var accY: CGFloat = 0

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isEnabled() else { return event }
        // Only act on the remote panel itself, not menus or other windows.
        guard let window = event.window, window.isKeyWindow else { return event }
        // Swallow the momentum tail so one flick isn't five presses.
        guard event.momentumPhase.isEmpty else { return nil }

        if event.phase == .began {
            accX = 0
            accY = 0
        }
        accX += event.scrollingDeltaX
        accY += event.scrollingDeltaY
        // Precise deltas are points per event; wheel notches are lines.
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 26 : 0.5

        if abs(accY) >= abs(accX) {
            if accY <= -threshold { fire("down") }
            else if accY >= threshold { fire("up") }
        } else {
            if accX <= -threshold { fire("right") }
            else if accX >= threshold { fire("left") }
        }
        return nil
    }

    private func fire(_ command: String) {
        send(command)
        accX = 0
        accY = 0
    }
}

// MARK: - Main view

struct RemoteView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("showApps") private var showApps = false
    @StateObject private var scrollRouter = ScrollRouter()
    @ObservedObject private var icons = IconStore.shared
    @State private var manualType = false
    @State private var typedText = ""
    @State private var appSearch = ""
    @State private var powerPressing = false
    @FocusState private var typing: Bool
    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 12) {
            deviceRow
            toolbarRow

            if let pairing = model.pairing {
                PairingView(pairing: pairing)
            } else if model.devices.isEmpty {
                emptyState
            } else if !model.selectedIsPaired {
                pairPrompt
            } else {
                if model.session.keyboardActive || manualType {
                    typeField
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Fixed-size stage: the apps drawer swaps in for the remote
                // controls so the panel never has to change height.
                ZStack {
                    if showApps {
                        appsDrawer
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        remoteControls
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .frame(width: Layout.contentWidth, height: Layout.bodyHeight)
                .animation(.spring(response: 0.32, dampingFraction: 0.85), value: showApps)
                .animation(
                    .spring(response: 0.35, dampingFraction: 0.8),
                    value: model.session.keyboardActive || manualType
                )
            }
        }
        .padding(.horizontal, Layout.gap)
        .padding(.vertical, 14)
        .frame(width: Layout.panelWidth)
        .background(Palette.panel)
        .colorScheme(.light)
        .onAppear {
            scrollRouter.send = { [weak model] in model?.session.send($0) }
            scrollRouter.isEnabled = { [weak model] in
                guard let model else { return false }
                return model.selectedIsPaired
                    && model.pairing == nil
                    && !UserDefaults.standard.bool(forKey: "showApps")
            }
            scrollRouter.install()
        }
        .onDisappear { scrollRouter.remove() }
    }

    // MARK: Header rows

    /// The connected device, on its own row above everything else.
    private var deviceRow: some View {
        Menu {
            ForEach(model.devices) { device in
                Button {
                    model.selectedID = device.id
                } label: {
                    if device.id == model.selectedID {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                statusDot
                Text(model.selectedDevice?.name ?? "No device")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Palette.inkSecondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(subtitle)
    }

    private var toolbarRow: some View {
        HStack(spacing: 8) {
            if model.selectedIsPaired, model.pairing == nil {
                powerMenu
            }
            if model.selectedIsPaired, model.pairing == nil {
                LightButton(symbol: "square.grid.2x2", help: showApps ? "Hide apps" : "Show apps",
                            active: showApps) {
                    showApps.toggle()
                }
            }
            if model.scanning {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
            } else {
                LightButton(symbol: "arrow.clockwise", help: "Scan for Apple TVs") {
                    model.scanNow()
                }
            }
            overflowMenu
        }
    }

    private var overflowMenu: some View {
        Menu {
            if model.selectedIsPaired, model.pairing == nil {
                Button("Re-pair \(model.selectedDevice?.name ?? "Device")…") {
                    model.beginPairing()
                }
            }
            Divider()
            Button("Buy Me a Coffee ☕") {
                NSWorkspace.shared.open(URL(string: "https://github.com/sponsors/ribren")!)
            }
            Divider()
            Button("Quit Clicker") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.45)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: 24, height: 24)
    }

    private var subtitle: String {
        switch model.session.state {
        case .connected: return model.selectedDevice?.model ?? "Connected"
        case .connecting: return "Connecting…"
        case .failed: return "Connection failed"
        case .idle: return model.selectedIsPaired ? "Not connected" : "Not paired"
        }
    }

    private var statusDot: some View {
        let color: Color
        switch model.session.state {
        case .connected: color = .green
        case .connecting: color = .yellow
        case .failed: color = .red
        case .idle: color = Palette.inkSecondary.opacity(0.4)
        }
        return Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.6), radius: 3)
    }

    // MARK: Empty / pairing states

    private var emptyState: some View {
        VStack(spacing: 10) {
            if !PyATV.isAvailable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.orange.opacity(0.8))
                Text("pyatv isn't installed")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text("Clicker uses pyatv to talk to Apple TVs.\nInstall it, then scan again:")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
                Text("pipx install pyatv")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.6)))
                Button("Scan Again") { model.scanNow() }
                    .controlSize(.small)
            } else {
                Image(systemName: "appletv.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Palette.inkSecondary.opacity(0.5))
                Text(model.scanning ? "Looking for Apple TVs…" : "No Apple TVs found")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.inkSecondary)
                if !model.scanning {
                    Button("Scan Again") { model.scanNow() }
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 28)
    }

    private var pairPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 26))
                .foregroundStyle(Palette.inkSecondary.opacity(0.5))
            Text("\(model.selectedDevice?.name ?? "This device") isn't paired yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            Text("Pairing shows a PIN on the TV screen;\nyou'll type it here once.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
            Button("Pair…") { model.beginPairing() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 18)
    }

    // MARK: Remote

    private var remoteControls: some View {
        VStack(spacing: 16) {
            clickpad

            buttonGrid

            nowPlayingCard
        }
        .overlay(alignment: .top) {
            if case .failed = model.session.state {
                Button("Reconnect") { model.connectIfPossible() }
                    .controlSize(.small)
                    .help(subtitle)
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .disabled(model.session.state == .connecting)
        .overlay {
            if model.session.state == .connecting {
                ProgressView("Connecting…")
                    .controlSize(.small)
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var clickpad: some View {
        ZStack {
            Circle()
                .fill(Palette.pad)
                .frame(width: Layout.padSize, height: Layout.padSize)

            DialGlyph(symbol: "chevron.up", shortcut: shortcut(.upArrow)) { send("up") }
                .offset(y: -53)
            DialGlyph(symbol: "chevron.down", shortcut: shortcut(.downArrow)) { send("down") }
                .offset(y: 53)
            DialGlyph(symbol: "chevron.left", shortcut: shortcut(.leftArrow)) { send("left") }
                .offset(x: -53)
            DialGlyph(symbol: "chevron.right", shortcut: shortcut(.rightArrow)) { send("right") }
                .offset(x: 53)

            selectButton
        }
    }

    private var selectButton: some View {
        Button {
            send("select")
        } label: {
            Circle()
                .fill(Palette.padInner)
                .frame(width: 74, height: 74)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .keyboardShortcut(shortcut(.return))
        .help("Select  ⏎")
    }

    private var buttonGrid: some View {
        HStack(alignment: .top, spacing: Layout.gap) {
            VStack(spacing: Layout.gap) {
                DarkButton(symbol: "chevron.backward", help: "Back  ⌫",
                           shortcut: shortcut(.delete)) { send("menu") }
                DarkButton(symbol: "playpause.fill", help: "Play / Pause  ␣",
                           fontSize: 16, shortcut: shortcut(" ")) { send("play_pause") }
                DarkButton(symbol: "keyboard", help: "Type on TV",
                           fontSize: 16, active: manualType || model.session.keyboardActive) {
                    manualType.toggle()
                }
            }
            VStack(spacing: Layout.gap) {
                DarkButton(symbol: "tv", help: "Home", fontSize: 16) { send("home") }
                VolumeRocker { send($0) }
            }
        }
    }

    /// Awake: click opens Control Center on the TV, long-press sleeps.
    /// Asleep: click wakes.
    private var powerMenu: some View {
        let asleep = model.session.powerState == .asleep
        return Image(systemName: "power")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(asleep ? Palette.inkSecondary.opacity(0.7) : Palette.ink)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color.white.opacity(powerPressing ? 0.85 : 0.45)))
            .scaleEffect(powerPressing ? 0.90 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: powerPressing)
            .contentShape(Circle())
            .onTapGesture {
                if asleep {
                    send("turn_on")
                    model.session.powerState = .on
                } else {
                    send("home_hold")
                }
            }
            .onLongPressGesture(minimumDuration: 0.5) {
                if asleep {
                    send("turn_on")
                    model.session.powerState = .on
                } else {
                    send("turn_off")
                    model.session.powerState = .asleep
                }
            } onPressingChanged: { pressing in
                powerPressing = pressing
            }
            .help(asleep ? "Wake Apple TV" : "Control Center (hold to sleep)")
    }

    // MARK: Now playing

    @ViewBuilder
    private var nowPlayingCard: some View {
        Group {
            if !model.selectedHasAirPlay {
                VStack(spacing: 6) {
                    Text("See what's playing here")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.inkSecondary)
                    Button("Set Up Now Playing…") {
                        model.beginPairing(protocolName: "airplay")
                    }
                    .controlSize(.small)
                }
            } else if !model.session.nowPlaying.hasMedia
                        && !(model.session.nowPlaying.isActiveState && model.session.nowPlayingApp != nil) {
                Text("Nothing playing")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                nowPlayingContent
            }
        }
        .frame(width: Layout.contentWidth, height: Layout.nowPlayingHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.35))
        )
    }

    private var nowPlayingContent: some View {
        let np = model.session.nowPlaying
        let app = model.session.nowPlayingApp
        // Apps like Netflix omit titles; fall back to the app itself.
        let title = np.title.isEmpty ? (app?.name ?? "Playing") : np.title
        let subtitle = !np.subtitle.isEmpty ? np.subtitle
            : (!np.title.isEmpty ? (app?.name ?? "") : np.state)
        return VStack(spacing: 5) {
            HStack(spacing: 8) {
                Group {
                    if let art = model.session.artwork {
                        Image(nsImage: art)
                            .resizable()
                            .scaledToFill()
                    } else if let app, let icon = icons.icon(for: app.bundleID) {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Palette.button)
                            Image(systemName: "music.note")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Palette.inkSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            if np.total > 0 {
                VStack(spacing: 3) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.black.opacity(0.12))
                            Capsule()
                                .fill(Palette.button)
                                .frame(width: geo.size.width * CGFloat(np.position) / CGFloat(max(np.total, 1)))
                        }
                    }
                    .frame(height: 3)

                    HStack {
                        Text(timeString(np.position))
                        Spacer()
                        Text(timeString(np.total))
                    }
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
                }
            }

            HStack(spacing: 22) {
                transportButton("backward.fill", help: "Skip back", command: "skip_backward")
                transportButton(np.isPlaying ? "pause.fill" : "play.fill",
                                help: "Play / Pause", command: "play_pause")
                transportButton("forward.fill", help: "Skip forward", command: "skip_forward")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func transportButton(_ symbol: String, help: String, command: String) -> some View {
        Button {
            send(command)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(help)
    }

    private func timeString(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// Shown when a text field is focused on the TV (or toggled manually).
    private var typeField: some View {
        HStack(spacing: 7) {
            Image(systemName: "keyboard")
                .font(.system(size: 11))
                .foregroundStyle(model.session.keyboardActive ? Color.accentColor : Palette.inkSecondary)
            TextField("Type on TV…", text: $typedText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
                .focused($typing)
                .onSubmit {
                    guard !typedText.isEmpty else { return }
                    send("text_set=\(typedText)")
                    typedText = ""
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(
                            model.session.keyboardActive
                                ? Color.accentColor.opacity(0.5)
                                : Color.black.opacity(0.08),
                            lineWidth: 1
                        )
                )
        )
        .onAppear { typing = true }
    }

    // MARK: Apps drawer

    /// The tvOS Search "app" is replaced by our own search field on top.
    private var launchableApps: [ATVApp] {
        model.session.apps.filter { $0.bundleID != "com.apple.TVSearch" }
    }

    private var filteredApps: [ATVApp] {
        appSearch.isEmpty
            ? launchableApps
            : launchableApps.filter { $0.name.localizedCaseInsensitiveContains(appSearch) }
    }

    private var appsDrawer: some View {
        Group {
            if model.session.apps.isEmpty {
                VStack(spacing: 8) {
                    if model.session.state == .connected {
                        ProgressView().controlSize(.small)
                        Text("Loading apps…")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.inkSecondary)
                    } else {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 20))
                            .foregroundStyle(Palette.inkSecondary.opacity(0.5))
                        Text("Connect to load apps")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.inkSecondary)
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    appSearchField

                    if filteredApps.isEmpty {
                        Text("No matches")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.inkSecondary)
                            .frame(maxHeight: .infinity)
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                                spacing: 14
                            ) {
                                ForEach(filteredApps) { app in
                                    AppTile(app: app) {
                                        send("launch_app=\(app.bundleID)")
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .onChange(of: showApps) { _, open in
            if !open { appSearch = "" }
        }
    }

    private var appSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.inkSecondary)
            TextField("Search apps…", text: $appSearch)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
                .focused($searching)
                .onSubmit {
                    if let first = filteredApps.first {
                        send("launch_app=\(first.bundleID)")
                        appSearch = ""
                    }
                }
            if !appSearch.isEmpty {
                Button {
                    appSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.inkSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.7)))
    }

    private func send(_ command: String) {
        model.session.send(command)
    }

    /// Keyboard shortcuts route to remote buttons only while no text field
    /// (TV typing or app search) is focused, so typing stays normal.
    private func shortcut(_ key: KeyEquivalent) -> KeyboardShortcut? {
        (typing || searching) ? nil : KeyboardShortcut(key, modifiers: [])
    }
}

// MARK: - App tile

private struct AppTile: View {
    let app: ATVApp
    let action: () -> Void
    @ObservedObject private var icons = IconStore.shared
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                iconView
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .shadow(color: .black.opacity(hovering ? 0.25 : 0.12), radius: hovering ? 6 : 3, y: 2)
                    .scaleEffect(hovering ? 1.06 : 1)
                    .animation(.spring(response: 0.25), value: hovering)

                Text(app.name)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help("Open \(app.name)")
    }

    @ViewBuilder
    private var iconView: some View {
        if let img = icons.icon(for: app.bundleID) {
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
        } else if let symbol = SystemAppSymbols.symbol(for: app.bundleID) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.white.opacity(0.55))
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Palette.ink)
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Palette.button)
                Text(String(app.name.prefix(1)).uppercased())
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }
}

// MARK: - Pairing flow

struct PairingView: View {
    @ObservedObject var pairing: PairingSession
    @EnvironmentObject private var model: AppModel
    @State private var pin = ""

    var body: some View {
        VStack(spacing: 12) {
            switch pairing.stage {
            case .starting:
                ProgressView("Contacting \(pairing.device.name)…")
                    .controlSize(.small)
                    .padding(.vertical, 18)
            case .waitingForPin:
                Image(systemName: pairing.protocolName == "airplay" ? "airplayvideo" : "tv")
                    .font(.system(size: 24))
                    .foregroundStyle(Palette.inkSecondary.opacity(0.5))
                Text(pairing.protocolName == "airplay"
                     ? "Enter the AirPlay PIN shown on your TV"
                     : "Enter the PIN shown on your TV")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                TextField("0000", text: $pin)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(width: 110)
                    .onSubmit(submit)
                Button("Pair", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(pin.isEmpty)
            case .verifying:
                ProgressView("Verifying…")
                    .controlSize(.small)
                    .padding(.vertical, 18)
            case .success:
                Label("Paired!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.vertical, 10)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            model.finishPairing()
                        }
                    }
            case .failure(let message):
                Label("Pairing failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(4)
                    .multilineTextAlignment(.center)
                Button("Try Again") { model.beginPairing() }
                    .controlSize(.small)
            }

            Button("Cancel") { model.cancelPairing() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(Palette.inkSecondary)
        }
        .padding(.vertical, 12)
    }

    private func submit() {
        guard !pin.isEmpty else { return }
        pairing.submit(pin: pin.trimmingCharacters(in: .whitespaces))
        pin = ""
    }
}
