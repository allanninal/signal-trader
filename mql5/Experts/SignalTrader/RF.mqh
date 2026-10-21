//+------------------------------------------------------------------+
//|                                                           RF.mqh |
//|                                      Copyright 2026, Allan Niñal |
//|                                  https://www.allanninal.dev/mql5 |
//+------------------------------------------------------------------+
//| Range Filter engine, one CLOSED bar per step (no repaint).       |
//| Own implementation of the published range-filter method:         |
//|   range r = EMA(EMA(|close - previous close|, period),           |
//|             2 x period - 1) x multiplier                         |
//|   filter: when the close is above the previous filter, the       |
//|     filter rises to close - r (it never falls in that case);     |
//|     below it, the filter falls to close + r (never rises); so it |
//|     only moves when price travels more than r away from it.      |
//|   bands = filter +/- r.                                          |
//|   trend counter: bars in a row the filter has risen (up) or      |
//|     fallen (down); an unchanged filter keeps the counts.         |
//|   buy setup: close above the filter, close not equal to the      |
//|     previous close, filter rising; sell mirrors it. A signal is  |
//|     the first buy setup after a sell setup (and vice versa).     |
//| EMAs are seeded with their first value (as TradingView's ema).   |
//| Tested against tests/reference.py.                               |
//+------------------------------------------------------------------+
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
// distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/
// Origin of the maths: UT Bot idea by Yo_adriiiiaan (from an original idea by HPotter), TradingView "UT Bot Alerts" by
// QuantNomad; SuperTrend follows the widely published TradingView ATR-band script; Range Filter is an own implementation
// of the published range-filter method.
#ifndef RF_MQH
#define RF_MQH

struct RFParams
  {
   int    period;                          // sampling period (100 by default)
   double mult;                            // range multiplier (3.0 by default)
  };

struct RFState
  {
   int    cnt;                             // bars fed; bar k = the k-th fed bar (0-based)
   double prev_src;
   double avrng;                           // EMA of |close change|
   double smrng;                           // EMA of avrng over 2*period-1, before the multiplier
   double range;                           // smrng * mult
   double filt;                            // EMPTY_VALUE until it starts (bar 1)
   double prev_filt;
   int    upward,downward;                 // bars the filter has risen / fallen in a row
   int    cond;                            // last setup: +1 buy, -1 sell, 0 none yet
   int    ev;                              // +1/-1 when the last bar gave a signal, else 0
   int    last_ev;                         // direction of the latest signal, 0 if none
   int    last_ev_bar;                     // bar of the latest signal, -1 if none
  };

void RFInit(RFState &s)
  {
   s.cnt=0; s.prev_src=0; s.avrng=EMPTY_VALUE; s.smrng=EMPTY_VALUE; s.range=EMPTY_VALUE;
   s.filt=EMPTY_VALUE; s.prev_filt=EMPTY_VALUE; s.upward=0; s.downward=0; s.cond=0;
   s.ev=0; s.last_ev=0; s.last_ev_bar=-1;
  }

//--- feed one CLOSED bar's close; true when it gave a signal (s.ev)
bool RFFeed(RFState &s,const RFParams &p,const double src)
  {
   int k=s.cnt;
   s.ev=0;
   if(k>=1)
     {
      double d=MathAbs(src-s.prev_src);
      double a1=2.0/(p.period+1);
      s.avrng=(s.avrng==EMPTY_VALUE ? d : s.avrng+a1*(d-s.avrng));
      int    wper=2*p.period-1;
      double a2=2.0/(wper+1);
      s.smrng=(s.smrng==EMPTY_VALUE ? s.avrng : s.smrng+a2*(s.avrng-s.smrng));
      s.range=s.smrng*p.mult;
      s.prev_filt=s.filt;
      if(s.filt==EMPTY_VALUE)
         s.filt=src;                                   // the filter starts at the first close with a range
      else
        {
         double f=s.filt,r=s.range;
         if(src>f)
            s.filt=(src-r<f ? f : src-r);
         else
            s.filt=(src+r>f ? f : src+r);
        }
      if(s.prev_filt!=EMPTY_VALUE)
        {
         if(s.filt>s.prev_filt)
           { s.upward++; s.downward=0; }
         else
            if(s.filt<s.prev_filt)
              { s.downward++; s.upward=0; }
        }
      bool moved=(src!=s.prev_src);
      bool buy=(src>s.filt && moved && s.upward>0);
      bool sell=(src<s.filt && moved && s.downward>0);
      int prev=s.cond;
      if(buy)
         s.cond=1;
      else
         if(sell)
            s.cond=-1;
      if(buy && prev==-1)
         s.ev=1;
      else
         if(sell && prev==1)
            s.ev=-1;
     }
   s.prev_src=src;
   s.cnt++;
   if(s.ev!=0)
     {
      s.last_ev=s.ev;
      s.last_ev_bar=k;
      return(true);
     }
   return(false);
  }

#endif
//+------------------------------------------------------------------+
