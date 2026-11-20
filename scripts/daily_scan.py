"""Morning scan: market + biotech + FDA catalyst calendar.

Runs on GitHub Actions (see .github/workflows/daily-scan.yml). Uses only the
Python standard library. Writes scan/latest.json (read by the iPhone app) and
sends a summary push notification through ntfy.sh if NTFY_TOPIC is set.

Environment:
  ALPACA_KEY_ID, ALPACA_SECRET  Alpaca API keys (paper keys work)
  NTFY_TOPIC                    ntfy topic name for iPhone notifications (optional)
  FORCE=true                    run even if it isn't 6 AM in Los Angeles
"""

import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent.parent
LA = ZoneInfo("America/Los_Angeles")
DATA = "https://data.alpaca.markets"
WINDOW_DAYS = 14
MIN_PRICE = 5.0
BIOTECH_MIN_PRICE = 1.0
OVERSOLD, OVERBOUGHT = 30.0, 70.0
UNUSUAL_RV, UNUSUAL_MOVE = 2.0, 5.0

RSI_UNIVERSE = (
    "SPY QQQ IWM AAPL MSFT NVDA AMZN GOOGL META TSLA AVGO AMD NFLX COST JPM V MA UNH LLY XOM "
    "CVX HD WMT PG KO PEP MRK ABBV PFE BAC WFC GS DIS INTC CSCO ORCL CRM ADBE QCOM TXN "
    "MU PLTR UBER SHOP COIN PYPL BA CAT GE NKE SBUX MCD T VZ"
).split()

BIOTECH = (
    "XBI IBB AMGN GILD VRTX REGN BIIB MRNA BNTX ALNY INCY NBIX EXEL SRPT BMRN IONS UTHR INSM CYTK MDGL "
    "VKTX KRYS AXSM RVMD CRSP NTLA BEAM RXRX NVAX IOVA ACAD HALO LEGN PCVX ARWR APLS SMMT VERA TGTX BBIO "
    "ROIV ASND ARGX DNLI RCKT SANA ALT CRNX IMVT XENE PTGX RYTM CAPR SVRA COGT CORT MLYS PRAX VNDA ANAB PYPD"
).split()

CATALYST_RULES = [
    ("FDA", ["fda", "pdufa", "approval", "approves", "approved", "complete response", "crl", " nda", " bla",
             "breakthrough therapy", "fast track", "orphan drug", "advisory committee", "adcom", "priority review"]),
    ("Trial", ["phase 1", "phase 2", "phase 3", "phase ii", "phase iii", "topline", "top-line", "trial",
               "primary endpoint", "readout", "pivotal"]),
    ("M&A", ["to acquire", "acquisition", "merger", "buyout", "takeover"]),
    ("Offering", ["public offering", "private placement", "priced offering", "registered direct"]),
]
MONTHS = {m: i for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], start=1)}
DATE_RE = re.compile(
    r"\b(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sept?(?:ember)?|"
    r"Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(20\d\d))?", re.I)
FORWARD_WORDS = ["pdufa", "target action date", "goal date", "advisory committee", "expected",
                 "anticipated", "scheduled", "will present", "to present"]


# ---------- Alpaca ----------

def get(path, params):
    url = DATA + path + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={
        "APCA-API-KEY-ID": os.environ["ALPACA_KEY_ID"],
        "APCA-API-SECRET-KEY": os.environ["ALPACA_SECRET"],
    })
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def daily_bars(symbols, days=90):
    start = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    out = {}
    for i in range(0, len(symbols), 100):
        chunk = symbols[i:i + 100]
        token = None
        for _ in range(10):
            params = {"symbols": ",".join(chunk), "timeframe": "1Day", "start": start,
                      "limit": 10000, "feed": "iex"}
            if token:
                params["page_token"] = token
            data = get("/v2/stocks/bars", params)
            for sym, bars in (data.get("bars") or {}).items():
                out.setdefault(sym, []).extend(bars)
            token = data.get("next_page_token")
            if not token:
                break
    return out


def news(symbols=None, days=3):
    start = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    params = {"start": start, "limit": 50, "sort": "desc"}
    if symbols:
        params["symbols"] = ",".join(symbols)
    return get("/v1beta1/news", params).get("news", [])


# ---------- Math ----------

def rsi(closes, period=14):
    if len(closes) <= period:
        return None
    gain = sum(max(closes[i] - closes[i - 1], 0) for i in range(1, period + 1)) / period
    loss = sum(max(closes[i - 1] - closes[i], 0) for i in range(1, period + 1)) / period
    for i in range(period + 1, len(closes)):
        ch = closes[i] - closes[i - 1]
        gain = (gain * (period - 1) + max(ch, 0)) / period
        loss = (loss * (period - 1) + max(-ch, 0)) / period
    if loss == 0:
        return 50.0 if gain == 0 else 100.0
    return 100 - 100 / (1 + gain / loss)


def make_row(symbol, bars):
    if len(bars) < 2:
        return None
    last, prev = bars[-1], bars[-2]["c"]
    hist = [b["v"] for b in bars[:-1][-20:]]
    avg = sum(hist) / len(hist) if hist else 0
    row = {
        "symbol": symbol,
        "price": round(last["c"], 2),
        "changePct": round((last["c"] - prev) / prev * 100, 2) if prev else 0.0,
        "volume": last["v"],
        "relVolume": round(last["v"] / avg, 2) if avg else None,
        "rsi": round(rsi([b["c"] for b in bars]), 1) if len(bars) > 14 else None,
    }
    tags = []
    if row["relVolume"] and row["relVolume"] >= UNUSUAL_RV and abs(row["changePct"]) >= UNUSUAL_MOVE:
        tags.append("🔥 Unusual")
    if row["changePct"] >= 10:
        tags.append("Big gainer")
    if row["changePct"] <= -10:
        tags.append("Big drop")
    if row["rsi"] is not None:
        if row["rsi"] <= OVERSOLD:
            tags.append("Oversold")
        if row["rsi"] >= OVERBOUGHT:
            tags.append("Overbought")
    row["tags"] = tags
    return row


def classify(text):
    low = " " + text.lower()
    return [name for name, words in CATALYST_RULES if any(w in low for w in words)]


def upcoming_date(text, today):
    low = text.lower()
    if not any(w in low for w in FORWARD_WORDS):
        return None
    for m in DATE_RE.finditer(text):
        month = MONTHS.get(m.group(1)[:3].lower())
        day = int(m.group(2))
        year = int(m.group(3)) if m.group(3) else today.year
        try:
            d = dt.date(year, month, day)
        except (TypeError, ValueError):
            continue
        if not m.group(3) and d < today:
            d = d.replace(year=d.year + 1)
        if today <= d <= today + dt.timedelta(days=WINDOW_DAYS):
            return d
    return None


# ---------- Main ----------

def main():
    now_la = dt.datetime.now(LA)
    if os.environ.get("FORCE", "").lower() != "true" and now_la.hour != 6:
        print(f"It's {now_la:%H:%M} in Los Angeles, not the 6 AM run; skipping (DST guard).")
        return
    today = now_la.date()

    # Catalyst calendar from the repo
    cal_path = ROOT / "catalysts.json"
    calendar = json.loads(cal_path.read_text()) if cal_path.exists() else {"events": []}
    catalysts = []
    for ev in calendar.get("events", []):
        try:
            d = dt.date.fromisoformat(ev["date"])
        except (KeyError, ValueError):
            continue
        days = (d - today).days
        if 0 <= days <= WINDOW_DAYS:
            catalysts.append({**ev, "daysAway": days, "fromNews": False})

    # Bars for everything we scan
    bars = daily_bars(sorted(set(RSI_UNIVERSE + BIOTECH)))

    # Market: previous-session movers from the screener + RSI extremes
    movers = get("/v1beta1/screener/stocks/movers", {"top": 50})
    def mover_rows(lst):
        rows = []
        for m in lst:
            if m["price"] < MIN_PRICE:
                continue
            extra = daily_bars([m["symbol"]]).get(m["symbol"], []) if m["symbol"] not in bars else bars[m["symbol"]]
            row = make_row(m["symbol"], extra) or {"symbol": m["symbol"], "tags": [], "volume": 0,
                                                    "relVolume": None, "rsi": None}
            row["price"], row["changePct"] = round(m["price"], 2), round(m["percent_change"], 2)
            rows.append(row)
            if len(rows) >= 10:
                break
        return rows

    gainers = mover_rows(movers.get("gainers", []))
    losers = mover_rows(movers.get("losers", []))

    universe_rows = [r for s in RSI_UNIVERSE if (r := make_row(s, bars.get(s, [])))]
    oversold = sorted([r for r in universe_rows if r["rsi"] is not None and r["rsi"] <= OVERSOLD],
                      key=lambda r: r["rsi"])
    overbought = sorted([r for r in universe_rows if r["rsi"] is not None and r["rsi"] >= OVERBOUGHT],
                        key=lambda r: -r["rsi"])

    # Biotech
    bio_rows = [r for s in BIOTECH if (r := make_row(s, bars.get(s, []))) and r["price"] >= BIOTECH_MIN_PRICE]

    # News + dates mentioned in news
    seen, news_items = set(), []
    for item in news(BIOTECH[:100]) + news():
        if item["id"] in seen:
            continue
        seen.add(item["id"])
        text = item["headline"] + ". " + (item.get("summary") or "")
        tags = classify(text)
        on_watch = any(s in BIOTECH for s in item.get("symbols", []))
        if not (on_watch or "FDA" in tags or "Trial" in tags):
            continue
        news_items.append({"headline": item["headline"], "url": item.get("url"),
                           "symbols": item.get("symbols", [])[:4], "tags": tags,
                           "createdAt": item["created_at"]})
        d = upcoming_date(text, today)
        if d and item.get("symbols"):
            tk = item["symbols"][0]
            if not any(c["ticker"] == tk and c["date"] == d.isoformat() for c in catalysts):
                catalysts.append({"date": d.isoformat(), "ticker": tk, "company": item.get("source", "News"),
                                  "drug": item["headline"], "indication": "Date found in news; verify",
                                  "type": "PDUFA" if "pdufa" in text.lower() else "News", "note": None,
                                  "daysAway": (d - today).days, "fromNews": True})
    catalysts.sort(key=lambda c: c["daysAway"])

    upcoming_by_ticker = {}
    for c in catalysts:
        upcoming_by_ticker.setdefault(c["ticker"], c)
    for r in bio_rows:
        c = upcoming_by_ticker.get(r["symbol"])
        if c:
            r["tags"].insert(0, f"📅 {c['type']} " + ("today" if c["daysAway"] == 0 else f"in {c['daysAway']}d"))

    bio_unusual = [r for r in bio_rows if "🔥 Unusual" in r["tags"]]
    bio_top = sorted(bio_rows, key=lambda r: -abs(r["changePct"]))[:10]

    result = {
        "generated": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "generatedLocal": now_la.strftime("%a %b %-d, %-I:%M %p PT"),
        "calendarUpdated": calendar.get("updated"),
        "catalysts": catalysts,
        "biotechUnusual": bio_unusual,
        "biotechTop": bio_top,
        "gainers": gainers,
        "losers": losers,
        "oversold": oversold[:10],
        "overbought": overbought[:10],
        "news": news_items[:20],
    }
    out = ROOT / "scan" / "latest.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(result, indent=1, ensure_ascii=False))
    print(f"Wrote {out}: {len(catalysts)} catalysts, {len(bio_unusual)} unusual biotech, "
          f"{len(oversold)} oversold, {len(gainers)} gainers")

    send_notification(result)


def send_notification(r):
    topic = os.environ.get("NTFY_TOPIC", "").strip()
    if not topic:
        print("NTFY_TOPIC not set; skipping notification.")
        return

    def short(rows, n=4):
        return ", ".join(f"{x['symbol']} {x['changePct']:+.1f}%" for x in rows[:n]) or "none"

    lines = []
    soon = [c for c in r["catalysts"] if c["daysAway"] <= 3]
    if soon:
        lines.append("📅 Next 3 days: " + "; ".join(
            f"{c['ticker']} {c['type']} " + ("today" if c["daysAway"] == 0 else f"in {c['daysAway']}d")
            for c in soon[:5]))
    later = len(r["catalysts"]) - len(soon)
    if later > 0:
        lines.append(f"📅 {later} more catalyst(s) in the next {WINDOW_DAYS} days")
    lines.append("🔥 Unusual biotech: " + short(r["biotechUnusual"]))
    lines.append("🧬 Biggest biotech moves: " + short(r["biotechTop"]))
    lines.append("📉 RSI oversold: " + (", ".join(f"{x['symbol']} {x['rsi']:.0f}" for x in r["oversold"][:5]) or "none"))
    lines.append("📈 Top gainers (prev. session): " + short(r["gainers"]))
    fda_news = [n for n in r["news"] if "FDA" in n["tags"]][:2]
    for n in fda_news:
        lines.append("📰 " + n["headline"][:110])

    req = urllib.request.Request(
        "https://ntfy.sh/" + urllib.parse.quote(topic),
        data="\n".join(lines).encode("utf-8"),
        headers={"Title": "Morning scan " + r["generatedLocal"], "Tags": "chart_with_upwards_trend"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        print("Notification sent:", resp.status)


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as e:
        print("Alpaca/HTTP error:", e.code, e.read().decode()[:300])
        sys.exit(1)
