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
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: submittedAt) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: submittedAt)
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

    var id: String { symbol }
    let symbol: String
    let price: Double?
    let rsi: Double?
    let action: Action
    let reason: String
    var note: String?
    let time = Date()
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
