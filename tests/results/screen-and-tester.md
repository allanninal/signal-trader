# The screen the validated preset came from, and its two gates (backtest, not live trading)

Protocol written before any out-of-sample number was looked at. Data: broker M1 history, server time; H1, H4 and D1 bars built
from M1. Costs: the spread of each bar's first minute (capped at the symbol's spec), swap per night, no commission. Rules: a signal
on a closed bar is acted on at the next bar's open, stop = stop multiple x ATR(14), no target, an opposite signal closes and
reverses, a same-side signal is ignored.

- In-sample (setting choice): entries 2020-01-01 to 2023-06-30. Out-of-sample (judgement): 2023-07-01 to 2026-09-30, halves split at 2025-02-15.
- One setting per test frozen from in-sample data only (highest in-sample t of the mean R per trade, at least 30 trades, positive mean).
- Pass criteria (all must hold): at least 40 trades; mean R > 0 and t >= 2.0; profit factor >= 1.20; mean R > 0 and PF > 1 in both
  halves; the same setting with a news pause on keeps mean R > 0. The MetaTrader 5 Strategy Tester must meet them too.

| Stage | Tests | Passes in Python | Expected by chance (bootstrap) |
|---|---:|---:|---:|
| First screen: 8 symbols x H1, H4, D1 x 4 signal sources | 96 | 1 | 0.76 |
| Extension: 29 more symbols, same rules (settings frozen before the numbers were computed) | 348 | 0 | 1.78 |
| All | 444 | 1 | 2.55 |

Holm-adjusted p (one-sided) of the best result: 1.0 over the 444. Best t among the 348 new tests: 1.93.

The one pass: XAUUSD H4, SuperTrend (ATR 10, multiplier 2.0), stop 3 ATR, no target.

| | trades | mean R | t | PF | halves mean R |
|---|---:|---:|---:|---:|---|
| In-sample 2020-01 to 2023-06 | | | 0.51 | 1.11 | |
| Python, out of sample | 212 | +0.179 | 2.05 | 1.52 | +0.12 / +0.24 |
| Python, parity window | 211 | +0.184 | 2.09 | 1.53 | |
| MetaTrader 5 Strategy Tester (1-minute OHLC, 0.01 lot, real per-bar spreads) | 211 | +0.180 | 2.06 | 1.52 | +0.118 / +0.246 |

All five criteria are met in the MT5 tester. Out of sample the profit is all buys: 106 buys +0.40 R each, 106 sells -0.04 R each,
in the 2023-26 gold rally. Neighbouring settings are weaker (ATR 7: t 1.57); doubling the spread barely changes it (t 2.00).

Parity, Python simulation against the MT5 tester (signals are the EA's own logged signals): XAUUSD H4 SuperTrend preset
212 of 212 signals and 211 of 211 trades identical, entry time and side 100%, exit bar 100%. Other runs (default settings, EURUSD
H1, 2025 to 2026): UT Bot 548 / 548 signals, exit bar 98.9%; SuperTrend 270 / 270, 99.3%; Range Filter 330 / 330, 99.4%.

# MetaTrader 4 edition: publish gate failed (2026-10-20), so no MT4 edition is published

The MT4 port reproduced the EA exactly in the MT4 tester (XAUUSD H4, every tick): 212 / 212 signals and 211 / 211 trades
identical to Python, entries 100%, exits 98.6%. But the gate judges the MT4 trade list, and it missed criterion 2:

| MT4 tester run | trades | mean R | t | PF | halves mean R |
|---|---:|---:|---:|---:|---|
| one fixed spread of 170 points | 211 | +0.149 | 1.70 | 1.41 | |
| two chunks, 170 points to 2025-09 and 20 after (set as the gate before it ran) | 211 | +0.152 | 1.74 | 1.42 | +0.076 / +0.234 |

The MT5 tester's t was 2.06 on real per-bar spreads; MT4 cannot model those. By the rule that an EA is published only if it
passes both backtests, there is no MT4 edition and this repository holds no MT4 code.
