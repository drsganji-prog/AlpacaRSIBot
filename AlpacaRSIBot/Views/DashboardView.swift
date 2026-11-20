import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var engine: BotEngine
    @EnvironmentObject var store: SettingsStore
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        ModeBadge(paper: store.settings.paper)
                        Spacer()
                        if let clock = engine.clock {
                            Label(clock.isOpen ? "Market open" : "Market closed",
                                  systemImage: clock.isOpen ? "sun.max.fill" : "moon.fill")
                                .font(.subheadline)
                                .foregroundStyle(clock.isOpen ? .green : .secondary)
                        }
                    }
                    if let a = engine.account {
                        LabeledContent("Equity", value: money(a.equityValue))
                        LabeledContent("Today") {
                            Text("\(a.dayChange >= 0 ? "+" : "")\(money(a.dayChange)) (\(fmt(a.dayChangePct, 2))%)")
                                .foregroundStyle(a.dayChange >= 0 ? .green : .red)
                        }
                        LabeledContent("Cash", value: money(a.cashValue))
                        LabeledContent("Buying power", value: money(a.buyingPowerValue))
                    } else {
                        Text("Add your Alpaca API keys in Settings, then pull down to refresh.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Bot") {
                    Button {
                        engine.isRunning ? engine.stop() : engine.start()
                    } label: {
                        Label(engine.isRunning ? "Stop bot" : "Start bot",
                              systemImage: engine.isRunning ? "stop.circle.fill" : "play.circle.fill")
                            .font(.headline)
                    }
                    .tint(engine.isRunning ? .red : .green)

                    Button {
                        Task { await engine.runCycle(allowTrading: false) }
                    } label: {
                        Label("Scan now (no trades)", systemImage: "magnifyingglass")
                    }
                    .disabled(engine.isBusy)

                    LabeledContent("Auto-trade", value: store.settings.autoTrade ? "On" : "Off (signals only)")
                    LabeledContent("Checks", value: "Every \(store.settings.intervalMinutes) min while open")
                    if let last = engine.lastRun {
                        LabeledContent("Last scan") {
                            Text(last, style: .relative) + Text(" ago")
                        }
                    }
                    if let err = engine.lastError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("Positions") {
                    if engine.positions.isEmpty {
                        Text("No open positions").foregroundStyle(.secondary)
                    } else {
                        ForEach(engine.positions) { PositionRow(position: $0) }
                    }
                }
            }
            .navigationTitle("RSI Bot")
            .refreshable { await engine.refresh() }
            .task { await engine.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showLog = true } label: { Label("Log", systemImage: "doc.text") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if engine.isBusy { ProgressView() }
                }
            }
            .sheet(isPresented: $showLog) {
                LogView().environmentObject(engine)
            }
        }
    }
}

struct PositionRow: View {
    let position: Position

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(position.symbol).font(.headline)
                Text("\(position.qty) sh @ \(money(position.avgEntryValue))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(money(position.marketValueValue))
                Text("\(money(position.unrealizedPlValue)) (\(fmt(position.unrealizedPlPctValue, 2))%)")
                    .font(.caption)
                    .foregroundStyle(position.unrealizedPlValue >= 0 ? .green : .red)
            }
        }
    }
}
