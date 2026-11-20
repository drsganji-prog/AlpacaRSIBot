import SwiftUI

struct ScannerView: View {
    @EnvironmentObject var scanner: ScannerEngine
    @EnvironmentObject var store: SettingsStore

    @State private var mode = 0                         // 0 = Market, 1 = Biotech
    @State private var source: ScannerEngine.MarketSource = .gainers
    @State private var sort: ScannerEngine.BiotechSort = .change
    @State private var showFilters = false
    @State private var addedSymbol: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Scanner", selection: $mode) {
                        Text("Market").tag(0)
                        Text("Biotech").tag(1)
                        Text("Morning").tag(2)
                    }
                    .pickerStyle(.segmented)

                    if mode == 2 {
                        Text(scanner.morning.map { "6:15 AM scan · \($0.generatedLocal ?? $0.generated)" }
                             ?? "Runs automatically every day at 6:15 AM PT on GitHub.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if mode == 0 {
                        Picker("Scan", selection: $source) {
                            ForEach(ScannerEngine.MarketSource.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } else {
                        Picker("Sort by", selection: $sort) {
                            ForEach(ScannerEngine.BiotechSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }

                    Button {
                        Task { await scan() }
                    } label: {
                        HStack {
                            Label(mode == 2 ? "Reload morning scan" : "Scan now", systemImage: mode == 2 ? "arrow.clockwise" : "scope")
                            if scanner.isScanning { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(scanner.isScanning)

                    if let last = scanner.lastScan {
                        Text("Last scan \(last.formatted(date: .omitted, time: .shortened)) · daily bars, IEX feed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = scanner.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }

                if mode == 2 {
                    morningSections
                } else if mode == 0 {
                    marketSection
                } else {
                    catalystSection
                    biotechSection
                    newsSection
                }
            }
            .navigationTitle("Scanner")
            .refreshable { await scan() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFilters = true } label: { Image(systemName: "slider.horizontal.3") }
                }
            }
            .sheet(isPresented: $showFilters) {
                ScannerFiltersView().environmentObject(scanner)
            }
            .onChange(of: source) { Task { await scan() } }
            .onChange(of: mode) {
                if mode == 1 && scanner.biotechRows.isEmpty { Task { await scan() } }
                if mode == 2 { Task { await scan() } }
            }
            .alert("Added \(addedSymbol ?? "") to the bot's watchlist",
                   isPresented: Binding(get: { addedSymbol != nil }, set: { if !$0 { addedSymbol = nil } })) {
                Button("OK") {}
            } message: {
                Text("The bot will check its RSI on the next cycle. Remove it anytime in Settings.")
            }
        }
    }

    // MARK: Sections

    private var marketSection: some View {
        Section("\(source.rawValue) (\(scanner.marketRows.count))") {
            if scanner.marketRows.isEmpty {
                Text(scanner.lastScan == nil ? "Tap Scan now." : "No stocks matched. Try lowering the minimum price in filters.")
                    .foregroundStyle(.secondary)
            }
            ForEach(scanner.marketRows) { row in
                rowView(row)
            }
        }
    }

    private var catalystSection: some View {
        Section {
            let events = scanner.upcomingCatalysts
            if events.isEmpty {
                Text(scanner.catalystError ?? "No catalysts in the next \(scanner.settings.catalystWindowDays) days.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(events) { CatalystRow(event: $0) }
        } header: {
            Text("Upcoming catalysts (next \(scanner.settings.catalystWindowDays) days)")
        } footer: {
            Text("FDA target (PDUFA) dates can move, and the FDA can decide early or late. \(scanner.catalystUpdated.map { "Calendar updated \($0)." } ?? "")")
        }
    }

    @ViewBuilder
    private var morningSections: some View {
        if let m = scanner.morning {
            Section("📅 Catalysts, next 14 days (\(m.catalysts.count))") {
                if m.catalysts.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(m.catalysts) { CatalystRow(event: $0) }
            }
            morningRows("🔥 Unusual biotech activity", m.biotechUnusual)
            morningRows("🧬 Biggest biotech moves", m.biotechTop)
            morningRows("📉 RSI oversold", m.oversold)
            morningRows("📈 Top gainers (previous session)", m.gainers)
            morningRows("🔻 Top losers (previous session)", m.losers)
            morningRows("RSI overbought", m.overbought)
            Section("📰 Catalyst news") {
                ForEach(m.catalystNews) { NewsRow(news: $0) }
            }
        } else {
            Section {
                Text(scanner.morningError ?? "Loading…").foregroundStyle(.secondary)
            }
        }
    }

    private func morningRows(_ title: String, _ rows: [MorningRow]) -> some View {
        Section("\(title) (\(rows.count))") {
            if rows.isEmpty { Text("None").foregroundStyle(.secondary) }
            ForEach(rows.map(\.scanRow)) { rowView($0) }
        }
    }

    private var biotechSection: some View {
        Section("Biotech watchlist (\(scanner.biotechRows.count))") {
            if scanner.biotechRows.isEmpty {
                Text("Tap Scan now.").foregroundStyle(.secondary)
            }
            ForEach(scanner.sortedBiotech(sort)) { row in
                rowView(row)
            }
        }
    }

    private var newsSection: some View {
        Section("Catalyst news (last 3 days)") {
            if scanner.news.isEmpty {
                Text("No FDA, trial or deal headlines yet.").foregroundStyle(.secondary)
            }
            ForEach(scanner.news.prefix(40)) { NewsRow(news: $0) }
        }
    }

    private func rowView(_ row: ScanRow) -> some View {
        ScanRowView(row: row)
            .swipeActions(edge: .trailing) {
                Button { addToBot(row.symbol) } label: { Label("Add to bot", systemImage: "plus.circle") }
                    .tint(.green)
            }
            .contextMenu {
                Button { addToBot(row.symbol) } label: { Label("Add \(row.symbol) to bot", systemImage: "plus.circle") }
            }
    }

    // MARK: Actions

    private func scan() async {
        if mode == 2 {
            await scanner.loadMorning()
        } else if mode == 0 {
            await scanner.scanMarket(source)
        } else {
            await scanner.scanBiotech()
        }
    }

    private func addToBot(_ symbol: String) {
        if !store.settings.symbols.map({ $0.uppercased() }).contains(symbol) {
            store.settings.symbols.append(symbol)
        }
        addedSymbol = symbol
    }
}

// MARK: - Rows

struct TagChip: View {
    let text: String

    private var color: Color {
        if text.hasPrefix("📅") { return .purple }
        if text.hasPrefix("🔥") || text == "Big gainer" { return .orange }
        if text == "Big drop" { return .red }
        if text == "Oversold" || text == "FDA" { return .green }
        if text == "Overbought" || text == "Offering" { return .red }
        if text == "Trial" { return .blue }
        if text == "M&A" { return .teal }
        return .gray
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct ScanRowView: View {
    let row: ScanRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.symbol).font(.headline)
                Spacer()
                Text(money(row.price))
                Text("\(row.changePct >= 0 ? "+" : "")\(fmt(row.changePct, 2))%")
                    .monospacedDigit()
                    .foregroundStyle(row.changePct >= 0 ? .green : .red)
                    .frame(minWidth: 70, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Text("Vol \(row.volume.formatted(.number.notation(.compactName)))")
                if let rv = row.relVolume { Text("RV \(fmt(rv))x") }
                if let rsi = row.rsi { Text("RSI \(fmt(rsi, 0))") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !row.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) { ForEach(row.tags, id: \.self) { TagChip(text: $0) } }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct CatalystRow: View {
    let event: CatalystEvent

    private var whenText: String {
        guard let d = event.daysAway else { return event.date }
        switch d {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return "In \(d) days"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(event.ticker).font(.headline)
                TagChip(text: event.type)
                if event.fromNews == true { TagChip(text: "From news") }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(whenText).font(.subheadline.bold())
                    if let day = event.day {
                        Text(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Text("\(event.drug) · \(event.indication)").font(.caption)
            Text([event.company, event.note].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct NewsRow: View {
    let news: CatalystNews

    var body: some View {
        if let link = news.item.url, let url = URL(string: link) {
            Link(destination: url) { content }
                .foregroundStyle(.primary)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(news.item.headline).font(.subheadline).multilineTextAlignment(.leading)
            HStack(spacing: 4) {
                ForEach(news.tags, id: \.self) { TagChip(text: $0) }
                Text(news.item.symbols.prefix(4).joined(separator: ", "))
                    .font(.caption.bold())
                Spacer()
                if let date = news.item.date {
                    Text(date, style: .relative).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Filters

struct ScannerFiltersView: View {
    @EnvironmentObject var scanner: ScannerEngine
    @Environment(\.dismiss) private var dismiss
    @State private var biotechText = ""
    @State private var universeText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Market scanner") {
                    priceField("Min price", value: $scanner.settings.minPrice)
                    Stepper("Show top \(scanner.settings.maxResults)", value: $scanner.settings.maxResults, in: 5...100, step: 5)
                }
                Section {
                    priceField("Biotech min price", value: $scanner.settings.biotechMinPrice)
                    Stepper("Catalyst window: \(scanner.settings.catalystWindowDays) days",
                            value: $scanner.settings.catalystWindowDays, in: 3...60)
                } header: {
                    Text("Biotech scanner")
                }
                Section {
                    Stepper("Rel. volume ≥ \(fmt(scanner.settings.unusualRelVolume))x",
                            value: $scanner.settings.unusualRelVolume, in: 1...10, step: 0.5)
                    Stepper("and move ≥ \(fmt(scanner.settings.unusualMovePct, 0))%",
                            value: $scanner.settings.unusualMovePct, in: 1...30, step: 1)
                } header: {
                    Text("🔥 Unusual activity")
                } footer: {
                    Text("Rel. volume compares today's volume with the 20-day average.")
                }
                Section {
                    TextEditor(text: $biotechText)
                        .frame(minHeight: 100)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } header: {
                    Text("Biotech watchlist")
                } footer: {
                    Text("Comma-separated tickers.")
                }
                Section("RSI scan list (market)") {
                    TextEditor(text: $universeText)
                        .frame(minHeight: 100)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                Section {
                    TextField("URL", text: $scanner.settings.catalystURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption)
                    Button("Reset all scanner settings", role: .destructive) {
                        scanner.settings = ScannerSettings()
                        loadLists()
                    }
                } header: {
                    Text("Catalyst calendar link")
                } footer: {
                    Text("The app reads upcoming FDA dates from catalysts.json in your GitHub repo. Edit that file on GitHub to add or change events, with no app rebuild needed.")
                }
            }
            .navigationTitle("Scanner filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { saveLists(); dismiss() }
                }
            }
            .onAppear { loadLists() }
        }
    }

    private func priceField(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100)
        }
    }

    private func split(_ text: String) -> [String] {
        ScannerSettings.clean(text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init))
    }

    private func loadLists() {
        biotechText = scanner.settings.biotechSymbols.joined(separator: ", ")
        universeText = scanner.settings.rsiUniverse.joined(separator: ", ")
    }

    private func saveLists() {
        let bio = split(biotechText)
        let uni = split(universeText)
        if !bio.isEmpty { scanner.settings.biotechSymbols = bio }
        if !uni.isEmpty { scanner.settings.rsiUniverse = uni }
    }
}
