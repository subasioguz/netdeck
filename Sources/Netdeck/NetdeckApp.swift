import NetdeckCore
import SwiftUI

@main
struct NetdeckApp: App {
    @State private var model: AppModel

    init() {
        SnapshotRenderer.runIfRequested()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("Netdeck") {
            RootView()
                .environment(model)
                .frame(minWidth: 1280, minHeight: 800)
                .onAppear { model.applyAppearance() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)

        Settings {
            SettingsView().environment(model)
        }
    }
}
