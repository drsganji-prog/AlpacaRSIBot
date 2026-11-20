import Foundation
import UIKit
import BackgroundTasks

/// Runs the RSI mean-reversion strategy:
///  • No position + RSI ≤ oversold  → market BUY (dollarsPerTrade worth of whole shares)
///  • Position + RSI ≥ overbought   → market SELL the whole position
///  • Position down ≥ stopLossPct   → market SELL the whole position
@MainActor
final class BotEngine: ObservableObject {
    static let shared = BotEngine()
    nonisolated static let backgroundTaskID = "com.example.AlpacaRSIBot.refresh"

    @Published var account: Account?
    @Published var positions: [Position] = []
    @Published var orders: [Order] = []
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

    func makeClient() throws -> AlpacaClient {
        let paper = settings.paper
        let id = store.keyID(paper: paper)
        let secret = store.secret(paper: paper)
        guard !id.isEmpty, !secret.isEmpty else { throw AlpacaError.missingKeys }
        return AlpacaClient(keyID: id, secret: secret, paper: paper)
    }

    // MARK: Start / stop

    func start() {
        guard loopTask == nil else { return }
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        addLog("Bot started — \(settings.paper ? "paper" : "LIVE") account, auto-trade \(settings.autoTrade ? "ON" : "off")", .info)

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
        do {
            let client = try makeClient()
            async let a = client.account()
            async let c = client.clock()
            async let p = client.positions()
            async let o = client.orders(status: "all", limit: 50)
            let (acct, clk, pos, ords) = try await (a, c, p, o)
            account = acct; clock = clk; positions = pos; orders = ords
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Strategy cycle

    func runCycle(allowTrading: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let s = settings
        do {
            let client = try makeClient()
            async let a = client.account()
            async let c = client.clock()
            async let p = client.positions()
            async let o = client.orders(status: "open", limit: 100)
            let (acct, clk, pos, openOrders) = try await (a, c, p, o)
            account = acct; clock = clk; positions = pos

            let pendingSymbols = Set(openOrders.map(\.symbol))
            var openPositionCount = pos.count
            let blocked = acct.tradingBlocked ?? false
            let start = Date().addingTimeInterval(-Double(s.lookbackDays) * 86_400)
            let limit = max(s.rsiPeriod * 10, 200)
            var newSignals: [Signal] = []

            for symbol in s.cleanSymbols {
                do {
                    let bars = try await client.bars(symbol: symbol, timeframe: s.timeframe, start: start, limit: limit)
                    let closes = bars.map(\.c)
                    guard let price = closes.last,
                          let rsi = RSI.compute(closes: closes, period: s.rsiPeriod) else {
                        newSignals.append(Signal(symbol: symbol, price: closes.last, rsi: nil, action: .hold,
                                                 reason: "Not enough price data (\(closes.count) bars)"))
                        continue
                    }

                    let position = pos.first { $0.symbol == symbol }
                    var action: Signal.Action = .hold
                    let reason: String

                    if let position {
                        let entry = position.avgEntryValue
                        let plPct = entry > 0 ? (price - entry) / entry * 100 : 0
                        if rsi >= s.overbought {
                            action = .sell
                            reason = "RSI \(fmt(rsi)) ≥ \(fmt(s.overbought, 0)): overbought, take profit/exit"
                        } else if s.stopLossPct > 0 && plPct <= -s.stopLossPct {
                            action = .sell
                            reason = "Stop-loss hit: \(fmt(plPct))% from entry"
                        } else {
                            reason = "Holding \(position.qty) sh, P/L \(fmt(plPct))%. Sell at RSI ≥ \(fmt(s.overbought, 0))"
                        }
                    } else if rsi <= s.oversold {
                        if openPositionCount >= s.maxOpenPositions {
                            reason = "Oversold, but max \(s.maxOpenPositions) positions reached"
                        } else if Int(s.dollarsPerTrade / price) < 1 {
                            reason = "Oversold, but \(money(s.dollarsPerTrade)) buys less than 1 share"
                        } else {
                            action = .buy
                            reason = "RSI \(fmt(rsi)) ≤ \(fmt(s.oversold, 0)): oversold, buy the dip"
                        }
                    } else {
                        reason = "Waiting for RSI ≤ \(fmt(s.oversold, 0))"
                    }

                    var signal = Signal(symbol: symbol, price: price, rsi: rsi, action: action, reason: reason)

                    if action != .hold {
                        if pendingSymbols.contains(symbol) {
                            signal.note = "Skipped: an order is already pending"
                        } else if !allowTrading {
                            signal.note = "Scan only, no order placed"
                        } else if !s.autoTrade {
                            signal.note = "Auto-trade is off, no order placed"
                        } else if !clk.isOpen {
                            signal.note = "Market closed, no order placed"
                        } else if blocked {
                            signal.note = "Account is blocked from trading"
                        } else {
                            let side = action == .buy ? "buy" : "sell"
                            let qty = action == .buy ? String(Int(s.dollarsPerTrade / price)) : (position?.qty ?? "0")
                            do {
                                let order = try await client.submitMarketOrder(symbol: symbol, qty: qty, side: side)
                                signal.note = "Order submitted (\(order.status))"
                                openPositionCount += action == .buy ? 1 : -1
                                let msg = "\(side.uppercased()) \(qty) \(symbol) @ ~\(money(price)). \(reason)"
                                addLog(msg, .trade)
                                Notifier.send("\(s.paper ? "[Paper] " : "")\(side.uppercased()) \(symbol)", msg)
                            } catch {
                                signal.note = "Order failed: \(error.localizedDescription)"
                                addLog("\(symbol) \(side) failed: \(error.localizedDescription)", .error)
                            }
                        }
                    }
                    newSignals.append(signal)
                } catch {
                    newSignals.append(Signal(symbol: symbol, price: nil, rsi: nil, action: .hold,
                                             reason: "Data error: \(error.localizedDescription)"))
                }
            }

            signals = newSignals
            lastRun = Date()
            lastError = nil
            if let recent = try? await client.orders(status: "all", limit: 50) { orders = recent }
            if let updated = try? await client.positions() { positions = updated }
        } catch {
            lastError = error.localizedDescription
            addLog(error.localizedDescription, .error)
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
