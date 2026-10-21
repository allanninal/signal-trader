# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
# distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/
# Origin of the maths: UT Bot idea by Yo_adriiiiaan (from an original idea by HPotter), TradingView "UT Bot Alerts" by
# QuantNomad; SuperTrend follows the widely published TradingView ATR-band script; Range Filter is an own implementation of the
# published range-filter method.
"""Python statement of the three signal engines of Signal Trader (UT Bot, SuperTrend, Range Filter) and of its trade rule,
written from the indicators' published semantics (not translated from the MQL code). No terminal needed.

    sig = signals("st", dict(atr=10, mult=2.0), o, h, l, c)        # +1 buy / -1 sell / 0 per closed bar
    trades = run(bars, sig, stop_atr=3.0)                          # bars: DataFrame open, high, low, close, spread

Engines (each reports a signal for a CLOSED bar only; the last array bar is treated as still forming):
  ut  UT Bot Alerts: ATR trailing stop on the close (key value x Wilder ATR), buy/sell on the cross.
  st  SuperTrend: hl2 +/- multiplier x Wilder ATR bands; a signal when the trend flips.
  rf  Range Filter: the filter moves only when price travels more than the smoothed range from it; a signal is the first
      buy setup after a sell setup (and vice versa).
Trade rule (the EA's): a signal on closed bar i is acted on at the open of bar i+1; an opposite position is closed at that
open and reversed; a same-side signal is ignored; otherwise a market order. The stop is stop_atr x ATR(14, Wilder) of bar i,
no target. A buy fills at the ask (open + spread), a sell at the bid (open); a buy stop is hit when the bid low touches it, a
sell stop when the ask (high + spread) does; a gap fills at the stop level (the tester's behaviour)."""
import numpy as np
import pandas as pd

NAN = np.nan


def above(a, b):
    """Strict a > b ignoring floating-point noise (a band can tie a close exactly in real arithmetic); same as MQL5."""
    return a - b > 1e-10 * abs(b)


def below(a, b):
    return b - a > 1e-10 * abs(b)


def true_range(h, l, c):
    tr = h - l
    tr[1:] = np.maximum(tr[1:], np.maximum(np.abs(h[1:] - c[:-1]), np.abs(l[1:] - c[:-1])))
    return tr


def sma(x, n):
    """Plain SMA. Each window is summed left to right (like Pine's ta.sma and the MQL5 loop); a running cumsum
    difference would carry ~1e-13 noise, and SuperTrend compares close against bands that can tie exactly."""
    out = np.full(len(x), NAN)
    for i in range(n - 1, len(x)):
        s = 0.0
        for v in x[i - n + 1:i + 1]:
            s += v
        out[i] = s / n
    return out


def rma(x, n):
    """RMA seeded with the SMA of x[:n]; x may carry leading NaN (then seeded at the first full window)."""
    out = np.full(len(x), NAN)
    first = int(np.argmax(~np.isnan(x))) if (~np.isnan(x)).any() else len(x)
    s = first + n - 1
    if s >= len(x):
        return out
    out[s] = x[first:first + n].mean()
    for i in range(s + 1, len(x)):
        out[i] = (out[i - 1] * (n - 1) + x[i]) / n
    return out


def ema(x, n):
    out = np.full(len(x), NAN)
    if len(x) < n:
        return out
    out[n - 1] = x[:n].mean()
    k = 2.0 / (n + 1)
    for i in range(n, len(x)):
        out[i] = out[i - 1] + k * (x[i] - out[i - 1])
    return out


def supertrend(o, h, l, c, period=10, mult=3.0, rma_atr=True, use_ema=False, ema_period=200):
    """Returns (line, buy, sell) arrays; buy/sell hold the arrow price (low/high) or NaN.
    The last bar is treated as still forming: no signal on it."""
    n = len(c)
    src = (h + l) / 2.0
    tr = true_range(h, l, c)
    atr = rma(tr, period) if rma_atr else sma(tr, period)
    e = ema(c, ema_period)
    up, dn, trend = np.full(n, NAN), np.full(n, NAN), np.full(n, NAN)
    line, buy, sell = np.full(n, NAN), np.full(n, NAN), np.full(n, NAN)
    for i in range(n):
        if np.isnan(atr[i]):
            continue
        u, d = src[i] - mult * atr[i], src[i] + mult * atr[i]
        u1 = up[i - 1] if i > 0 and not np.isnan(up[i - 1]) else u      # nz(up[1], up)
        d1 = dn[i - 1] if i > 0 and not np.isnan(dn[i - 1]) else d
        if i > 0 and above(c[i - 1], u1):
            u = max(u, u1)
        if i > 0 and below(c[i - 1], d1):
            d = min(d, d1)
        t_prev = trend[i - 1] if i > 0 and not np.isnan(trend[i - 1]) else 1.0
        t = t_prev
        if t == -1 and above(c[i], d1):
            t = 1.0
        elif t == 1 and below(c[i], u1):
            t = -1.0
        up[i], dn[i], trend[i] = u, d, t
        line[i] = u if t == 1 else d
        if i == 0 or i == n - 1 or np.isnan(trend[i - 1]):
            continue
        b, s = t == 1 and trend[i - 1] == -1, t == -1 and trend[i - 1] == 1
        if use_ema:
            b = b and not np.isnan(e[i]) and c[i] > e[i]
            s = s and not np.isnan(e[i]) and c[i] < e[i]
        if b:
            buy[i] = l[i]
        if s:
            sell[i] = h[i]
    return line, buy, sell


def heikin_close(o, h, l, c):
    return (o + h + l + c) / 4.0


def utbot(o, h, l, c, key=1.0, atr_period=10, heikin=False, use_ema=False, ema_period=200):
    """Returns (trail, buy, sell) arrays; buy/sell hold the arrow price (low/high) or NaN.
    The last bar is treated as still forming: no signal on it."""
    n = len(c)
    src = heikin_close(o, h, l, c) if heikin else c.copy()
    atr = rma(true_range(h, l, c), atr_period)
    e = ema(c, ema_period)
    trail = np.full(n, NAN)
    buy, sell = np.full(n, NAN), np.full(n, NAN)
    for i in range(n):
        if np.isnan(atr[i]):
            continue
        prev = trail[i - 1] if i > 0 and not np.isnan(trail[i - 1]) else 0.0
        s, s1, nl = src[i], (src[i - 1] if i > 0 else src[i]), key * atr[i]
        if s > prev and s1 > prev:
            trail[i] = max(prev, s - nl)
        elif s < prev and s1 < prev:
            trail[i] = min(prev, s + nl)
        else:
            trail[i] = s - nl if s > prev else s + nl
        if i == 0 or i == n - 1 or np.isnan(trail[i - 1]):
            continue
        up = s > trail[i] and s1 <= trail[i - 1]
        dn = s < trail[i] and s1 >= trail[i - 1]
        if use_ema:
            up = up and not np.isnan(e[i]) and c[i] > e[i]
            dn = dn and not np.isnan(e[i]) and c[i] < e[i]
        if up:
            buy[i] = l[i]
        if dn:
            sell[i] = h[i]
    return trail, buy, sell


def range_filter_run(src, period=100, mult=3.0):
    rows = []
    prev = 0.0
    avrng = smrng = rng = filt = prev_filt = None
    up = dn = cond = 0
    a1 = 2.0 / (period + 1)
    wper = 2 * period - 1
    a2 = 2.0 / (wper + 1)
    for k, x in enumerate(src):
        ev = 0
        if k >= 1:
            d = abs(x - prev)
            avrng = d if avrng is None else avrng + a1 * (d - avrng)
            smrng = avrng if smrng is None else smrng + a2 * (avrng - smrng)
            rng = smrng * mult
            prev_filt = filt
            if filt is None:
                filt = x
            else:
                f, r = filt, rng
                if x > f:
                    filt = f if x - r < f else x - r
                else:
                    filt = f if x + r > f else x + r
            if prev_filt is not None:
                if filt > prev_filt:
                    up, dn = up + 1, 0
                elif filt < prev_filt:
                    dn, up = dn + 1, 0
            moved = x != prev
            buy = x > filt and moved and up > 0
            sell = x < filt and moved and dn > 0
            p = cond
            if buy:
                cond = 1
            elif sell:
                cond = -1
            if buy and p == -1:
                ev = 1
            elif sell and p == 1:
                ev = -1
        prev = x
        rows.append(dict(filt=filt, range=rng, up=up, dn=dn, cond=cond, ev=ev,
                         side=1 if up > 0 else (-1 if dn > 0 else 0)))
    return rows


def atr14(h, l, c, n=14):
    """Wilder ATR (RMA seeded with the SMA of the first n true ranges): the unit of the stop distance."""
    return rma(true_range(h, l, c), n)


def _flags(buy, sell):
    return np.where(~np.isnan(buy), 1, 0) + np.where(~np.isnan(sell), -1, 0)


def signals(source, p, o, h, l, c):
    o, h, l, c = (np.ascontiguousarray(x, dtype=float) for x in (o, h, l, c))
    if source == "ut":
        _, b, s = utbot(o, h, l, c, key=p["key"], atr_period=p["atr"], heikin=False, use_ema=bool(p.get("ema", 0)))
        return _flags(b, s)
    if source == "st":
        _, b, s = supertrend(o, h, l, c, period=p["atr"], mult=p["mult"], use_ema=bool(p.get("ema", 0)))
        return _flags(b, s)
    if source == "rf":
        out = np.array([r["ev"] for r in range_filter_run(list(c), p["period"], p["mult"])], dtype=int)
        out[-1] = 0                                  # the last array bar is still forming
        return out
    raise ValueError(source)


def run(bars, sig, stop_atr=3.0):
    """Trades on bars (DataFrame with open, high, low, close and spread in price units), gross of swap.
    Columns: side, entry_bar, exit_bar (bar open times), entry, exit, dist, r, why."""
    o, h, l, c = (bars[k].to_numpy(float) for k in ("open", "high", "low", "close"))
    sp = bars["spread"].to_numpy(float)
    idx, n = bars.index, len(c)
    atr = atr14(h, l, c)
    rows, cur = [], None

    def locate(k_in, side, sl):
        for k in range(k_in, n):
            if side > 0 and l[k] <= sl:
                return k, sl, "stop"
            if side < 0 and h[k] + sp[k] >= sl:
                return k, sl, "stop"
        return None

    def close(k, px, why):
        nonlocal cur
        pnl = (px - cur["entry"]) * cur["side"]
        rows.append(dict(side=cur["side"], entry_bar=idx[cur["k_in"]], exit_bar=idx[k], entry=cur["entry"], exit=px,
                         dist=cur["dist"], r=pnl / cur["dist"], why=why))
        cur = None

    for i in np.flatnonzero(sig != 0):
        k = i + 1
        if k >= n or np.isnan(atr[i]):
            continue
        s = int(sig[i])
        if cur is not None and cur["exit"] is not None and cur["exit"][0] < k:
            close(*cur["exit"])
        if cur is not None:
            if cur["side"] == s:
                continue
            close(k, o[k] if cur["side"] > 0 else o[k] + sp[k], "reverse")
        dist = stop_atr * atr[i]
        entry = o[k] + sp[k] if s > 0 else o[k]
        sl = entry - dist if s > 0 else entry + dist
        cur = dict(side=s, k_in=k, entry=entry, dist=dist, exit=locate(k, s, sl))
    if cur is not None and cur["exit"] is not None:
        close(*cur["exit"])
    return pd.DataFrame(rows)
