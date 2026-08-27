import SwiftUI

@main
struct VivaDictaMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("VivaDicta Mac") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 560, minHeight: 520)
        }
        .defaultSize(width: 620, height: 620)

        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.isRecording ? "waveform.circle.fill" : "mic.circle")
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 520, height: 420)
        }
    }
}
