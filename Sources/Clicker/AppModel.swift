import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var scanning = false
    @Published var pairing: PairingSession?
    @Published var selectedID: String? {
        didSet {
            defaults.set(selectedID, forKey: "selectedID")
            if oldValue != selectedID { connectIfPossible() }
        }
    }

    let session = RemoteSession()
    private let defaults = UserDefaults.standard
    private var sigtermSource: DispatchSourceSignal?

    init() {
        // Never orphan the engine process: tear it down on normal quit, and
        // turn SIGTERM (pkill, logout) into a normal quit so the same
        // teardown path runs. A leftover engine holds a live connection to
        // the Apple TV and makes the next launch hang while connecting.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.session.disconnect()
            self?.pairing?.cancel()
        }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApplication.shared.terminate(nil) }
        source.resume()
        sigtermSource = source

        if let data = defaults.data(forKey: "devices"),
           let cached = try? JSONDecoder().decode([Device].self, from: data) {
            devices = cached.filter(\.isAppleTV)
        }
        let saved = defaults.string(forKey: "selectedID")
        selectedID = saved ?? devices.first?.id
        if devices.isEmpty {
            scanNow()
        } else {
            connectIfPossible()
        }
    }

    var selectedDevice: Device? {
        devices.first { $0.id == selectedID }
    }

    var selectedIsPaired: Bool {
        guard let id = selectedID else { return false }
        return credentials(for: id) != nil
    }

    var selectedHasAirPlay: Bool {
        guard let id = selectedID else { return false }
        return airplayCredentials(for: id) != nil
    }

    func credentials(for id: String) -> String? {
        (defaults.dictionary(forKey: "credentials") as? [String: String])?[id]
    }

    func setCredentials(_ creds: String, for id: String) {
        var all = (defaults.dictionary(forKey: "credentials") as? [String: String]) ?? [:]
        all[id] = creds
        defaults.set(all, forKey: "credentials")
    }

    func airplayCredentials(for id: String) -> String? {
        (defaults.dictionary(forKey: "airplayCredentials") as? [String: String])?[id]
    }

    func setAirplayCredentials(_ creds: String, for id: String) {
        var all = (defaults.dictionary(forKey: "airplayCredentials") as? [String: String]) ?? [:]
        all[id] = creds
        defaults.set(all, forKey: "airplayCredentials")
    }

    func scanNow() {
        guard !scanning else { return }
        scanning = true
        Task {
            let found = await DeviceScanner.scan()
            if !found.isEmpty {
                devices = found
                if let data = try? JSONEncoder().encode(found) {
                    defaults.set(data, forKey: "devices")
                }
                if selectedID == nil || !found.contains(where: { $0.id == selectedID }) {
                    selectedID = found.first?.id
                }
            }
            scanning = false
            if case .idle = session.state { connectIfPossible() }
        }
    }

    func connectIfPossible() {
        guard let device = selectedDevice,
              let creds = credentials(for: device.id) else {
            session.disconnect()
            return
        }
        session.connect(
            device: device,
            credentials: creds,
            airplayCredentials: airplayCredentials(for: device.id)
        )
    }

    func beginPairing(protocolName: String = "companion") {
        guard let device = selectedDevice else { return }
        session.disconnect()
        let p = PairingSession(device: device, protocolName: protocolName)
        pairing = p
        p.start()
    }

    func finishPairing() {
        if let p = pairing, let creds = p.credentials, !creds.isEmpty {
            if p.protocolName == "airplay" {
                setAirplayCredentials(creds, for: p.device.id)
            } else {
                setCredentials(creds, for: p.device.id)
            }
        }
        pairing?.cancel()
        pairing = nil
        connectIfPossible()
    }

    func cancelPairing() {
        pairing?.cancel()
        pairing = nil
        connectIfPossible()
    }
}
