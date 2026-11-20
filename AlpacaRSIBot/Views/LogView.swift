import SwiftUI

struct LogView: View {
    @EnvironmentObject var engine: BotEngine

    var body: some View {
        NavigationStack {
            Group {
                if engine.log.isEmpty {
                    ContentUnavailableView("Log is empty", systemImage: "doc.text",
                                           description: Text("Trades, starts/stops and errors appear here."))
                } else {
                    List(engine.log) { entry in
                        HStack(alignment: .top) {
                            Image(systemName: icon(entry.kind))
                                .foregroundStyle(color(entry.kind))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.message).font(.subheadline)
                                Text(entry.date, format: .dateTime.month().day().hour().minute().second())
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Log")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { engine.log.removeAll() }
                        .disabled(engine.log.isEmpty)
                }
            }
        }
    }

    private func icon(_ kind: LogEntry.Kind) -> String {
        switch kind {
        case .info: return "info.circle"
        case .trade: return "arrow.left.arrow.right.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ kind: LogEntry.Kind) -> Color {
        switch kind {
        case .info: return .secondary
        case .trade: return .blue
        case .error: return .red
        }
    }
}
