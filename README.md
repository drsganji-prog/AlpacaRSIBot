# RSI Bot: Alpaca trading bot for iPhone

A SwiftUI app that trades US stocks on Alpaca using an **RSI mean-reversion** strategy. It starts on the **paper (simulated money)** account.

## Strategy
Every N minutes (default 5) for each symbol (default SPY, AAPL, MSFT):
- **Buy** when RSI(14) on 15-minute bars drops to **30 or lower** and you don't hold the stock. It buys as many whole shares as fit in *Dollars per trade* (default $100).
- **Sell the whole position** when RSI rises to **70 or higher**, or when the price is **5% below** your entry (stop-loss).
- Never holds more than *Max open positions* (default 3) at once. Skips a symbol that already has a pending order. Only trades while the market is open.

**Auto-trade is OFF by default.** The bot shows signals only until you turn it on in Settings.

## Scanner tab
- **Market:** top gainers, top losers, most active, plus RSI oversold or overbought stocks from a list of about 55 liquid names. Penny stocks are filtered out by a minimum price.
- **Biotech:** a watchlist of about 60 biotech tickers, showing daily % change, relative volume (vs. the 20-day average), RSI and tags (🔥 unusual activity, 📅 upcoming catalyst, 📰 news). It also shows a **catalyst news** feed tagged FDA / Trial / M&A / Offering.
- **Upcoming catalysts (next 14 days):** read from `catalysts.json` in this repo. Edit that file on GitHub to add or change events, with no rebuild needed. The app also picks up dates mentioned in news headlines, e.g. "PDUFA date of December 2"; it marks these "From news", so verify them before trading.
- Swipe a row left to **add it to the bot's watchlist**.

## Automatic daily jobs
- **5:40 AM PT, FDA calendar update:** a Claude scheduled task researches PDUFA dates, AdComs and readouts for the next 30 days and updates `catalysts.json`. It needs GitHub linked to Claude so it can push.
- **6:15 AM PT, morning scan:** `.github/workflows/daily-scan.yml` runs `scripts/daily_scan.py` on GitHub. The scan covers market movers, RSI extremes, biotech activity, the catalyst calendar and FDA news. It saves the results to `scan/latest.json`, which the app shows under **Scanner → Morning**, and sends an iPhone notification through the free **ntfy** app. GitHub can start scheduled jobs a few minutes late.

One-time setup for the morning scan:
1. Repo **Settings → Secrets and variables → Actions → New repository secret**. Add:
   - `ALPACA_KEY_ID`: your Alpaca paper Key ID
   - `ALPACA_SECRET`: your Alpaca paper Secret
   - `NTFY_TOPIC`: a hard-to-guess name you make up, e.g. `rsibot-yourname-8k2q`
2. On the iPhone, install **ntfy** from the App Store, tap **+**, and subscribe to that same topic name.
3. **Actions → Daily morning scan → Run workflow** to test it now. You should get a notification within about a minute.

## Setup on Windows (no Mac needed)
GitHub builds the app on one of its cloud Macs. Then Sideloadly installs it on your iPhone from your Windows PC.

1. **Upload to GitHub**: create a free account at github.com, then click **New repository**. Make it **Public**, because public repos get free Mac build minutes. Then use *uploading an existing file* and drag in everything *inside* the unzipped `AlpacaRSIBot` folder, so that `AlpacaRSIBot.xcodeproj` sits at the top level of the repo. Commit.
   - Windows can hide the `.github` folder. If it didn't upload, add it by hand: *Add file → Create new file*, name it `.github/workflows/build-ipa.yml`, and paste in that file's contents.
2. **Build**: open the repo's **Actions** tab → *Build iPhone app (IPA)* → **Run workflow**. Wait about 5 minutes for the green check. Open the run and download **AlpacaRSIBot-ipa** under *Artifacts*. Unzip it to get `AlpacaRSIBot.ipa`.
   - If the run shows a red ✗, open the failed step and copy the error lines to Claude.
3. **Install tools on Windows**: install **iTunes** and **iCloud** from apple.com. Use the versions from Apple's site, *not* the Microsoft Store versions. Then install **Sideloadly** (sideloadly.io).
4. **Install on iPhone**: plug in the iPhone by USB and tap *Trust*. Open Sideloadly, drag in `AlpacaRSIBot.ipa`, enter your Apple ID, and click **Start**.
5. **On the iPhone**: turn on *Settings → Privacy & Security → Developer Mode* and restart the phone. Then trust your Apple ID under *Settings → General → VPN & Device Management*.
6. Get your Alpaca keys as described in step 1 below. Then in the app: **Settings → paste keys → Save & test connection**.

With a free Apple ID, the app stops opening after **7 days**. Re-run Sideloadly with the same .ipa to renew it; your settings are kept.

## Setup with a Mac (about 15 minutes)
You need a Mac with **Xcode 15 or newer**, and an iPhone on **iOS 17+**.

1. **Get Alpaca paper keys**: sign up at alpaca.markets → switch to the *Paper* account → *API Keys* → Generate. Copy the Key ID and Secret.
2. **Open the project**: unzip, then double-click `AlpacaRSIBot.xcodeproj`.
3. **Signing**: click the blue *AlpacaRSIBot* project → *Signing & Capabilities* → choose your **Team** (a free Apple ID works). Change the **Bundle Identifier** to something unique, e.g. `com.yourname.rsibot`.
   - If you change the bundle ID, it's fine to leave the background-task ID `com.example.AlpacaRSIBot.refresh` as it is. It only has to match in `Info.plist` and `BotEngine.swift`.
4. **Run on your iPhone**: plug it in, pick it as the run destination, press ▶. On the phone, turn on *Settings → Privacy & Security → Developer Mode*. Then trust your developer profile under *Settings → General → VPN & Device Management*.
5. In the app: **Settings → paste your keys → Save & test connection.** Then **Dashboard → Scan now** to see signals. Tap **Start bot** to run it on its schedule.

With a free Apple ID, the app expires after 7 days. Re-run it from Xcode to renew. A paid developer account ($99/yr) lasts a year.

## Important limitations
- **iOS pauses apps in the background.** The bot runs its schedule only while the app is open on screen. "Keep screen on" helps, e.g. with the phone on a charger. iOS may wake the app occasionally in the background, but timing isn't guaranteed. For true 24/7 trading, run the bot on a server and use the phone as a dashboard.
- It uses Alpaca's free **IEX** data feed. That feed covers only part of all trades, so prices and RSI can differ slightly from other charts.
- **Market orders, whole shares, stocks only.** It doesn't support crypto, options, short selling, or extended hours.
- RSI mean reversion can lose money in strong trends, when "oversold" keeps falling. Run it on paper for several weeks before going live. Going live needs separate live keys, and the app asks you to confirm the switch.

## Files
| File | What it does |
|---|---|
| `BotEngine.swift` | Strategy loop, order decisions, background refresh |
| `AlpacaClient.swift` | Alpaca REST calls (account, positions, orders, bars) |
| `RSI.swift` | Wilder RSI calculation |
| `Settings.swift` / `Keychain.swift` | Saved settings; API keys stored in the iPhone Keychain |
| `Views/` | Dashboard, Signals, Orders, Log, Settings screens |

This is not financial advice. Use at your own risk.
