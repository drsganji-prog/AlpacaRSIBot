import Foundation

struct BotSettings: Codable, Equatable {
    static let timeframes = ["1Min", "5Min", "15Min", "1Hour", "1Day"]

    var paper = true
    var symbols: [String] = ["SPY", "AAPL", "MSFT"]
    var timeframe = "15Min"
    var rsiPeriod = 14
    var oversold = 30.0
    var overbought = 70.0
    var dollarsPerTrade = 100.0
    var stopLossPct = 5.0          // 0 = off
    var maxOpenPositions = 3
    var intervalMinutes = 5
    var autoTrade = false          // off = signals only, no orders
    var keepScreenOn = true

    /// How far back to request bars so there are enough for a stable RSI.
    var lookbackDays: Int {
        switch timeframe {
        case "1Min": return 5
        case "5Min": return 10
        case "15Min": return 20
        case "1Hour": return 60
        default: return 400
        }
    }

    var cleanSymbols: [String] {
        var seen = Set<String>()
        return symbols
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private static let defaultsKey = "botSettings.v1"

    @Published var settings: BotSettings {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(BotSettings.self, from: data) {
            settings = saved
        } else {
            settings = BotSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // Paper and live accounts have different keys, so each is stored separately.
    private func prefix(_ paper: Bool) -> String { paper ? "paper" : "live" }

    func keyID(paper: Bool) -> String { Keychain.get("\(prefix(paper)).keyID") ?? "" }
    func secret(paper: Bool) -> String { Keychain.get("\(prefix(paper)).secret") ?? "" }

    func setKeys(id: String, secret: String, paper: Bool) {
        Keychain.set(id.trimmingCharacters(in: .whitespacesAndNewlines), for: "\(prefix(paper)).keyID")
        Keychain.set(secret.trimmingCharacters(in: .whitespacesAndNewlines), for: "\(prefix(paper)).secret")
    }
}
