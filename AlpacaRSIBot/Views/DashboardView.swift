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
                        Text("Market").font(.subheadline)
                        Spacer()
                        if let clock = engine.clock {
                            Label(clock.isOpen ? "Open" : "Closed",
                                  systemImage: clock.isOpen ? "sun.max.fill" : "moon.fill")
                                .font(.subheadline)
                                .foregroundStyle(clock.isOpen ? .green : .secondary)
                        }
                    }
                }

                ForEach(engine.activeModes) { mode in
                    AccountSection(mode: mode, state: engine.state(mode),
                                   autoTrade: store.settings.autoTrade(mode))
                }
                if !store.settings.liveEnabled {
                    Section {
                        Text("Want your live account here too? Turn on \"Show live account\" in Settings.")
                            .font(.footnote).foregroundStyle(.secondary)
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

                    ForEach(engine.activeModes) { mode in
                        LabeledContent("\(mode.title) auto-trade",
                                       value: store.settings.autoTrade(mode) ? "On" : "Off (signals only)")
                    }
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
            }
            .navigationTitle("RSI Bot")
            .refreshable { await engine.refresh() }
            .task { await engine.refresh() }
            .onChange(of: store.settings.liveEnabled) { Task { await engine.refresh() } }
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

/// One account's balances and open positions.
struct AccountSection: View {
    let mode: AccountMode
    let state: AccountState
    let autoTrade: Bool

    private var message: String {
        state.error ?? "Add your \(mode.title.lowercased()) API keys in Settings, then pull down to refresh."
    }

    var body: some View {
        Section {
            if let a = state.account {
                LabeledContent("Equity", value: money(a.equityValue))
                LabeledContent("Today") {
                    Text("\(a.dayChange >= 0 ? "+" : "")\(money(a.dayChange)) (\(fmt(a.dayChangePct, 2))%)")
                        .foregroundStyle(a.dayChange >= 0 ? .green : .red)
                }
                LabeledContent("Cash", value: money(a.cashValue))
                LabeledContent("Buying power", value: money(a.buyingPowerValue))
                if state.positions.isEmpty {
                    Text("No open positions").foregroundStyle(.secondary)
                } else {
                    ForEach(state.positions) { PositionRow(position: $0) }
                }
            } else {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(state.error == nil ? Color.secondary : Color.red)
            }
        } header: {
            HStack {
                ModeBadge(paper: mode.isPaper)
                Text("\(mode.title) account")
                Spacer()
                Text(autoTrade ? "Auto-trade ON" : "Signals only")
                    .foregroundStyle(autoTrade && !mode.isPaper ? Color.red : Color.secondary)
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
