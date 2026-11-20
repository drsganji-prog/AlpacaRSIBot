import SwiftUI

struct SignalsView: View {
    @EnvironmentObject var engine: BotEngine
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        NavigationStack {
            Group {
                if engine.signals.isEmpty {
                    ContentUnavailableView("No signals yet",
                                           systemImage: "waveform.path.ecg",
                                           description: Text("Start the bot or tap Scan."))
                } else {
                    List(engine.signals) { signal in
                        SignalRow(signal: signal, settings: store.settings)
                    }
                }
            }
            .navigationTitle("Signals")
            .refreshable { await engine.runCycle(allowTrading: false) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Scan") { Task { await engine.runCycle(allowTrading: false) } }
                        .disabled(engine.isBusy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("RSI(\(store.settings.rsiPeriod)) on \(store.settings.timeframe) bars · buy ≤ \(Int(store.settings.oversold)) · sell ≥ \(Int(store.settings.overbought))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }
}

struct SignalRow: View {
    let signal: Signal
    let settings: BotSettings

    private var rsiColor: Color {
        guard let rsi = signal.rsi else { return .secondary }
        if rsi <= settings.oversold { return .green }
        if rsi >= settings.overbought { return .red }
        return .primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(signal.symbol).font(.headline)
                if let price = signal.price {
                    Text(money(price)).foregroundStyle(.secondary)
                }
                Spacer()
                if let rsi = signal.rsi {
                    Text("RSI \(fmt(rsi))").monospacedDigit().foregroundStyle(rsiColor)
                }
                ActionBadge(action: signal.action)
            }
            if let rsi = signal.rsi {
                ProgressView(value: min(max(rsi, 0), 100), total: 100)
                    .tint(rsiColor)
            }
            Text(signal.reason).font(.caption)
            if let note = signal.note {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}
