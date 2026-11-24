import SwiftUI

struct OrdersView: View {
    @EnvironmentObject var engine: BotEngine
    @EnvironmentObject var store: SettingsStore
    @State private var mode: AccountMode = .paper

    var body: some View {
        NavigationStack {
            let orders = engine.state(mode).orders
            Group {
                if orders.isEmpty {
                    ContentUnavailableView("No \(mode.title.lowercased()) orders yet", systemImage: "list.bullet.rectangle")
                } else {
                    List(orders) { OrderRow(order: $0) }
                }
            }
            .safeAreaInset(edge: .top) {
                if store.settings.liveEnabled {
                    Picker("Account", selection: $mode) {
                        ForEach(AccountMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                    .background(.bar)
                }
            }
            .onChange(of: store.settings.liveEnabled) { if !store.settings.liveEnabled { mode = .paper } }
            .navigationTitle("Orders")
            .refreshable { await engine.refresh() }
        }
    }
}

struct OrderRow: View {
    let order: Order

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(order.side.uppercased())
                        .font(.caption.bold())
                        .foregroundStyle(order.side == "buy" ? .green : .red)
                    Text(order.symbol).font(.headline)
                }
                Text("\(order.qty ?? order.notional ?? "?") sh · \(order.type)")
                    .font(.caption).foregroundStyle(.secondary)
                if let date = order.submittedDate {
                    Text(date, format: .dateTime.month().day().hour().minute())
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(order.status.replacingOccurrences(of: "_", with: " "))
                    .font(.subheadline)
                if let price = order.filledAvgPrice, let value = Double(price) {
                    Text("@ \(money(value))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
