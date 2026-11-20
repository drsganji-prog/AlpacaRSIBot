import SwiftUI
import BackgroundTasks

@main
struct AlpacaRSIBotApp: App {
    @StateObject private var store = SettingsStore.shared
    @StateObject private var engine = BotEngine.shared
    @StateObject private var scanner = ScannerEngine.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(engine)
                .environmentObject(scanner)
                .task { await Notifier.requestPermission() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                BotEngine.scheduleBackgroundRefresh()
            }
        }
        // iOS decides when (and whether) this runs. It is a bonus, not a schedule.
        .backgroundTask(.appRefresh(BotEngine.backgroundTaskID)) {
            await BotEngine.shared.runBackgroundCycle()
        }
    }
}
