import Foundation

/// The two Alpaca accounts the app can watch and trade at the same time.
enum AccountMode: String, CaseIterable, Identifiable {
    case paper, live
    var id: String { rawValue }
    var title: String { self == .paper ? "Paper" : "Live" }
    var isPaper: Bool { self == .paper }
}

struct BotSettings: Codable, Equatable {
    static let timeframes = ["1Min", "5Min", "15Min", "1Hour", "1Day"]

    // Strategy (shared by both accounts)
    var symbols: [String] = ["SPY", "AAPL", "MSFT"]
    var timeframe = "15Min"
    var rsiPeriod = 14
    var oversold = 30.0
    var overbought = 70.0
    var stopLossPct = 5.0          // 0 = off
    var intervalMinutes = 5
    var keepScreenOn = true

    // Paper account
    var dollarsPerTrade = 100.0
    var maxOpenPositions = 3
    var autoTrade = false          // paper auto-trade; off = signals only

    // Live account (real money): shown only when enabled, never trades unless liveAutoTrade is on
    var liveEnabled = false
    var liveAutoTrade = false
    var liveDollarsPerTrade = 100.0
    var liveMaxOpenPositions = 1

    enum CodingKeys: String, CodingKey {
        case symbols, timeframe, rsiPeriod, oversold, overbought, stopLossPct, intervalMinutes, keepScreenOn
        case dollarsPerTrade, maxOpenPositions, autoTrade
        case liveEnabled, liveAutoTrade, liveDollarsPerTrade, liveMaxOpenPositions
    }

    func autoTrade(_ m: AccountMode) -> Bool { m.isPaper ? autoTrade : (liveEnabled && liveAutoTrade) }
    func dollars(_ m: AccountMode) -> Double { m.isPaper ? dollarsPerTrade : liveDollarsPerTrade }
    func maxPositions(_ m: AccountMode) -> Int { m.isPaper ? maxOpenPositions : liveMaxOpenPositions }

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

extension BotSettings {
    private enum LegacyKeys: String, CodingKey { case paper }

    /// Reads settings saved by any earlier version: missing values get defaults, so an update never
    /// wipes the user's symbols and risk choices.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbols = try c.decodeIfPresent([String].self, forKey: .symbols) ?? symbols
        timeframe = try c.decodeIfPresent(String.self, forKey: .timeframe) ?? timeframe
        rsiPeriod = try c.decodeIfPresent(Int.self, forKey: .rsiPeriod) ?? rsiPeriod
        oversold = try c.decodeIfPresent(Double.self, forKey: .oversold) ?? oversold
        overbought = try c.decodeIfPresent(Double.self, forKey: .overbought) ?? overbought
        stopLossPct = try c.decodeIfPresent(Double.self, forKey: .stopLossPct) ?? stopLossPct
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? intervalMinutes
        keepScreenOn = try c.decodeIfPresent(Bool.self, forKey: .keepScreenOn) ?? keepScreenOn
        dollarsPerTrade = try c.decodeIfPresent(Double.self, forKey: .dollarsPerTrade) ?? dollarsPerTrade
        maxOpenPositions = try c.decodeIfPresent(Int.self, forKey: .maxOpenPositions) ?? maxOpenPositions
        autoTrade = try c.decodeIfPresent(Bool.self, forKey: .autoTrade) ?? autoTrade
        liveEnabled = try c.decodeIfPresent(Bool.self, forKey: .liveEnabled) ?? liveEnabled
        liveAutoTrade = try c.decodeIfPresent(Bool.self, forKey: .liveAutoTrade) ?? liveAutoTrade
        liveDollarsPerTrade = try c.decodeIfPresent(Double.self, forKey: .liveDollarsPerTrade) ?? liveDollarsPerTrade
        liveMaxOpenPositions = try c.decodeIfPresent(Int.self, forKey: .liveMaxOpenPositions) ?? liveMaxOpenPositions
        // Version 1 had a single Paper/Live switch. If it was on Live, keep showing the live account,
        // but auto-trade stays with paper: live trading has to be switched on again on purpose.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if let wasPaper = try legacy.decodeIfPresent(Bool.self, forKey: .paper), !wasPaper {
            liveEnabled = true
            autoTrade = false
        }
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

    // Paper and live accounts have different keys, so each is stored separately in the Keychain.
    func keyID(_ m: AccountMode) -> String { Keychain.get("\(m.rawValue).keyID") ?? "" }
    func secret(_ m: AccountMode) -> String { Keychain.get("\(m.rawValue).secret") ?? "" }
    func hasKeys(_ m: AccountMode) -> Bool { !keyID(m).isEmpty && !secret(m).isEmpty }

    func setKeys(id: String, secret: String, for m: AccountMode) {
        Keychain.set(id.trimmingCharacters(in: .whitespacesAndNewlines), for: "\(m.rawValue).keyID")
        Keychain.set(secret.trimmingCharacters(in: .whitespacesAndNewlines), for: "\(m.rawValue).secret")
    }
}
