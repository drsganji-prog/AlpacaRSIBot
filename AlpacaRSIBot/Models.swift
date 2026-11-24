import Foundation

// MARK: - Alpaca API models (decoded with .convertFromSnakeCase)

struct Account: Decodable {
    let status: String
    let equity: String
    let lastEquity: String
    let cash: String
    let buyingPower: String
    let tradingBlocked: Bool?
    let patternDayTrader: Bool?

    var equityValue: Double { Double(equity) ?? 0 }
    var lastEquityValue: Double { Double(lastEquity) ?? 0 }
    var cashValue: Double { Double(cash) ?? 0 }
    var buyingPowerValue: Double { Double(buyingPower) ?? 0 }
    var dayChange: Double { equityValue - lastEquityValue }
    var dayChangePct: Double { lastEquityValue > 0 ? dayChange / lastEquityValue * 100 : 0 }
}

struct Position: Decodable, Identifiable {
    var id: String { symbol }
    let symbol: String
    let qty: String
    let avgEntryPrice: String
    let currentPrice: String?
    let marketValue: String?
    let unrealizedPl: String?
    let unrealizedPlpc: String?

    var qtyValue: Double { Double(qty) ?? 0 }
    var avgEntryValue: Double { Double(avgEntryPrice) ?? 0 }
    var marketValueValue: Double { Double(marketValue ?? "") ?? 0 }
    var unrealizedPlValue: Double { Double(unrealizedPl ?? "") ?? 0 }
    var unrealizedPlPctValue: Double { (Double(unrealizedPlpc ?? "") ?? 0) * 100 }
}

struct Order: Decodable, Identifiable {
    let id: String
    let symbol: String
    let side: String
    let type: String
    let status: String
    let qty: String?
    let notional: String?
    let filledQty: String?
    let filledAvgPrice: String?
    let submittedAt: String?

    var submittedDate: Date? {
        guard let submittedAt else { return nil }
        return parseISODate(submittedAt)
    }
}

func parseISODate(_ string: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: string) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: string)
}

// MARK: - Screener / news models

struct Mover: Decodable {
    let symbol: String
    let percentChange: Double
    let change: Double
    let price: Double
}

struct MoversResponse: Decodable {
    let gainers: [Mover]
    let losers: [Mover]
}

struct MostActive: Decodable {
    let symbol: String
    let volume: Double
}

struct MostActivesResponse: Decodable {
    let mostActives: [MostActive]
}

struct MultiBarsResponse: Decodable {
    let bars: [String: [Bar]]?
    let nextPageToken: String?
}

struct NewsItem: Decodable {
    let id: Int
    let headline: String
    let summary: String?
    let source: String?
    let url: String?
    let createdAt: String
    let symbols: [String]

    var date: Date? { parseISODate(createdAt) }
}

struct NewsResponse: Decodable {
    let news: [NewsItem]
    let nextPageToken: String?
}

struct CatalystNews: Identifiable {
    var id: Int { item.id }
    let item: NewsItem
    let tags: [String]
}

struct ScanRow: Identifiable {
    var id: String { symbol }
    let symbol: String
    var price: Double
    var changePct: Double
    let volume: Double
    let relVolume: Double?
    let rsi: Double?
    var tags: [String] = []

    /// Builds a row from daily bars (oldest → newest).
    static func make(symbol: String, bars: [Bar], rsiPeriod: Int = 14) -> ScanRow? {
        guard bars.count >= 2, let last = bars.last else { return nil }
        let prev = bars[bars.count - 2].c
        let history = bars.dropLast().suffix(20).map(\.v)
        let avgVolume = history.isEmpty ? 0 : history.reduce(0, +) / Double(history.count)
        return ScanRow(
            symbol: symbol,
            price: last.c,
            changePct: prev > 0 ? (last.c - prev) / prev * 100 : 0,
            volume: last.v,
            relVolume: avgVolume > 0 ? last.v / avgVolume : nil,
            rsi: RSI.compute(closes: bars.map(\.c), period: rsiPeriod)
        )
    }
}

struct Clock: Decodable {
    let isOpen: Bool
    let nextOpen: String
    let nextClose: String
}

struct Bar: Decodable {
    let t: String
    let o: Double
    let h: Double
    let l: Double
    let c: Double
    let v: Double
}

struct BarsResponse: Decodable {
    let bars: [Bar]?
    let nextPageToken: String?
}

struct APIErrorBody: Decodable {
    let message: String?
}

struct OrderRequest: Encodable {
    let symbol: String
    let qty: String
    let side: String
    let type: String
    let timeInForce: String
}

// MARK: - App models

struct Signal: Identifiable {
    enum Action: String {
        case buy = "BUY", sell = "SELL", hold = "HOLD"
    }

    /// What the bot decided for one account (paper or live) on this symbol.
    struct Decision: Identifiable {
        var id: String { account.rawValue }
        let account: AccountMode
        let action: Action
        let reason: String
        var note: String?
    }

    var id: String { symbol }
    let symbol: String
    let price: Double?
    let rsi: Double?
    var decisions: [Decision] = []
    var info: String?              // e.g. "Not enough price data", when there is no decision
    let time = Date()

    /// The strongest action across accounts, for the badge.
    var action: Action {
        decisions.first(where: { $0.action == .sell })?.action
            ?? decisions.first(where: { $0.action == .buy })?.action ?? .hold
    }
}

struct LogEntry: Identifiable {
    enum Kind { case info, trade, error }

    let id = UUID()
    let date = Date()
    let message: String
    let kind: Kind
}

// MARK: - Formatting helpers

func fmt(_ value: Double, _ decimals: Int = 1) -> String {
    String(format: "%.\(decimals)f", value)
}

func money(_ value: Double) -> String {
    value.formatted(.currency(code: "USD"))
}
