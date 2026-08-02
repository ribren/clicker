import AppKit
import Foundation

// MARK: - Now-playing snapshot (parsed from `playing` output)

struct NowPlaying: Equatable {
    var state: String = ""      // Playing / Paused / Idle / Stopped / …
    var title: String = ""
    var subtitle: String = ""
    var position: Int = 0
    var total: Int = 0

    var hasMedia: Bool {
        !title.isEmpty && isActiveState
    }
    var isActiveState: Bool {
        ["Playing", "Paused", "Loading", "Seeking"].contains(state)
    }
    var isPlaying: Bool { state == "Playing" }
}

// MARK: - Remote control session (persistent `atvremote cli` subprocess)

@MainActor
final class RemoteSession: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var apps: [ATVApp] = []
    /// True while a text field is focused on the Apple TV (polled).
    @Published var keyboardActive = false
    @Published var nowPlaying = NowPlaying()
    /// App currently playing media (fallback when apps like Netflix omit titles).
    @Published var nowPlayingApp: ATVApp?
    @Published var artwork: NSImage?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = ""
    private var lineRemainder = ""
    private var focusTimer: Timer?
    private var playingTimer: Timer?
    private var hasAirPlay = false
    private var lastArtworkTitle = ""

    /// Working directory for the subprocess; `artwork_save` drops artwork.png here.
    private let workDir: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = base.appendingPathComponent("Clicker/nowplaying", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var artworkFile: URL { workDir.appendingPathComponent("artwork.png") }

    func connect(device: Device, credentials: String, airplayCredentials: String?) {
        disconnect()
        state = .connecting
        hasAirPlay = airplayCredentials != nil

        let p = Process()
        p.executableURL = URL(fileURLWithPath: PyATV.atvremote)
        var args = [
            "--id", device.id,
            "--companion-credentials", credentials,
        ]
        if let airplayCredentials {
            args += ["--airplay-credentials", airplayCredentials]
        }
        args.append("cli")
        p.arguments = args
        p.currentDirectoryURL = workDir

        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = outPipe
        stdinHandle = inPipe.fileHandleForWriting

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async { self?.consume(text) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.processDied() }
        }

        process = p
        do {
            try p.run()
        } catch {
            state = .failed("Couldn't launch atvremote: \(error.localizedDescription)")
            process = nil
        }
    }

    func disconnect() {
        focusTimer?.invalidate()
        focusTimer = nil
        playingTimer?.invalidate()
        playingTimer = nil
        process?.terminationHandler = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        stdinHandle = nil
        buffer = ""
        lineRemainder = ""
        apps = []
        keyboardActive = false
        nowPlaying = NowPlaying()
        nowPlayingApp = nil
        artwork = nil
        lastArtworkTitle = ""
        state = .idle
    }

    func send(_ command: String) {
        guard state == .connected, let stdinHandle else { return }
        stdinHandle.write(Data((command + "\n").utf8))
    }

    func refreshApps() {
        send("app_list")
    }

    private func consume(_ text: String) {
        buffer += text
        if state == .connecting, buffer.contains("pyatv>") {
            state = .connected
            // The prompt is up, so the connection is established; grab the app list.
            stdinHandle?.write(Data("app_list\n".utf8))
            startFocusPolling()
            if hasAirPlay {
                // tvOS 26 doesn't push the current playback snapshot to new
                // clients; an artwork request forces it out (playback-queue
                // request under the hood). Prime with one before querying.
                stdinHandle?.write(Data("artwork_save\nplaying\napp\n".utf8))
                startPlayingPolling()
            }
        }

        lineRemainder += text
        let lines = lineRemainder.components(separatedBy: "\n")
        lineRemainder = lines.last ?? ""
        for line in lines.dropLast() {
            parse(line: line)
        }
    }

    /// Poll the TV's virtual-keyboard focus so the UI can offer text entry
    /// exactly when a text field is open on screen.
    private func startFocusPolling() {
        focusTimer?.invalidate()
        focusTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.state == .connected else { return }
                self.stdinHandle?.write(Data("text_focus_state\n".utf8))
            }
        }
    }

    /// Poll playback state for the now-playing card (needs AirPlay credentials).
    private func startPlayingPolling() {
        playingTimer?.invalidate()
        playingTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.state == .connected else { return }
                var commands = "playing\napp\n"
                if !self.nowPlaying.isActiveState {
                    // Keep prodding for a snapshot while the TV claims idle —
                    // it may just not have told us yet (tvOS 26 behavior).
                    commands = "artwork_save\n" + commands
                }
                self.stdinHandle?.write(Data(commands.utf8))
            }
        }
    }

    private func parse(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.contains("FocusState.Unfocused") {
            if keyboardActive { keyboardActive = false }
            return
        }
        if trimmed.contains("FocusState.Focused") {
            if !keyboardActive { keyboardActive = true }
            return
        }
        if hasAirPlay, parsePlaying(trimmed) {
            return
        }

        guard trimmed.contains("App: ") else { return }
        guard let regex = try? NSRegularExpression(pattern: "App: ([^(]+) \\(([^)]+)\\)") else { return }
        let ns = trimmed as NSString
        var found: [ATVApp] = []
        for match in regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let bundleID = ns.substring(with: match.range(at: 2))
            found.append(ATVApp(name: name, bundleID: bundleID))
        }
        if found.count > 1 {
            // Multi-entry line = app_list response.
            apps = found.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } else if let single = found.first {
            // Single entry = `app` poll (currently playing app).
            if nowPlayingApp != single { nowPlayingApp = single }
        } else if trimmed.hasPrefix("App: None") {
            if nowPlayingApp != nil { nowPlayingApp = nil }
        }
    }

    /// Field-by-field parse of `playing` output blocks. Returns true if the
    /// line belonged to a now-playing block.
    private func parsePlaying(_ line: String) -> Bool {
        func value(_ key: String) -> String? {
            guard line.hasPrefix(key) else { return nil }
            return String(line.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
        }

        if line == "Nothing playing" {
            clearNowPlaying()
            return true
        }
        if value("Media type:") != nil {
            return true  // block header; fields follow
        }
        if let v = value("Device state:") {
            nowPlaying.state = v
            if v == "Idle" || v == "Stopped" {
                clearNowPlaying(keepState: v)
            }
            return true
        }
        if let v = value("Title:") {
            if v != nowPlaying.title {
                nowPlaying.title = v
                nowPlaying.subtitle = ""
                nowPlaying.position = 0
                nowPlaying.total = 0
            }
            if v != lastArtworkTitle {
                lastArtworkTitle = v
                requestArtwork(for: v)
            }
            return true
        }
        for key in ["Artist:", "Album:", "Series Name:"] {
            if let v = value(key) {
                if nowPlaying.subtitle.isEmpty { nowPlaying.subtitle = v }
                return true
            }
        }
        if let v = value("Position:") {
            // e.g. "13/240s (5.4%)"
            let parts = v.split(separator: "/")
            if parts.count == 2,
               let pos = Int(parts[0]),
               let total = Int(parts[1].prefix(while: \.isNumber)) {
                nowPlaying.position = pos
                nowPlaying.total = total
            }
            return true
        }
        return false
    }

    private func clearNowPlaying(keepState: String = "") {
        nowPlaying = NowPlaying(state: keepState)
        artwork = nil
        lastArtworkTitle = ""
        nowPlayingApp = nil
    }

    /// Ask the subprocess to save artwork to disk, then pick it up once written.
    private func requestArtwork(for title: String) {
        artwork = nil
        try? FileManager.default.removeItem(at: artworkFile)
        send("artwork_save")
        for delay in [1.0, 2.5, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.artwork == nil,
                      self.lastArtworkTitle == title,
                      let data = try? Data(contentsOf: self.artworkFile),
                      let image = NSImage(data: data) else { return }
                self.artwork = image
            }
        }
    }

    private func processDied() {
        focusTimer?.invalidate()
        focusTimer = nil
        playingTimer?.invalidate()
        playingTimer = nil
        process = nil
        stdinHandle = nil
        keyboardActive = false
        nowPlaying = NowPlaying()
        nowPlayingApp = nil
        artwork = nil
        let tail = buffer.split(separator: "\n").suffix(2).joined(separator: " ")
        switch state {
        case .connecting:
            state = .failed(tail.isEmpty ? "Couldn't connect." : tail)
        case .connected:
            state = .failed("Connection lost.")
        default:
            break
        }
    }
}

// MARK: - Pairing session (`atvremote --protocol <p> pair` subprocess)

@MainActor
final class PairingSession: ObservableObject {
    enum Stage: Equatable {
        case starting
        case waitingForPin
        case verifying
        case success
        case failure(String)
    }

    @Published var stage: Stage = .starting
    let device: Device
    let protocolName: String
    private(set) var credentials: String?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = ""

    init(device: Device, protocolName: String = "companion") {
        self.device = device
        self.protocolName = protocolName
    }

    func start() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: PyATV.atvremote)
        p.arguments = ["--id", device.id, "--protocol", protocolName, "pair"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = outPipe
        stdinHandle = inPipe.fileHandleForWriting

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async { self?.consume(text) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.finished() }
        }

        process = p
        do {
            try p.run()
        } catch {
            stage = .failure("Couldn't launch atvremote: \(error.localizedDescription)")
        }
    }

    func submit(pin: String) {
        stage = .verifying
        stdinHandle?.write(Data((pin + "\n").utf8))
    }

    func cancel() {
        process?.terminationHandler = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    private func consume(_ text: String) {
        buffer += text
        if stage == .starting, buffer.contains("Enter PIN on screen:") {
            stage = .waitingForPin
        }
    }

    private func finished() {
        process = nil
        stdinHandle = nil
        // Let the readability handler drain any final output before judging.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.evaluateOutcome()
        }
    }

    private func evaluateOutcome() {
        if let range = buffer.range(of: "You may now use these credentials: ") {
            let rest = buffer[range.upperBound...]
            let line = rest.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                credentials = trimmed
                stage = .success
                return
            }
        }
        let tail = buffer.split(separator: "\n").suffix(3).joined(separator: "\n")
        stage = .failure(tail.isEmpty ? "Pairing failed." : tail)
    }
}
