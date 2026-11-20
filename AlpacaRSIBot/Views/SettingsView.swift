import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: SettingsStore
    @EnvironmentObject var engine: BotEngine

    @State private var keyID = ""
    @State private var secret = ""
    @State private var symbolsText = ""
    @State private var confirmLive = false
    @State private var testResult: String?
    @State private var testing = false

    private var modeBinding: Binding<Bool> {
        Binding(
            get: { store.settings.paper },
            set: { paper in
                if paper { store.settings.paper = true } else { confirmLive = true }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Account", selection: modeBinding) {
                        Text("Paper").tag(true)
                        Text("Live").tag(false)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Trading mode")
                } footer: {
                    Text(store.settings.paper
                         ? "Simulated money. Safe for testing."
                         : "⚠️ LIVE: the bot places real orders with real money.")
                }

                Section {
                    TextField("API Key ID", text: $keyID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    SecureField("Secret Key", text: $secret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await saveAndTest() }
                    } label: {
                        HStack {
                            Text("Save & test connection")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(keyID.isEmpty || secret.isEmpty || testing)
                    if let testResult {
                        Text(testResult).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("\(store.settings.paper ? "Paper" : "Live") API keys")
                } footer: {
                    Text("From the Alpaca dashboard → API Keys. Paper and live keys are different and are stored separately in the iPhone Keychain.")
                }

                Section {
                    TextField("SPY, AAPL, MSFT", text: $symbolsText)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Picker("Bar timeframe", selection: $store.settings.timeframe) {
                        ForEach(BotSettings.timeframes, id: \.self) { Text($0) }
                    }
                    Stepper("RSI period: \(store.settings.rsiPeriod)",
                            value: $store.settings.rsiPeriod, in: 2...50)
                    Stepper("Buy when RSI ≤ \(Int(store.settings.oversold))",
                            value: $store.settings.oversold, in: 5...50, step: 1)
                    Stepper("Sell when RSI ≥ \(Int(store.settings.overbought))",
                            value: $store.settings.overbought, in: 50...95, step: 1)
                } header: {
                    Text("Strategy: RSI mean reversion")
                } footer: {
                    Text("Stock symbols, separated by commas.")
                }

                Section {
                    HStack {
                        Text("Dollars per trade")
                        Spacer()
                        TextField("100", value: $store.settings.dollarsPerTrade, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 120)
                    }
                    Stepper(store.settings.stopLossPct == 0 ? "Stop-loss: off" : "Stop-loss: \(Int(store.settings.stopLossPct))%",
                            value: $store.settings.stopLossPct, in: 0...50, step: 1)
                    Stepper("Max open positions: \(store.settings.maxOpenPositions)",
                            value: $store.settings.maxOpenPositions, in: 1...20)
                } header: {
                    Text("Risk")
                }

                Section {
                    Toggle("Auto-trade (place orders)", isOn: $store.settings.autoTrade)
                    Stepper("Check every \(store.settings.intervalMinutes) min",
                            value: $store.settings.intervalMinutes, in: 1...60)
                    Toggle("Keep screen on while running", isOn: $store.settings.keepScreenOn)
                } header: {
                    Text("Automation")
                } footer: {
                    Text("With auto-trade off, the bot only shows signals. iOS pauses apps in the background, so scheduled checks run only while the app is open. iOS may wake it occasionally in the background, with no guaranteed timing.")
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                loadKeys()
                symbolsText = store.settings.symbols.joined(separator: ", ")
            }
            .onChange(of: store.settings.paper) {
                loadKeys()
                testResult = nil
            }
            .onChange(of: symbolsText) {
                store.settings.symbols = symbolsText
                    .split(whereSeparator: { $0 == "," || $0 == " " })
                    .map(String.init)
            }
            .alert("Switch to LIVE trading?", isPresented: $confirmLive) {
                Button("Use live account", role: .destructive) { store.settings.paper = false }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The bot will place real orders with real money. Test on paper first.")
            }
        }
    }

    private func loadKeys() {
        keyID = store.keyID(paper: store.settings.paper)
        secret = store.secret(paper: store.settings.paper)
    }

    private func saveAndTest() async {
        store.setKeys(id: keyID, secret: secret, paper: store.settings.paper)
        testing = true
        defer { testing = false }
        do {
            let account = try await engine.makeClient().account()
            testResult = "✅ Connected. Status \(account.status), equity \(money(account.equityValue))."
            await engine.refresh()
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }
}
