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
    /// How to launch a pyatv CLI: an executable plus the arguments that
    /// select the tool (the bundled bridge takes the tool name first).
    struct Tool {
        let executable: String
        let baseArgs: [String]
    }

    /// The frozen pyatv engine shipped inside the app bundle.
    private static var bundledBridge: String? {
        guard let resources = Bundle.main.resourcePath else { return nil }
        let path = resources + "/atvbridge/atvbridge"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// System fallbacks (source builds without the bridge): explicit override,
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

    private static var binDir: String? {
        candidates.first {
            FileManager.default.isExecutableFile(atPath: $0 + "/atvremote")
        }
    }

    static var isAvailable: Bool { bundledBridge != nil || binDir != nil }

    private static func tool(_ name: String) -> Tool? {
        if let bridge = bundledBridge {
            return Tool(executable: bridge, baseArgs: [name])
        }
        if let dir = binDir {
            return Tool(executable: dir + "/" + name, baseArgs: [])
        }
        return nil
    }

    static var atvremote: Tool? { tool("atvremote") }
    static var atvscript: Tool? { tool("atvscript") }
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
        guard let tool = PyATV.atvscript else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool.executable)
        process.arguments = tool.baseArgs + ["scan"]
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
