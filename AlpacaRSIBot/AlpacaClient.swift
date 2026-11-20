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

    /// Daily (or other) bars for many symbols in one request, following pagination.
    func multiBars(symbols: [String], timeframe: String, start: Date) async throws -> [String: [Bar]] {
        guard !symbols.isEmpty else { return [:] }
        let iso = ISO8601DateFormatter()
        var result: [String: [Bar]] = [:]
        var token: String?
        var pages = 0
        repeat {
            var items = [
                URLQueryItem(name: "symbols", value: symbols.joined(separator: ",")),
                URLQueryItem(name: "timeframe", value: timeframe),
                URLQueryItem(name: "start", value: iso.string(from: start)),
                URLQueryItem(name: "limit", value: "10000"),
                URLQueryItem(name: "feed", value: "iex"),
            ]
            if let token { items.append(URLQueryItem(name: "page_token", value: token)) }
            let resp: MultiBarsResponse = try await send(url(Self.dataBase, "/v2/stocks/bars", items))
            for (symbol, bars) in resp.bars ?? [:] {
                result[symbol, default: []] += bars
            }
            token = resp.nextPageToken
            pages += 1
        } while token != nil && pages < 10
        return result
    }

    // MARK: Screener & news

    func movers(top: Int = 50) async throws -> MoversResponse {
        try await send(url(Self.dataBase, "/v1beta1/screener/stocks/movers", [
            URLQueryItem(name: "top", value: String(top)),
        ]))
    }

    func mostActives(top: Int = 100) async throws -> MostActivesResponse {
        try await send(url(Self.dataBase, "/v1beta1/screener/stocks/most-actives", [
            URLQueryItem(name: "by", value: "volume"),
            URLQueryItem(name: "top", value: String(top)),
        ]))
    }

    /// Latest news, newest first. Pass nil symbols for all market news.
    func news(symbols: [String]?, start: Date, limit: Int = 50) async throws -> [NewsItem] {
        let iso = ISO8601DateFormatter()
        var items = [
            URLQueryItem(name: "start", value: iso.string(from: start)),
            URLQueryItem(name: "limit", value: String(min(limit, 50))),
            URLQueryItem(name: "sort", value: "desc"),
        ]
        if let symbols, !symbols.isEmpty {
            items.append(URLQueryItem(name: "symbols", value: symbols.joined(separator: ",")))
        }
        let resp: NewsResponse = try await send(url(Self.dataBase, "/v1beta1/news", items))
        return resp.news
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
