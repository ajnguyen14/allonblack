import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct DishonestCasinoApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onChange(of: scenePhase) { _, phase in
                    #if os(iOS)
                    // Haptics and speech capture only work in the foreground; keep the screen awake during the demo.
                    UIApplication.shared.isIdleTimerDisabled = (phase == .active)
                    #endif
                    if phase == .active { model.appBecameActive() }
                }
        }
    }
}
