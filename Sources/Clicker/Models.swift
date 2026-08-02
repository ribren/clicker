import Foundation

struct Device: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var address: String
    var model: String

    var isAppleTV: Bool { model.localizedCaseInsensitiveContains("Apple TV") }
}

struct ATVApp: Identifiable, Hashable {
    let name: String
    let bundleID: String
    var id: String { bundleID }
}

enum PyATV {
    /// Places the pyatv CLIs might live, best first: explicit override,
    /// a dev checkout venv, our own app-support venv, pipx, Homebrew.
    private static var candidates: [String] {
        let home = NSHomeDirectory()
        var dirs: [String] = []
        if let override = UserDefaults.standard.string(forKey: "pyatvBinDir") {
            dirs.append(override)
        }
        dirs += [
            home + "/Documents/Claude/Projects/clicker/.venv/bin",
            home + "/Library/Application Support/Clicker/venv/bin",
            home + "/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        return dirs
    }

    static var binDir: String? {
        candidates.first {
            FileManager.default.isExecutableFile(atPath: $0 + "/atvremote")
        }
    }
    static var isAvailable: Bool { binDir != nil }
    static var atvremote: String { (binDir ?? "/usr/local/bin") + "/atvremote" }
    static var atvscript: String { (binDir ?? "/usr/local/bin") + "/atvscript" }
}

enum DeviceScanner {
    static func scan() async -> [Device] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runScan())
            }
        }
    }

    private static func runScan() -> [Device] {
        guard PyATV.isAvailable else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: PyATV.atvscript)
        process.arguments = ["scan"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceList = json["devices"] as? [[String: Any]] else { return [] }

        var found: [Device] = []
        for entry in deviceList {
            guard let name = entry["name"] as? String,
                  let id = entry["identifier"] as? String,
                  let address = entry["address"] as? String else { continue }
            let services = (entry["services"] as? [[String: Any]])?
                .compactMap { $0["protocol"] as? String } ?? []
            guard services.contains("companion") else { continue }
            let info = entry["device_info"] as? [String: Any]
            let model = info?["model_str"] as? String ?? "Unknown"
            let device = Device(id: id, name: name, address: address, model: model)
            // Macs and HomePods advertise Companion too; only real Apple TVs belong here.
            guard device.isAppleTV else { continue }
            found.append(device)
        }
        found.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return found
    }
}
