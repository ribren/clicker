import SwiftUI

@main
struct ClickerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            RemoteView()
                .environmentObject(model)
        } label: {
            Image(systemName: "appletvremote.gen4.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
