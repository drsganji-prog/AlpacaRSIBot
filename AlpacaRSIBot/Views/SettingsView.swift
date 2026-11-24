import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: SettingsStore
    @EnvironmentObject var engine: BotEngine

    @State private var keyID = ""
    @State private var secret = ""
    @State private var symbolsText = ""
    @State private var keyMode: AccountMode = .paper
    @State private var confirmLive = false
    @State private var testResult: String?
    @State private var testing = false

    /// Turning live auto-trade on asks first; turning it off is immediate.
    private var liveAutoTradeBinding: Binding<Bool> {
        Binding(
            get: { store.settings.liveAutoTrade },
            set: { on in
                if on { confirmLive = true } else { store.settings.liveAutoTrade = false }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Keys for", selection: $keyMode) {
                        ForEach(AccountMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
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
                    Text("API keys")
                } footer: {
                    Text("From the Alpaca dashboard → API Keys. Paper and live accounts have different keys; each pair is stored separately in the iPhone Keychain.")
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
                    Stepper(store.settings.stopLossPct == 0 ? "Stop-loss: off" : "Stop-loss: \(Int(store.settings.stopLossPct))%",
                            value: $store.settings.stopLossPct, in: 0...50, step: 1)
                } header: {
                    Text("Strategy: RSI mean reversion")
                } footer: {
                    Text("Stock symbols, separated by commas. The same signals are used for both accounts.")
                }

                Section {
                    Toggle("Auto-trade (place orders)", isOn: $store.settings.autoTrade)
                    dollarsField(value: $store.settings.dollarsPerTrade)
                    Stepper("Max open positions: \(store.settings.maxOpenPositions)",
                            value: $store.settings.maxOpenPositions, in: 1...20)
                } header: {
                    HStack { ModeBadge(paper: true); Text("Paper account") }
                } footer: {
                    Text("Simulated money. Safe for testing.")
                }

                Section {
                    Toggle("Show live account", isOn: $store.settings.liveEnabled)
                    if store.settings.liveEnabled {
                        Toggle("Live auto-trade (real orders)", isOn: liveAutoTradeBinding)
                            .tint(.red)
                        dollarsField(value: $store.settings.liveDollarsPerTrade)
                        Stepper("Max open positions: \(store.settings.liveMaxOpenPositions)",
                                value: $store.settings.liveMaxOpenPositions, in: 1...20)
                    }
                } header: {
                    HStack { ModeBadge(paper: false); Text("Live account") }
                } footer: {
                    Text(store.settings.liveAutoTrade && store.settings.liveEnabled
                         ? "⚠️ The bot places real orders with real money on the live account."
                         : "With auto-trade off, the live account is shown and gets signals, but no orders are placed.")
                }

                Section {
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
            .onChange(of: keyMode) {
                loadKeys()
                testResult = nil
            }
            .onChange(of: store.settings.liveEnabled) {
                if !store.settings.liveEnabled { store.settings.liveAutoTrade = false }
            }
            .onChange(of: symbolsText) {
                store.settings.symbols = symbolsText
                    .split(whereSeparator: { $0 == "," || $0 == " " })
                    .map(String.init)
            }
            .alert("Turn on LIVE auto-trade?", isPresented: $confirmLive) {
                Button("Place real orders", role: .destructive) { store.settings.liveAutoTrade = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The bot will buy and sell with real money on your live account, up to \(money(store.settings.liveDollarsPerTrade)) per trade and \(store.settings.liveMaxOpenPositions) position(s) at a time. Test on paper first.")
            }
        }
    }

    private func dollarsField(value: Binding<Double>) -> some View {
        HStack {
            Text("Dollars per trade")
            Spacer()
            TextField("100", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
        }
    }

    private func loadKeys() {
        keyID = store.keyID(keyMode)
        secret = store.secret(keyMode)
    }

    private func saveAndTest() async {
        store.setKeys(id: keyID, secret: secret, for: keyMode)
        testing = true
        defer { testing = false }
        do {
            guard let client = engine.client(for: keyMode) else { throw AlpacaError.missingKeys }
            let account = try await client.account()
            testResult = "✅ \(keyMode.title) connected. Status \(account.status), equity \(money(account.equityValue))."
            await engine.refresh()
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }
}
