import AppKit
import SwiftUI

/// Fetches real app icons via the iTunes lookup API, keyed by bundle ID,
/// with a disk cache (including negative results) in Application Support.
@MainActor
final class IconStore: ObservableObject {
    static let shared = IconStore()

    @Published private var icons: [String: NSImage] = [:]
    private var inflight: Set<String> = []
    private let dir: URL

    init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        dir = base.appendingPathComponent("Clicker/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func icon(for bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        fetch(bundleID)
        return nil
    }

    /// tvOS built-ins that have a macOS counterpart whose real icon we can use.
    private static let localAppPaths: [String: String] = [
        "com.apple.TVAppStore": "/System/Applications/App Store.app",
        "com.apple.facetime": "/System/Applications/FaceTime.app",
        "com.apple.TVMusic": "/System/Applications/Music.app",
        "com.apple.podcasts": "/System/Applications/Podcasts.app",
        "com.apple.TVPhotos": "/System/Applications/Photos.app",
        "com.apple.TVWatchList": "/System/Applications/TV.app",
        "com.apple.TVMovies": "/System/Applications/TV.app",
        "com.apple.TVShows": "/System/Applications/TV.app",
        "com.apple.TVSettings": "/System/Applications/System Settings.app",
        "com.apple.Fitness": "/System/Applications/Fitness.app",
    ]

    /// macOS icons pad the squircle inside a transparent canvas (824/1024
    /// content box); crop to full bleed so they sit flush like store artwork.
    private static func fullBleed(_ icon: NSImage) -> NSImage {
        let canvas = 256
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let scaled = CGFloat(canvas) * 1024 / 824
        let origin = -(scaled - CGFloat(canvas)) / 2
        icon.draw(
            in: NSRect(x: origin, y: origin, width: scaled, height: scaled),
            from: .zero, operation: .sourceOver, fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: NSSize(width: canvas, height: canvas))
        out.addRepresentation(rep)
        return out
    }

    private func fetch(_ id: String) {
        guard !inflight.contains(id) else { return }
        inflight.insert(id)

        // Local system-app icon beats any cache or network lookup.
        if let path = Self.localAppPaths[id], FileManager.default.fileExists(atPath: path) {
            icons[id] = Self.fullBleed(NSWorkspace.shared.icon(forFile: path))
            return
        }

        let imageFile = dir.appendingPathComponent(id + ".img")
        let missFile = dir.appendingPathComponent(id + ".miss")

        Task {
            if let img = NSImage(contentsOf: imageFile) {
                icons[id] = img
                return
            }
            guard !FileManager.default.fileExists(atPath: missFile.path) else { return }

            do {
                var comps = URLComponents(string: "https://itunes.apple.com/lookup")!
                comps.queryItems = [
                    URLQueryItem(name: "bundleId", value: id),
                    URLQueryItem(name: "media", value: "software"),
                ]
                let (data, _) = try await URLSession.shared.data(from: comps.url!)

                struct Lookup: Decodable {
                    struct App: Decodable { let artworkUrl100: String? }
                    let results: [App]
                }
                guard let art = try JSONDecoder().decode(Lookup.self, from: data)
                    .results.first?.artworkUrl100,
                    let artURL = URL(string: art.replacingOccurrences(of: "100x100", with: "256x256"))
                else {
                    try? Data().write(to: missFile)
                    return
                }
                let (imgData, _) = try await URLSession.shared.data(from: artURL)
                guard let img = NSImage(data: imgData) else {
                    try? Data().write(to: missFile)
                    return
                }
                try? imgData.write(to: imageFile)
                icons[id] = img
            } catch {
                // Network hiccup: don't write a miss marker so we retry later.
            }
        }
    }
}

/// SF Symbol stand-ins for Apple's built-in tvOS apps, which aren't in the
/// iTunes store catalog.
enum SystemAppSymbols {
    static let map: [String: String] = [
        "com.apple.TVAppStore": "bag.fill",
        "com.apple.Arcade": "gamecontroller.fill",
        "com.apple.TVHomeSharing": "rectangle.on.rectangle",
        "com.apple.facetime": "video.fill",
        "com.apple.Fitness": "figure.run",
        "com.apple.TVMovies": "film.fill",
        "com.apple.TVShows": "play.rectangle.fill",
        "com.apple.TVMusic": "music.note",
        "com.apple.TVPhotos": "photo.fill",
        "com.apple.TVSearch": "magnifyingglass",
        "com.apple.TVSettings": "gearshape.fill",
        "com.apple.podcasts": "waveform",
        "com.apple.TVWatchList": "play.tv.fill",
    ]

    static func symbol(for bundleID: String) -> String? { map[bundleID] }
}
