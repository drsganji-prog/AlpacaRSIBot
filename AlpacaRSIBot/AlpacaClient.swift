import Foundation

enum AlpacaError: LocalizedError {
    case missingKeys
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingKeys:
            return "Add your Alpaca API key and secret in Settings."
        case let .http(code, message):
            switch code {
            case 401, 403: return "Alpaca rejected the keys (\(code)). Check you're using keys for the selected paper/live account. \(message)"
            case 422: return "Order rejected: \(message)"
            case 429: return "Rate limited by Alpaca. Try a longer check interval."
            default: return "Alpaca error \(code): \(message)"
            }
        case let .decoding(detail):
            return "Unexpected response from Alpaca: \(detail)"
        }
    }
}

/// Minimal Alpaca REST client (Trading API v2 + Market Data v2).
struct AlpacaClient {
    let keyID: String
    let secret: String
    let paper: Bool

    private static let liveBase = "https://api.alpaca.markets"
    private static let paperBase = "https://paper-api.alpaca.markets"
    private static let dataBase = "https://data.alpaca.markets"

    private var tradingBase: String { paper ? Self.paperBase : Self.liveBase }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    // MARK: Trading

    func account() async throws -> Account {
        try await send(url(tradingBase, "/v2/account"))
    }

    func clock() async throws -> Clock {
        try await send(url(tradingBase, "/v2/clock"))
    }

    func positions() async throws -> [Position] {
        try await send(url(tradingBase, "/v2/positions"))
    }

    func orders(status: String = "all", limit: Int = 50) async throws -> [Order] {
        try await send(url(tradingBase, "/v2/orders", [
            URLQueryItem(name: "status", value: status),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "direction", value: "desc"),
        ]))
    }

    func submitMarketOrder(symbol: String, qty: String, side: String) async throws -> Order {
        let body = try Self.encoder.encode(OrderRequest(
            symbol: symbol, qty: qty, side: side, type: "market", timeInForce: "day"
        ))
        return try await send(url(tradingBase, "/v2/orders"), method: "POST", body: body)
    }

    // MARK: Market data

    /// Most recent `limit` bars since `start`, returned oldest → newest.
    /// Uses the free IEX feed so it works on Alpaca's free plan.
    func bars(symbol: String, timeframe: String, start: Date, limit: Int) async throws -> [Bar] {
        let iso = ISO8601DateFormatter()
        let resp: BarsResponse = try await send(url(Self.dataBase, "/v2/stocks/\(symbol)/bars", [
            URLQueryItem(name: "timeframe", value: timeframe),
            URLQueryItem(name: "start", value: iso.string(from: start)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "feed", value: "iex"),
            URLQueryItem(name: "sort", value: "desc"),
        ]))
        return Array((resp.bars ?? []).reversed())
    }

    // MARK: Plumbing

    private func url(_ base: String, _ path: String, _ items: [URLQueryItem] = []) -> URL {
        var components = URLComponents(string: base + path)!
        if !items.isEmpty { components.queryItems = items }
        return components.url!
    }

    private func send<T: Decodable>(_ url: URL, method: String = "GET", body: Data? = nil) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue(keyID, forHTTPHeaderField: "APCA-API-KEY-ID")
        request.setValue(secret, forHTTPHeaderField: "APCA-API-SECRET-KEY")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let message = (try? Self.decoder.decode(APIErrorBody.self, from: data))?.message
                ?? String(data: data, encoding: .utf8) ?? ""
            throw AlpacaError.http(code, message)
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw AlpacaError.decoding(String(describing: error))
        }
    }
}
