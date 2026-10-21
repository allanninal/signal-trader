//+------------------------------------------------------------------+
//|                                                   StEngines.mqh |
//|                                      Copyright 2026, Allan Niñal |
//|                                  https://www.allanninal.dev/mql5 |
//+------------------------------------------------------------------+
//| The three signal engines of Signal Trader (UT Bot, SuperTrend,   |
//| Range Filter), embedded so nothing else has to be installed.     |
//| Each is the calculation loop of the indicator moved into a class |
//| that is fed ONE CLOSED BAR at a time. Range Filter uses RF.mqh.  |
//| A signal is reported for the bar just fed, which is always       |
//| closed, so nothing repaints. The Python statement of the three   |
//| engines is tests/reference.py.                                   |
//+------------------------------------------------------------------+
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
// distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/
// Origin of the maths: UT Bot idea by Yo_adriiiiaan (from an original idea by HPotter), TradingView "UT Bot Alerts" by
// QuantNomad; SuperTrend follows the widely published TradingView ATR-band script; Range Filter is an own implementation
// of the published range-filter method.
#ifndef ST_ENGINES_MQH
#define ST_ENGINES_MQH

#include "RF.mqh"

#define ST_ATR_N 14                        // the stop distance unit

bool StAbove(const double a,const double b) { return(a-b>1e-10*MathAbs(b)); }
bool StBelow(const double a,const double b) { return(b-a>1e-10*MathAbs(b)); }

//--- bars fed so far plus Wilder ATR(14) (seeded with the SMA of the first 14 true ranges)
class CEng
  {
public:
   double o[],h[],l[],c[],atr[];
   int    n,cap;
                     CEng(void) { n=0; cap=0; }
   virtual          ~CEng(void) {}
   void              Clear(void) { n=0; cap=0; ArrayResize(o,0); ArrayResize(h,0); ArrayResize(l,0); ArrayResize(c,0); ArrayResize(atr,0); OnClear(); }
   virtual void      OnClear(void) {}
   virtual void      Grow(void)
     {
      if(n<cap)
         return;
      cap+=4096;
      ArrayResize(o,cap); ArrayResize(h,cap); ArrayResize(l,cap); ArrayResize(c,cap); ArrayResize(atr,cap);
     }
   double            TR(const int k)
     {
      if(k==0)
         return(h[k]-l[k]);
      return(MathMax(h[k]-l[k],MathMax(MathAbs(h[k]-c[k-1]),MathAbs(l[k]-c[k-1]))));
     }
   //--- feed one closed bar; returns +1 buy, -1 sell, 0 none for that bar
   int               Feed(const double O,const double H,const double L,const double C)
     {
      Grow();
      GrowState();
      int i=n;
      o[i]=O; h[i]=H; l[i]=L; c[i]=C;
      n++;
      if(i<ST_ATR_N-1)
         atr[i]=EMPTY_VALUE;
      else
         if(i==ST_ATR_N-1)
           {
            double s=0;
            for(int k=0; k<ST_ATR_N; k++)
               s+=TR(k);
            atr[i]=s/ST_ATR_N;
           }
         else
            atr[i]=(atr[i-1]*(ST_ATR_N-1)+TR(i))/ST_ATR_N;
      return(Step(i));
     }
   virtual void      GrowState(void) {}
   virtual int       Step(const int i) { return(0); }
   virtual string    Describe(void) { return(""); }
  };

//+------------------------------------------------------------------+
//| UT Bot (UTBotAlerts.mq5)                                         |
//+------------------------------------------------------------------+
class CUtBot : public CEng
  {
public:
   double InpKey;
   int    InpATR;
   bool   InpUseEMA;
   int    InpEMA;
   double g_line[],g_atr[],g_ema[];
                     CUtBot(const double key,const int atrp,const bool use_ema) { InpKey=key; InpATR=atrp; InpUseEMA=use_ema; InpEMA=200; }
   virtual void      OnClear(void) { ArrayResize(g_line,0); ArrayResize(g_atr,0); ArrayResize(g_ema,0); }
   virtual void      GrowState(void)
     {
      if(ArraySize(g_line)<cap)
        { ArrayResize(g_line,cap); ArrayResize(g_atr,cap); ArrayResize(g_ema,cap); }
     }
   virtual string    Describe(void) { return(StringFormat("UT Bot %.1f/%d%s",InpKey,InpATR,InpUseEMA ? " EMA200" : "")); }
   virtual int       Step(const int i)
     {
      //--- ATR: Wilder's smoothing of the true range, seeded with the SMA of the first InpATR values
      double tr=TR(i);
      if(i<InpATR-1)
         g_atr[i]=EMPTY_VALUE;
      else
         if(i==InpATR-1)
           {
            double s=0;
            for(int k=0; k<InpATR; k++)
               s+=TR(k);
            g_atr[i]=s/InpATR;
           }
         else
            g_atr[i]=(g_atr[i-1]*(InpATR-1)+tr)/InpATR;
      //--- EMA of the close, seeded with the SMA of the first InpEMA closes
      if(i<InpEMA-1)
         g_ema[i]=EMPTY_VALUE;
      else
         if(i==InpEMA-1)
           {
            double s=0;
            for(int k=0; k<InpEMA; k++)
               s+=c[k];
            g_ema[i]=s/InpEMA;
           }
         else
            g_ema[i]=g_ema[i-1]+2.0/(InpEMA+1)*(c[i]-g_ema[i-1]);
      //--- the trailing stop
      double prev=(i>0 ? g_line[i-1] : 0.0);
      if(g_atr[i]==EMPTY_VALUE)
        {
         g_line[i]=EMPTY_VALUE;
         return(0);
        }
      if(prev==EMPTY_VALUE)
         prev=0.0;
      double src=c[i],p1=(i>0 ? c[i-1] : src),nloss=InpKey*g_atr[i];
      if(src>prev && p1>prev)
         g_line[i]=MathMax(prev,src-nloss);
      else
         if(src<prev && p1<prev)
            g_line[i]=MathMin(prev,src+nloss);
         else
            g_line[i]=(src>prev ? src-nloss : src+nloss);
      if(i==0 || g_line[i-1]==EMPTY_VALUE)
         return(0);
      bool up=(src>g_line[i] && p1<=g_line[i-1]);
      bool dn=(src<g_line[i] && p1>=g_line[i-1]);
      if(InpUseEMA)
        {
         up=up && g_ema[i]!=EMPTY_VALUE && c[i]>g_ema[i];
         dn=dn && g_ema[i]!=EMPTY_VALUE && c[i]<g_ema[i];
        }
      return(up ? 1 : (dn ? -1 : 0));
     }
  };

//+------------------------------------------------------------------+
//| SuperTrend (SuperTrendSignalAlerts.mq5, RMA ATR)                 |
//+------------------------------------------------------------------+
class CSuperTrend : public CEng
  {
public:
   int    InpATR;
   double InpMult;
   bool   InpUseEMA;
   int    InpEMA;
   double g_up[],g_dn[],g_trend[],g_atr[],g_ema[];
                     CSuperTrend(const int atrp,const double mult,const bool use_ema) { InpATR=atrp; InpMult=mult; InpUseEMA=use_ema; InpEMA=200; }
   virtual void      OnClear(void) { ArrayResize(g_up,0); ArrayResize(g_dn,0); ArrayResize(g_trend,0); ArrayResize(g_atr,0); ArrayResize(g_ema,0); }
   virtual void      GrowState(void)
     {
      if(ArraySize(g_up)<cap)
        { ArrayResize(g_up,cap); ArrayResize(g_dn,cap); ArrayResize(g_trend,cap); ArrayResize(g_atr,cap); ArrayResize(g_ema,cap); }
     }
   virtual string    Describe(void) { return(StringFormat("SuperTrend %d/%.1f%s",InpATR,InpMult,InpUseEMA ? " EMA200" : "")); }
   virtual int       Step(const int i)
     {
      double tr=TR(i);
      g_atr[i]=EMPTY_VALUE;
      if(i>=InpATR-1)
        {
         if(i==InpATR-1)
           {
            double s=0;
            for(int k=i-InpATR+1; k<=i; k++)
               s+=TR(k);
            g_atr[i]=s/InpATR;
           }
         else
            g_atr[i]=(g_atr[i-1]*(InpATR-1)+tr)/InpATR;
        }
      if(i<InpEMA-1)
         g_ema[i]=EMPTY_VALUE;
      else
         if(i==InpEMA-1)
           {
            double s=0;
            for(int k=0; k<InpEMA; k++)
               s+=c[k];
            g_ema[i]=s/InpEMA;
           }
         else
            g_ema[i]=g_ema[i-1]+2.0/(InpEMA+1)*(c[i]-g_ema[i-1]);
      if(g_atr[i]==EMPTY_VALUE)
        {
         g_up[i]=EMPTY_VALUE;
         g_dn[i]=EMPTY_VALUE;
         g_trend[i]=EMPTY_VALUE;
         return(0);
        }
      double src=(h[i]+l[i])/2.0;
      double up=src-InpMult*g_atr[i];
      double dn=src+InpMult*g_atr[i];
      bool first=(i==0 || g_up[i-1]==EMPTY_VALUE);
      double up1=(first ? up : g_up[i-1]);
      double dn1=(first ? dn : g_dn[i-1]);
      if(i>0 && StAbove(c[i-1],up1))
         up=MathMax(up,up1);
      if(i>0 && StBelow(c[i-1],dn1))
         dn=MathMin(dn,dn1);
      double trend=(first ? 1.0 : g_trend[i-1]);
      if(trend==-1.0 && StAbove(c[i],dn1))
         trend=1.0;
      else
         if(trend==1.0 && StBelow(c[i],up1))
            trend=-1.0;
      g_up[i]=up;
      g_dn[i]=dn;
      g_trend[i]=trend;
      if(first)
         return(0);
      bool buy=(trend==1.0 && g_trend[i-1]==-1.0);
      bool sell=(trend==-1.0 && g_trend[i-1]==1.0);
      if(InpUseEMA)
        {
         buy=buy && g_ema[i]!=EMPTY_VALUE && c[i]>g_ema[i];
         sell=sell && g_ema[i]!=EMPTY_VALUE && c[i]<g_ema[i];
        }
      return(buy ? 1 : (sell ? -1 : 0));
     }
  };

//+------------------------------------------------------------------+
//| Range Filter (RF.mqh)                                            |
//+------------------------------------------------------------------+
class CRangeFilter : public CEng
  {
public:
   RFParams p;
   RFState  s;
                     CRangeFilter(const int period,const double mult) { p.period=period; p.mult=mult; RFInit(s); }
   virtual void      OnClear(void) { RFInit(s); }
   virtual string    Describe(void) { return(StringFormat("Range Filter %d/%.1f",p.period,p.mult)); }
   virtual int       Step(const int i)
     {
      RFFeed(s,p,c[i]);
      return(s.ev);
     }
  };

enum ENUM_ST_SOURCE
  {
   ST_SRC_UT=0,     // UT Bot
   ST_SRC_ST=1,     // SuperTrend
   ST_SRC_RF=2      // Range Filter
  };

#endif
//+------------------------------------------------------------------+
