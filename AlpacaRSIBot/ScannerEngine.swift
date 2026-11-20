import Foundation

// MARK: - Settings

struct ScannerSettings: Codable, Equatable {
    var minPrice = 5.0
    var biotechMinPrice = 1.0
    var maxResults = 25
    var unusualRelVolume = 2.0
    var unusualMovePct = 5.0
    var catalystWindowDays = 14
    var catalystURL = "https://raw.githubusercontent.com/drsganji-prog/AlpacaRSIBot/main/catalysts.json"
    var morningURL = "https://raw.githubusercontent.com/drsganji-prog/AlpacaRSIBot/main/scan/latest.json"

    var rsiUniverse: [String] = [
        "SPY", "QQQ", "IWM", "AAPL", "MSFT", "NVDA", "AMZN", "GOOGL", "META", "TSLA",
        "AVGO", "AMD", "NFLX", "COST", "JPM", "V", "MA", "UNH", "LLY", "XOM",
        "CVX", "HD", "WMT", "PG", "KO", "PEP", "MRK", "ABBV", "PFE", "BAC",
        "WFC", "GS", "DIS", "INTC", "CSCO", "ORCL", "CRM", "ADBE", "QCOM", "TXN",
        "MU", "PLTR", "UBER", "SHOP", "COIN", "PYPL", "BA", "CAT", "GE", "NKE",
        "SBUX", "MCD", "T", "VZ",
    ]

    var biotechSymbols: [String] = [
        "XBI", "IBB", "AMGN", "GILD", "VRTX", "REGN", "BIIB", "MRNA", "BNTX", "ALNY",
        "INCY", "NBIX", "EXEL", "SRPT", "BMRN", "IONS", "UTHR", "INSM", "CYTK", "MDGL",
        "VKTX", "KRYS", "AXSM", "RVMD", "CRSP", "NTLA", "BEAM", "RXRX", "NVAX", "IOVA",
        "ACAD", "HALO", "LEGN", "PCVX", "ARWR", "APLS", "SMMT", "VERA", "TGTX", "BBIO",
        "ROIV", "ASND", "ARGX", "DNLI", "RCKT", "SANA", "ALT", "CRNX", "IMVT", "XENE",
        "PTGX", "RYTM", "CAPR", "SVRA", "COGT", "CORT", "MLYS", "PRAX", "VNDA", "ANAB",
        "PYPD",
    ]

    static func clean(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

// MARK: - Catalyst calendar

struct CatalystEvent: Decodable, Identifiable {
    var id: String { "\(date)-\(ticker)-\(drug)" }
    let date: String          // yyyy-MM-dd
    let ticker: String
    let company: String
    let drug: String
    let indication: String
    let type: String          // PDUFA, AdCom, Readout, Conference, News
    let note: String?
    var fromNews: Bool? = false

    var day: Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        return f.date(from: date)
    }

    var daysAway: Int? {
        guard let day else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: day)).day
    }
}

// MARK: - Morning scan (written by scripts/daily_scan.py on GitHub)

struct MorningRow: Decodable {
    let symbol: String
    let price: Double?
    let changePct: Double?
    let volume: Double?
    let relVolume: Double?
    let rsi: Double?
    let tags: [String]?

    var scanRow: ScanRow {
        ScanRow(symbol: symbol, price: price ?? 0, changePct: changePct ?? 0, volume: volume ?? 0,
                relVolume: relVolume, rsi: rsi, tags: tags ?? [])
    }
}

struct MorningNews: Decodable {
    let headline: String
    let url: String?
    let symbols: [String]
    let tags: [String]
    let createdAt: String
}

struct MorningScan: Decodable {
    let generated: String
    let generatedLocal: String?
    let calendarUpdated: String?
    let catalysts: [CatalystEvent]
    let biotechUnusual: [MorningRow]
    let biotechTop: [MorningRow]
    let gainers: [MorningRow]
    let losers: [MorningRow]
    let oversold: [MorningRow]
    let overbought: [MorningRow]
    let news: [MorningNews]

    var catalystNews: [CatalystNews] {
        news.enumerated().map { index, n in
            CatalystNews(item: NewsItem(id: index, headline: n.headline, summary: nil, source: nil,
                                        url: n.url, createdAt: n.createdAt, symbols: n.symbols),
                         tags: n.tags)
        }
    }
}

struct CatalystFile: Decodable {
    let updated: String?
    let events: [CatalystEvent]
}

/// Classifies headlines into catalyst types.
enum CatalystClassifier {
    static let rules: [(String, [String])] = [
        ("FDA", ["fda", "pdufa", "approval", "approves", "approved", "complete response", "crl",
                 " nda", " bla", "breakthrough therapy", "fast track", "orphan drug",
                 "advisory committee", "adcom", "priority review"]),
        ("Trial", ["phase 1", "phase 2", "phase 3", "phase ii", "phase iii", "topline", "top-line",
                   "trial", "primary endpoint", "readout", "pivotal"]),
        ("M&A", ["to acquire", "acquisition", "merger", "buyout", "takeover"]),
        ("Offering", ["public offering", "private placement", "priced offering", "registered direct"]),
    ]

    static func tags(for text: String) -> [String] {
        let lower = " " + text.lowercased()
        return rules.compactMap { name, words in
            words.contains(where: { lower.contains($0) }) ? name : nil
        }
    }

    private static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8,
        "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    private static let dateRegex = try! NSRegularExpression(
        pattern: #"\b(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sept?(?:ember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(20\d\d))?"#,
        options: [.caseInsensitive]
    )

    /// Finds a future date mentioned next to catalyst wording, e.g. "PDUFA date of December 2".
    static func upcomingDate(in text: String, within days: Int) -> Date? {
        let lower = text.lowercased()
        let forwardWords = ["pdufa", "target action date", "goal date", "advisory committee",
                            "expected", "anticipated", "scheduled", "will present", "to present"]
        guard forwardWords.contains(where: { lower.contains($0) }) else { return nil }

        let range = NSRange(text.startIndex..., in: text)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let limit = cal.date(byAdding: .day, value: days, to: today) else { return nil }

        for match in dateRegex.matches(in: text, range: range) {
            guard let mRange = Range(match.range(at: 1), in: text),
                  let dRange = Range(match.range(at: 2), in: text),
                  let month = months[String(String(text[mRange]).lowercased().prefix(3))],
                  let dayNum = Int(text[dRange]), (1...31).contains(dayNum) else { continue }

            var year = cal.component(.year, from: today)
            if let yRange = Range(match.range(at: 3), in: text), let y = Int(text[yRange]) {
                year = y
            }
            guard var date = cal.date(from: DateComponents(year: year, month: month, day: dayNum)) else { continue }
            if match.range(at: 3).location == NSNotFound && date < today,
               let next = cal.date(byAdding: .year, value: 1, to: date) {
                date = next
            }
            if date >= today && date <= limit { return date }
        }
        return nil
    }
}

// MARK: - Engine

@MainActor
final class ScannerEngine: ObservableObject {
    static let shared = ScannerEngine()
    private static let defaultsKey = "scannerSettings.v1"

    enum MarketSource: String, CaseIterable, Identifiable {
        case gainers = "Top gainers"
        case losers = "Top losers"
        case active = "Most active"
        case oversold = "RSI oversold"
        case overbought = "RSI overbought"
        var id: String { rawValue }
    }

    enum BiotechSort: String, CaseIterable, Identifiable {
        case change = "% change"
        case relVolume = "Rel. volume"
        case catalyst = "Next catalyst"
        case rsiLow = "RSI low"
        case rsiHigh = "RSI high"
        var id: String { rawValue }
    }

    @Published var marketRows: [ScanRow] = []
    @Published var biotechRows: [ScanRow] = []
    @Published var news: [CatalystNews] = []
    @Published var catalysts: [CatalystEvent] = []
    @Published var catalystUpdated: String?
    @Published var catalystError: String?
    @Published var morning: MorningScan?
    @Published var morningError: String?
    @Published var isScanning = false
    @Published var error: String?
    @Published var lastScan: Date?

    @Published var settings: ScannerSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(ScannerSettings.self, from: data) {
            settings = saved
        } else {
            settings = ScannerSettings()
        }
    }

    // MARK: Market scan

    func scanMarket(_ source: MarketSource) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let s = settings
        let bot = SettingsStore.shared.settings
        do {
            let client = try BotEngine.shared.makeClient()
            var symbols: [String] = []
            var overrides: [String: (price: Double, pct: Double)] = [:]

            switch source {
            case .gainers, .losers:
                let movers = try await client.movers(top: 50)
                let list = source == .gainers ? movers.gainers : movers.losers
                for m in list where m.price >= s.minPrice {
                    symbols.append(m.symbol)
                    overrides[m.symbol] = (m.price, m.percentChange)
                }
            case .active:
                symbols = try await client.mostActives(top: 100).mostActives.map(\.symbol)
            case .oversold, .overbought:
                symbols = ScannerSettings.clean(s.rsiUniverse)
            }

            if source != .oversold && source != .overbought {
                symbols = Array(symbols.prefix(max(s.maxResults * 2, 40)))
            }

            var rows = try await buildRows(client: client, symbols: symbols, rsiPeriod: bot.rsiPeriod)
            for i in rows.indices {
                if let o = overrides[rows[i].symbol] {
                    rows[i].price = o.price
                    rows[i].changePct = o.pct
                }
                rows[i].tags = self.tags(for: rows[i], oversold: bot.oversold, overbought: bot.overbought)
            }
            rows = rows.filter { $0.price >= s.minPrice }

            switch source {
            case .gainers:
                rows.sort { $0.changePct > $1.changePct }
            case .losers:
                rows.sort { $0.changePct < $1.changePct }
            case .active:
                let order = Dictionary(symbols.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
                rows.sort { (order[$0.symbol] ?? 0) < (order[$1.symbol] ?? 0) }
            case .oversold:
                rows = rows.filter { ($0.rsi ?? 50) <= bot.oversold }
                rows.sort { ($0.rsi ?? 50) < ($1.rsi ?? 50) }
            case .overbought:
                rows = rows.filter { ($0.rsi ?? 50) >= bot.overbought }
                rows.sort { ($0.rsi ?? 50) > ($1.rsi ?? 50) }
            }

            marketRows = Array(rows.prefix(s.maxResults))
            lastScan = Date()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Biotech scan

    func scanBiotech() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let s = settings
        let bot = SettingsStore.shared.settings
        let universe = ScannerSettings.clean(s.biotechSymbols)
        let universeSet = Set(universe)

        await loadCatalysts()

        do {
            let client = try BotEngine.shared.makeClient()
            var rows = try await buildRows(client: client, symbols: universe, rsiPeriod: bot.rsiPeriod)
            rows = rows.filter { $0.price >= s.biotechMinPrice }

            // News: the watchlist's own news + broad market news filtered to FDA / trial headlines.
            let since = Date().addingTimeInterval(-3 * 86_400)
            async let watchNews = client.news(symbols: Array(universe.prefix(100)), start: since, limit: 50)
            async let broadNews = client.news(symbols: nil, start: since, limit: 50)
            let (w, b) = try await (watchNews, broadNews)

            var seen = Set<Int>()
            var items: [CatalystNews] = []
            for item in w + b where seen.insert(item.id).inserted {
                let text = item.headline + " " + (item.summary ?? "")
                let tags = CatalystClassifier.tags(for: text)
                let isWatch = item.symbols.contains { universeSet.contains($0) }
                if isWatch || tags.contains("FDA") || tags.contains("Trial") {
                    items.append(CatalystNews(item: item, tags: tags))
                }
            }
            items.sort { ($0.item.date ?? .distantPast) > ($1.item.date ?? .distantPast) }
            news = items

            // Upcoming dates mentioned in the news become extra calendar entries.
            addNewsCatalysts(from: items, window: s.catalystWindowDays)

            let recentNewsSymbols = Set(items.filter {
                ($0.item.date ?? .distantPast) > Date().addingTimeInterval(-2 * 86_400)
            }.flatMap(\.item.symbols))

            for i in rows.indices {
                var rowTags = self.tags(for: rows[i], oversold: bot.oversold, overbought: bot.overbought)
                if let next = nextCatalyst(for: rows[i].symbol), let d = next.daysAway {
                    rowTags.insert("📅 \(next.type) \(d == 0 ? "today" : "in \(d)d")", at: 0)
                }
                if recentNewsSymbols.contains(rows[i].symbol) { rowTags.append("📰 News") }
                rows[i].tags = rowTags
            }
            biotechRows = rows
            lastScan = Date()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func sortedBiotech(_ sort: BiotechSort) -> [ScanRow] {
        switch sort {
        case .change:
            return biotechRows.sorted { abs($0.changePct) > abs($1.changePct) }
        case .relVolume:
            return biotechRows.sorted { ($0.relVolume ?? 0) > ($1.relVolume ?? 0) }
        case .catalyst:
            return biotechRows.sorted {
                (nextCatalyst(for: $0.symbol)?.daysAway ?? 9_999) < (nextCatalyst(for: $1.symbol)?.daysAway ?? 9_999)
            }
        case .rsiLow:
            return biotechRows.sorted { ($0.rsi ?? 50) < ($1.rsi ?? 50) }
        case .rsiHigh:
            return biotechRows.sorted { ($0.rsi ?? 50) > ($1.rsi ?? 50) }
        }
    }

    // MARK: Catalyst calendar

    /// Events from today through the next `catalystWindowDays` days.
    var upcomingCatalysts: [CatalystEvent] {
        catalysts
            .filter { ($0.daysAway ?? -1) >= 0 && ($0.daysAway ?? 9_999) <= settings.catalystWindowDays }
            .sorted { ($0.daysAway ?? 0) < ($1.daysAway ?? 0) }
    }

    func nextCatalyst(for symbol: String) -> CatalystEvent? {
        upcomingCatalysts.first { $0.ticker == symbol }
    }

    func loadCatalysts() async {
        guard let url = URL(string: settings.catalystURL) else {
            catalystError = "Catalyst calendar link is not a valid URL."
            return
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                catalystError = "Couldn't load the catalyst calendar (check catalysts.json is in your GitHub repo)."
                return
            }
            let file = try JSONDecoder().decode(CatalystFile.self, from: data)
            let fromNews = catalysts.filter { $0.fromNews == true }
            catalysts = file.events + fromNews
            catalystUpdated = file.updated
            catalystError = nil
        } catch {
            catalystError = "Catalyst calendar error: \(error.localizedDescription)"
        }
    }

    func loadMorning() async {
        guard let url = URL(string: settings.morningURL) else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                morningError = "No morning scan yet. It appears after the first 6:15 AM run (or a manual run in GitHub Actions)."
                return
            }
            morning = try JSONDecoder().decode(MorningScan.self, from: data)
            morningError = nil
        } catch {
            morningError = "Couldn't read the morning scan: \(error.localizedDescription)"
        }
    }

    private func addNewsCatalysts(from items: [CatalystNews], window: Int) {
        var events = catalysts.filter { $0.fromNews != true }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")

        for n in items {
            let text = n.item.headline + ". " + (n.item.summary ?? "")
            guard let date = CatalystClassifier.upcomingDate(in: text, within: window),
                  let ticker = n.item.symbols.first else { continue }
            let day = f.string(from: date)
            // Skip if the calendar already has an event for this ticker that day.
            if events.contains(where: { $0.ticker == ticker && $0.date == day }) { continue }
            let type = text.lowercased().contains("pdufa") || text.lowercased().contains("action date") ? "PDUFA" : "News"
            events.append(CatalystEvent(
                date: day, ticker: ticker, company: n.item.source ?? "News",
                drug: n.item.headline, indication: "Date found in a news headline; verify before trading",
                type: type, note: nil, fromNews: true
            ))
        }
        catalysts = events
    }

    // MARK: Helpers

    private func buildRows(client: AlpacaClient, symbols: [String], rsiPeriod: Int) async throws -> [ScanRow] {
        guard !symbols.isEmpty else { return [] }
        let start = Date().addingTimeInterval(-90 * 86_400)
        var all: [String: [Bar]] = [:]
        var index = 0
        while index < symbols.count {
            let chunk = Array(symbols[index..<min(index + 100, symbols.count)])
            let bars = try await client.multiBars(symbols: chunk, timeframe: "1Day", start: start)
            all.merge(bars) { $0 + $1 }
            index += 100
        }
        return symbols.compactMap { symbol in
            guard let bars = all[symbol] else { return nil }
            return ScanRow.make(symbol: symbol, bars: bars, rsiPeriod: rsiPeriod)
        }
    }

    private func tags(for row: ScanRow, oversold: Double, overbought: Double) -> [String] {
        var tags: [String] = []
        if let rv = row.relVolume, rv >= settings.unusualRelVolume, abs(row.changePct) >= settings.unusualMovePct {
            tags.append("🔥 Unusual")
        }
        if row.changePct >= 10 { tags.append("Big gainer") }
        if row.changePct <= -10 { tags.append("Big drop") }
        if let rsi = row.rsi {
            if rsi <= oversold { tags.append("Oversold") }
            if rsi >= overbought { tags.append("Overbought") }
        }
        return tags
    }
}
