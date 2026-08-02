import AppKit
import Foundation

/// Checks GitHub releases for a newer Clicker and self-updates in place:
/// download the notarized zip, verify its Developer ID signature, swap the
/// bundle, relaunch. Checks at launch and every 12 hours.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Update: Equatable {
        let version: String
        let zipURL: URL
        let pageURL: URL
    }

    @Published var available: Update?
    @Published var installing = false
    @Published var lastError: String?

    private var timer: Timer?
    private let repo = "ribren/clicker"
    private let teamID = "96C8S99N97"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.check() }
        }
    }

    func check() {
        Task { await performCheck() }
    }

    func install() {
        guard let update = available, !installing else { return }
        installing = true
        lastError = nil
        Task { await performInstall(update) }
    }

    private func performCheck() async {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            struct Release: Decodable {
                struct Asset: Decodable {
                    let name: String
                    let browser_download_url: String
                }
                let tag_name: String
                let html_url: String
                let assets: [Asset]
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tag_name.hasPrefix("v")
                ? String(release.tag_name.dropFirst()) : release.tag_name
            guard Self.isNewer(latest, than: currentVersion),
                  let asset = release.assets.first(where: { $0.name == "Clicker-macOS.zip" }),
                  let zipURL = URL(string: asset.browser_download_url),
                  let pageURL = URL(string: release.html_url) else {
                return
            }
            available = Update(version: latest, zipURL: zipURL, pageURL: pageURL)
        } catch {
            // Quiet failure: offline is normal; we'll try again next cycle.
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func performInstall(_ update: Update) async {
        do {
            let (downloaded, _) = try await URLSession.shared.download(from: update.zipURL)
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("clicker-update-\(update.version)", isDirectory: true)
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let zip = staging.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: downloaded, to: zip)
            try run("/usr/bin/ditto", ["-xk", zip.path, staging.path])

            let newApp = staging.appendingPathComponent("Clicker.app")
            guard FileManager.default.fileExists(atPath: newApp.path) else {
                throw UpdateError(message: "Downloaded update is malformed.")
            }
            // Must be validly signed by this app's Developer ID team.
            try run("/usr/bin/codesign", [
                "--verify", "--strict",
                "-R=anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"",
                newApp.path,
            ])

            let destination = Bundle.main.bundlePath
            try? FileManager.default.removeItem(atPath: destination)
            try run("/usr/bin/ditto", [newApp.path, destination])
            try? FileManager.default.removeItem(at: staging)

            // Relaunch the new version; terminate() runs our engine cleanup.
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"\(destination)\""]
            try relaunch.run()
            NSApplication.shared.terminate(nil)
        } catch {
            installing = false
            lastError = error.localizedDescription
        }
    }

    private func run(_ launchPath: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError(message: "\(URL(fileURLWithPath: launchPath).lastPathComponent) failed (\(p.terminationStatus)).")
        }
    }
}
