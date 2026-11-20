import Foundation

enum RSI {
    /// Wilder's Relative Strength Index of the latest close.
    /// Returns nil when there are not more than `period` closes.
    static func compute(closes: [Double], period: Int = 14) -> Double? {
        guard period > 0, closes.count > period else { return nil }

        var gain = 0.0
        var loss = 0.0
        for i in 1...period {
            let change = closes[i] - closes[i - 1]
            if change > 0 { gain += change } else { loss -= change }
        }

        let p = Double(period)
        var avgGain = gain / p
        var avgLoss = loss / p

        for i in (period + 1)..<closes.count {
            let change = closes[i] - closes[i - 1]
            avgGain = (avgGain * (p - 1) + max(change, 0)) / p
            avgLoss = (avgLoss * (p - 1) + max(-change, 0)) / p
        }

        if avgLoss == 0 { return avgGain == 0 ? 50 : 100 }
        let rs = avgGain / avgLoss
        return 100 - 100 / (1 + rs)
    }
}
