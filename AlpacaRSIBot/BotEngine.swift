import Foundation
import UIKit
import BackgroundTasks

/// One Alpaca account as last fetched.
struct AccountState {
    var account: Account?
    var positions: [Position] = []
    var orders: [Order] = []
    var error: String?
}

/// Runs the RSI mean-reversion strategy on the paper account and, when enabled, the live account.
/// RSI is computed once per symbol; each account then decides with its own positions and limits:
///  • No position + RSI ≤ oversold  → market BUY (that account's dollars per trade, whole shares)
///  • Position + RSI ≥ overbought   → market SELL the whole position
///  • Position down ≥ stopLossPct   → market SELL the whole position
/// Orders are placed only for accounts whose auto-trade is on (live is off by default).
@MainActor
final class BotEngine: ObservableObject {
    static let shared = BotEngine()
    nonisolated static let backgroundTaskID = "com.example.AlpacaRSIBot.refresh"

    @Published var paper = AccountState()
    @Published var live = AccountState()
    @Published var signals: [Signal] = []
    @Published var log: [LogEntry] = []
    @Published var clock: Clock?
    @Published var isRunning = false
    @Published var isBusy = false
    @Published var lastRun: Date?
    @Published var lastError: String?

    private var loopTask: Task<Void, Never>?
    private let store = SettingsStore.shared
    private var settings: BotSettings { store.settings }

    func state(_ m: AccountMode) -> AccountState { m.isPaper ? paper : live }

    private func update(_ m: AccountMode, _ change: (inout AccountState) -> Void) {
        if m.isPaper { change(&paper) } else { change(&live) }
    }

    /// Accounts the app is watching: paper, plus live when it's switched on in Settings.
    var activeModes: [AccountMode] {
        AccountMode.allCases.filter { $0.isPaper || settings.liveEnabled }
    }

    func client(for m: AccountMode) -> AlpacaClient? {
        guard store.hasKeys(m) else { return nil }
        return AlpacaClient(keyID: store.keyID(m), secret: store.secret(m), paper: m.isPaper)
    }

    /// Client for market data (prices, news, screeners): paper keys if set, otherwise live keys.
    func makeClient() throws -> AlpacaClient {
        if let c = client(for: .paper) ?? client(for: .live) { return c }
        throw AlpacaError.missingKeys
    }

    // MARK: Start / stop

    func start() {
        guard loopTask == nil else { return }
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        let modes = activeModes.map { "\($0.title) auto-trade \(settings.autoTrade($0) ? "ON" : "off")" }
        addLog("Bot started: " + modes.joined(separator: ", "), .info)

        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runCycle(allowTrading: true)
                let minutes = max(1, self.settings.intervalMinutes)
                try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        addLog("Bot stopped", .info)
    }

    // MARK: Refresh (no strategy)

    func refresh() async {
        guard let data = try? makeClient() else {
            lastError = AlpacaError.missingKeys.localizedDescription
            return
        }
        clock = try? await data.clock()
        for m in AccountMode.allCases {
            guard activeModes.contains(m), let api = client(for: m) else {
                update(m) { $0 = AccountState() }
                continue
            }
            do {
                async let a = api.account()
                async let p = api.positions()
                async let o = api.orders(status: "all", limit: 50)
                let (acct, pos, ords) = try await (a, p, o)
                update(m) { $0 = AccountState(account: acct, positions: pos, orders: ords) }
            } catch {
                update(m) { $0.error = error.localizedDescription }
            }
        }
        lastError = nil
    }

    // MARK: Strategy cycle

    private struct Context {
        let client: AlpacaClient
        var positions: [Position]
        let pending: Set<String>
        var openCount: Int
        let blocked: Bool
    }

    func runCycle(allowTrading: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let s = settings
        do {
            let data = try makeClient()
            let clk = try await data.clock()
            clock = clk

            // Each watched account: its positions and pending orders.
            var ctx: [AccountMode: Context] = [:]
            for m in activeModes {
                guard let api = client(for: m) else {
                    update(m) { $0 = AccountState(error: "Add your \(m.title.lowercased()) API keys in Settings.") }
                    continue
                }
                do {
                    async let a = api.account()
                    async let p = api.positions()
                    async let o = api.orders(status: "open", limit: 100)
                    let (acct, pos, open) = try await (a, p, o)
                    update(m) { $0.account = acct; $0.positions = pos; $0.error = nil }
                    ctx[m] = Context(client: api, positions: pos, pending: Set(open.map(\.symbol)),
                                     openCount: pos.count, blocked: acct.tradingBlocked ?? false)
                } catch {
                    update(m) { $0.error = error.localizedDescription }
                }
            }

            let start = Date().addingTimeInterval(-Double(s.lookbackDays) * 86_400)
            let limit = max(s.rsiPeriod * 10, 200)
            var newSignals: [Signal] = []

            for symbol in s.cleanSymbols {
                let bars: [Bar]
                do {
                    bars = try await data.bars(symbol: symbol, timeframe: s.timeframe, start: start, limit: limit)
                } catch {
                    newSignals.append(Signal(symbol: symbol, price: nil, rsi: nil,
                                             info: "Data error: \(error.localizedDescription)"))
                    continue
                }
                let closes = bars.map(\.c)
                guard let price = closes.last, let rsi = RSI.compute(closes: closes, period: s.rsiPeriod) else {
                    newSignals.append(Signal(symbol: symbol, price: closes.last, rsi: nil,
                                             info: "Not enough price data (\(closes.count) bars)"))
                    continue
                }

                var signal = Signal(symbol: symbol, price: price, rsi: rsi)
                for m in activeModes {
                    guard var c = ctx[m] else { continue }
                    var d = decide(m, symbol: symbol, price: price, rsi: rsi, ctx: c, s: s)
                    if d.action != .hold {
                        d.note = await execute(m, d, symbol: symbol, price: price, ctx: &c,
                                               allowTrading: allowTrading, marketOpen: clk.isOpen, s: s)
                        ctx[m] = c
                    }
                    signal.decisions.append(d)
                }
                newSignals.append(signal)
            }

            signals = newSignals
            lastRun = Date()
            lastError = nil
            for (m, c) in ctx {
                let ords = try? await c.client.orders(status: "all", limit: 50)
                let pos = try? await c.client.positions()
                update(m) { st in
                    if let ords { st.orders = ords }
                    if let pos { st.positions = pos }
                }
            }
        } catch {
            lastError = error.localizedDescription
            addLog(error.localizedDescription, .error)
        }
    }

    private func decide(_ m: AccountMode, symbol: String, price: Double, rsi: Double,
                        ctx: Context, s: BotSettings) -> Signal.Decision {
        if let position = ctx.positions.first(where: { $0.symbol == symbol }) {
            let entry = position.avgEntryValue
            let plPct = entry > 0 ? (price - entry) / entry * 100 : 0
            if rsi >= s.overbought {
                return .init(account: m, action: .sell, reason: "RSI \(fmt(rsi)) ≥ \(fmt(s.overbought, 0)): overbought, exit")
            }
            if s.stopLossPct > 0 && plPct <= -s.stopLossPct {
                return .init(account: m, action: .sell, reason: "Stop-loss hit: \(fmt(plPct))% from entry")
            }
            return .init(account: m, action: .hold,
                         reason: "Holding \(position.qty) sh, P/L \(fmt(plPct))%. Sell at RSI ≥ \(fmt(s.overbought, 0))")
        }
        guard rsi <= s.oversold else {
            return .init(account: m, action: .hold, reason: "Waiting for RSI ≤ \(fmt(s.oversold, 0))")
        }
        if ctx.openCount >= s.maxPositions(m) {
            return .init(account: m, action: .hold, reason: "Oversold, but max \(s.maxPositions(m)) positions reached")
        }
        if Int(s.dollars(m) / price) < 1 {
            return .init(account: m, action: .hold, reason: "Oversold, but \(money(s.dollars(m))) buys less than 1 share")
        }
        return .init(account: m, action: .buy, reason: "RSI \(fmt(rsi)) ≤ \(fmt(s.oversold, 0)): oversold, buy the dip")
    }

    /// Places the order when allowed; returns the note to show under the decision.
    private func execute(_ m: AccountMode, _ d: Signal.Decision, symbol: String, price: Double,
                         ctx: inout Context, allowTrading: Bool, marketOpen: Bool, s: BotSettings) async -> String {
        if ctx.pending.contains(symbol) { return "Skipped: an order is already pending" }
        if !allowTrading { return "Scan only, no order placed" }
        if !s.autoTrade(m) { return "\(m.title) auto-trade is off, no order placed" }
        if !marketOpen { return "Market closed, no order placed" }
        if ctx.blocked { return "Account is blocked from trading" }

        let side = d.action == .buy ? "buy" : "sell"
        let qty = d.action == .buy
            ? String(Int(s.dollars(m) / price))
            : (ctx.positions.first { $0.symbol == symbol }?.qty ?? "0")
        do {
            let order = try await ctx.client.submitMarketOrder(symbol: symbol, qty: qty, side: side)
            ctx.openCount += d.action == .buy ? 1 : -1
            let msg = "[\(m.title.uppercased())] \(side.uppercased()) \(qty) \(symbol) @ ~\(money(price)). \(d.reason)"
            addLog(msg, .trade)
            Notifier.send("[\(m.title)] \(side.uppercased()) \(symbol)", msg)
            return "Order submitted (\(order.status))"
        } catch {
            addLog("[\(m.title.uppercased())] \(symbol) \(side) failed: \(error.localizedDescription)", .error)
            return "Order failed: \(error.localizedDescription)"
        }
    }

    // MARK: Background

    func runBackgroundCycle() async {
        Self.scheduleBackgroundRefresh()
        await runCycle(allowTrading: true)
    }

    nonisolated static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Log

    func addLog(_ message: String, _ kind: LogEntry.Kind) {
        log.insert(LogEntry(message: message, kind: kind), at: 0)
        if log.count > 300 { log.removeLast(log.count - 300) }
    }
}
