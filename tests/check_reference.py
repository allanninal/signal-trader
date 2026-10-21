# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 (see LICENSE)
"""Self-test of tests/reference.py on synthetic bars (no broker data needed).

    python3 tests/check_reference.py [seeds]        default 20 seeds, 3 years of H4 bars each

For every random walk and each source (UT Bot, SuperTrend, Range Filter) it checks: the last bar never carries a signal (it
is still forming); SuperTrend signals alternate buy, sell, buy; every trade enters at the open of the bar after a signal bar;
the stop distance is stop x ATR(14) of the signal bar; trades never overlap; a reversal exits and re-enters at the same open on
the other side; a stop exit is on the bar where the extreme touches the stop."""
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent))
from reference import signals, run, atr14  # noqa: E402

SOURCES = {"ut": dict(key=2.0, atr=10, ema=0), "st": dict(atr=10, mult=2.0, ema=0), "rf": dict(period=100, mult=3.0)}


def synth(seed, years=3):
    rng = np.random.default_rng(seed)
    idx = pd.date_range("2021-01-01", periods=years * 365 * 6, freq="4h")
    idx = idx[idx.dayofweek < 5]
    drift = 0.15 * np.sin(np.arange(len(idx)) / 400.0)
    close = 1800 + np.cumsum(rng.normal(drift, 6.0))
    open_ = np.concatenate(([1800.0], close[:-1]))
    span = np.abs(rng.normal(0, 3.0, len(idx)))
    return pd.DataFrame({"open": open_, "high": np.maximum(open_, close) + span, "low": np.minimum(open_, close) - span,
                         "close": close, "spread": rng.choice([0.2, 0.3, 0.5], len(idx))}, index=idx)


def main(seeds):
    problems, n_sig, n_tr = [], 0, 0
    for seed in range(seeds):
        b = synth(seed)
        o, h, l, c = (b[k].to_numpy(float) for k in ("open", "high", "low", "close"))
        atr = atr14(h, l, c)
        for src, p in SOURCES.items():
            sig = signals(src, p, o, h, l, c)
            n_sig += int((sig != 0).sum())
            if sig[-1] != 0:
                problems.append(("signal on the last (forming) bar", src, seed))
            if src == "st":
                s = sig[sig != 0]
                if len(s) > 1 and (s[1:] == s[:-1]).any():
                    problems.append(("SuperTrend signals do not alternate", src, seed))
            tr = run(b, sig, 3.0)
            n_tr += len(tr)
            pos_idx = {t: k for k, t in enumerate(b.index)}
            last_exit = None
            for i, r in enumerate(tr.itertuples()):
                k = pos_idx[r.entry_bar]
                if sig[k - 1] != r.side:
                    problems.append(("entry not on the bar after a same-side signal", src, seed, str(r.entry_bar)))
                if abs(r.dist - 3.0 * atr[k - 1]) > 1e-9:
                    problems.append(("stop distance is not 3 x ATR(14) of the signal bar", src, seed, str(r.entry_bar)))
                if last_exit is not None and r.entry_bar < last_exit:
                    problems.append(("overlap", src, seed, str(r.entry_bar)))
                if i > 0 and tr.iloc[i - 1].why == "reverse":
                    q = tr.iloc[i - 1]
                    if not (q.exit_bar == r.entry_bar and q.side == -r.side):
                        problems.append(("reversal not at the same open", src, seed, str(r.entry_bar)))
                if r.why == "stop":
                    j = pos_idx[r.exit_bar]
                    touched = l[j] <= r.exit if r.side > 0 else h[j] + b.spread.iloc[j] >= r.exit
                    if not touched:
                        problems.append(("stop exit without a touch", src, seed, str(r.exit_bar)))
                last_exit = r.exit_bar
    print(f"seeds: {seeds}, signals: {n_sig}, trades: {n_tr}")
    print(f"violations: {len(problems)}")
    for p in problems[:10]:
        print("  ", p)
    print("RESULT:", "PASS" if not problems else "FAIL")
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main(int(sys.argv[1]) if len(sys.argv) > 1 else 20))
