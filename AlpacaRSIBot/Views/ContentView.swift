import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "chart.line.uptrend.xyaxis") }
            SignalsView()
                .tabItem { Label("Signals", systemImage: "waveform.path.ecg") }
            OrdersView()
                .tabItem { Label("Orders", systemImage: "list.bullet.rectangle") }
            LogView()
                .tabItem { Label("Log", systemImage: "doc.text") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

struct ModeBadge: View {
    let paper: Bool

    var body: some View {
        Text(paper ? "PAPER" : "LIVE")
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(paper ? Color.blue.opacity(0.15) : Color.red.opacity(0.2))
            .foregroundStyle(paper ? Color.blue : Color.red)
            .clipShape(Capsule())
    }
}

struct ActionBadge: View {
    let action: Signal.Action

    private var color: Color {
        switch action {
        case .buy: return .green
        case .sell: return .red
        case .hold: return .gray
        }
    }

    var body: some View {
        Text(action.rawValue)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
