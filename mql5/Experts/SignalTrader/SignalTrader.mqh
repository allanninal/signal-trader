//+------------------------------------------------------------------+
//|                                                 SignalTrader.mqh |
//|                                      Copyright 2026, Allan Niñal |
//|                                  https://www.allanninal.dev/mql5 |
//+------------------------------------------------------------------+
//| Signal Trader: trades the closed-bar signals of one of three     |
//| engines (UT Bot, SuperTrend, Range Filter), embedded.            |
//| Automation, not a strategy with an edge: no profit is promised.  |
//|                                                                  |
//| Rules, identical in tests/reference.py:                          |
//|  * a signal on a closed bar is acted on at the next bar's open;  |
//|  * an opposite position is closed (and reversed), a same-side    |
//|    signal is ignored, otherwise a market order is sent;          |
//|  * stop = stop multiple x ATR(14, Wilder) of the signal bar,     |
//|    optional target = x times the stop distance.                  |
//| Fixed lot (0.01 or the broker minimum), one source at a time.    |
//| Tester: when the pair is not one of the validated presets the EA |
//| still trades (so the Market validator can run it); live it       |
//| refuses new orders there.                                        |
//+------------------------------------------------------------------+
// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 (see LICENSE)
#property strict
#include <Trade/Trade.mqh>
#include "StEngines.mqh"
#include "StPanel.mqh"
#include "StPresets.mqh"

#define ST_NAME "Signal Trader"

input group "Signal"
input ENUM_ST_SOURCE InpSource = ST_SRC_UT;   // Signal source
input double InpUtKey    = 2.0;     // UT Bot: key value (ATR multiple)
input int    InpUtATR    = 10;      // UT Bot: ATR period
input bool   InpUtEMA    = false;   // UT Bot: only with the EMA(200) trend
input int    InpStATR    = 10;      // SuperTrend: ATR period
input double InpStMult   = 3.0;     // SuperTrend: ATR multiplier
input bool   InpStEMA    = false;   // SuperTrend: only with the EMA(200) trend
input int    InpRfPeriod = 100;     // Range Filter: sampling period
input double InpRfMult   = 3.0;     // Range Filter: range multiplier
input group "Trade"
input double InpStopATR  = 2.0;     // Stop loss, x ATR(14) of the signal bar
input double InpTpR      = 0.0;     // Take profit, x the stop distance (0 = none)
input long   InpMagic    = 26101701;// Magic number
input int    InpSlippage = 30;      // Maximum slippage, points
input group "Display"
input bool   InpPanel    = true;    // Show the panel
input bool   InpDebug    = false;   // Log every signal and trade (Experts tab)

#define ST_HIST 3000                   // closed bars the engines are warmed up with
#define ST_MAX_STOP_PCT 50.0           // never open a trade whose stop would lose more than this % of equity

CTrade   g_trade;
CEng    *g_eng=NULL;
datetime g_bar0=0;                     // open time of the current bar
datetime g_last_fed=0;                 // time of the last closed bar fed to the engines
int      g_last_sig=0;
datetime g_last_sig_bar=0;
string   g_msg="";
datetime g_msg_time=0;
int      g_panel_h=200;
bool     g_validated=true;
int      g_pend=0;                    // a signal waiting for the market to open (valid for the current bar only)
datetime g_pend_bar=0;

//+------------------------------------------------------------------+
datetime NowSrv(void) { return(MQLInfoInteger(MQL_TESTER) ? TimeCurrent() : TimeTradeServer()); }
string TfName(const ENUM_TIMEFRAMES tf) { return(StringSubstr(EnumToString(tf==PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : tf),7)); }
string Stamp(const datetime t) { return(TimeToString(t,TIME_DATE|TIME_MINUTES)); }

void Say(const string m,const string full="")
  {
   g_msg=m;
   g_msg_time=TimeLocal();
   if(InpDebug || full!="")
      Print(ST_NAME+": "+(full!="" ? full : m));
  }

bool MarketOpen(void)
  {
   datetime now=NowSrv();
   MqlDateTime dt;
   TimeToStruct(now,dt);
   int tod=(int)(now%86400);
   datetime from,to;
   for(int s=0; SymbolInfoSessionTrade(_Symbol,(ENUM_DAY_OF_WEEK)dt.day_of_week,s,from,to); s++)
     {
      int f=(int)(from%86400),t=(int)(to%86400);
      if(t==0)
         t=86400;
      if(f<t ? (tod>=f && tod<t) : (tod>=f || tod<t))
         return(true);
     }
   return(false);
  }

double NormPrice(const double p)
  {
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(ts>0)
      return(NormalizeDouble(MathRound(p/ts)*ts,_Digits));
   return(NormalizeDouble(p,_Digits));
  }

//--- money lost from `price` to `sl` by one lot
double LossPerLot(const double price,const double sl)
  {
   double tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv<=0)
      tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double by_tick=(tick>0 ? MathAbs(price-sl)/tick : 0)*tv;
   double p=0;
   if(price!=sl && OrderCalcProfit(sl<price ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,_Symbol,1.0,price,sl,p))
      return(MathMax(by_tick,MathAbs(p)));
   return(by_tick);
  }

int LotDigits(void)
  {
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   int d=0;
   while(d<8 && step>0 && MathAbs(step*MathPow(10,d)-MathRound(step*MathPow(10,d)))>1e-9)
      d++;
   return(d);
  }

//--- the volume for an entry at `price` with stop `sl`; 0 = refuse (message in `why`)
double EntryLots(const bool buy,const double price,const double sl,string &why)
  {
   double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   why="";
   double lots=MathMax(0.01,vmin);                    // 0.01, or the broker minimum when that is larger
   if(step>0)
      lots=MathCeil(lots/step-1e-9)*step;
   lots=NormalizeDouble(MathMin(lots,vmax),8);
   if(LossPerLot(price,sl)*lots>AccountInfoDouble(ACCOUNT_EQUITY)*ST_MAX_STOP_PCT/100.0)
     { why=StringFormat("the stop would lose more than %.0f%% of equity",ST_MAX_STOP_PCT); return(0); }
   double m=0;
   if(!OrderCalcMargin(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,_Symbol,lots,price,m) || m>AccountInfoDouble(ACCOUNT_MARGIN_FREE)*0.95)
     { why="not enough free margin"; return(0); }
   return(lots);
  }

//--- this EA's position on the symbol: ticket (0 = none), direction +1/-1
ulong FindPos(int &dir)
  {
   dir=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong t=PositionGetTicket(i);
      if(t==0 || PositionGetString(POSITION_SYMBOL)!=_Symbol || PositionGetInteger(POSITION_MAGIC)!=InpMagic)
         continue;
      dir=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? 1 : -1);
      return(t);
     }
   return(0);
  }

//+------------------------------------------------------------------+
//| Engines                                                          |
//+------------------------------------------------------------------+
CEng *MakeEngine(const ENUM_ST_SOURCE s)
  {
   switch(s)
     {
      case ST_SRC_UT: return(new CUtBot(InpUtKey,InpUtATR,InpUtEMA));
      case ST_SRC_ST: return(new CSuperTrend(InpStATR,InpStMult,InpStEMA));
      default:        return(new CRangeFilter(InpRfPeriod,InpRfMult));
     }
  }

//--- warm the engine up with the last ST_HIST closed bars
bool WarmUp(void)
  {
   MqlRates r[];
   ArraySetAsSeries(r,false);
   int n=CopyRates(_Symbol,_Period,1,ST_HIST,r);
   if(n<300)
      return(false);
   g_eng.Clear();
   for(int i=0; i<n; i++)
     {
      g_eng.Feed(r[i].open,r[i].high,r[i].low,r[i].close);
     }
   g_last_fed=r[n-1].time;
   return(true);
  }

//--- feed the closed bars that arrived since the last call; returns the signal of the newest closed bar
int FeedNew(datetime &sig_bar)
  {
   sig_bar=0;
   MqlRates r[];
   ArraySetAsSeries(r,false);
   int n=CopyRates(_Symbol,_Period,1,40,r);
   if(n<1)
      return(0);
   if(r[n-1].time<=g_last_fed)
      return(0);
   if(r[0].time>g_last_fed && g_last_fed>0)
     {
      WarmUp();                                          // missed more than 40 bars: rebuild, no trade on this one
      return(0);
     }
   int sig=0;
   for(int i=0; i<n; i++)
     {
      if(r[i].time<=g_last_fed)
         continue;
      sig=g_eng.Feed(r[i].open,r[i].high,r[i].low,r[i].close);
      sig_bar=r[i].time;
      if(i<n-1)
         sig=0;                                          // a catch-up bar: only the newest one is traded
     }
   g_last_fed=r[n-1].time;
   return(sig);
  }

//+------------------------------------------------------------------+
//| Entry                                                            |
//+------------------------------------------------------------------+
//--- why a new entry is not allowed right now ("" = allowed)
string EntryBlocked(void)
  {
   if(!MQLInfoInteger(MQL_TESTER) && !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return("Algo Trading is off");
   if(!MarketOpen())
      return("market closed");
   if(!g_validated && !MQLInfoInteger(MQL_TESTER))
      return("pair is not a validated preset");
   return("");
  }

bool OpenTrade(const int dir,const double atr)
  {
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask<=0 || bid<=0)
      return(false);
   bool buy=(dir>0);
   double price=buy ? ask : bid;
   double dist=InpStopATR*atr;
   //--- never closer than the broker allows: stop level + spread
   double minDist=((double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)+(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL))*_Point+(ask-bid)+2*_Point;
   if(dist<minDist)
     {
      PrintFormat("CHK stop widened from %s to %s (broker minimum)",DoubleToString(dist,_Digits),DoubleToString(minDist,_Digits));
      dist=minDist;
     }
   double sl=NormPrice(buy ? price-dist : price+dist);
   double tp=(InpTpR>0 ? NormPrice(buy ? price+InpTpR*dist : price-InpTpR*dist) : 0);
   string why;
   double lots=EntryLots(buy,price,sl,why);
   if(lots<=0)
     {
      Say("skipped: "+why,"entry skipped: "+why);
      return(false);
     }
   bool ok=(buy ? g_trade.Buy(lots,_Symbol,0,sl,tp,ST_NAME) : g_trade.Sell(lots,_Symbol,0,sl,tp,ST_NAME));
   if(!ok)
     {
      Say("refused, code "+IntegerToString(g_trade.ResultRetcode()),"order refused ("+g_trade.ResultRetcodeDescription()+")");
      return(false);
     }
   Say((buy ? "BUY " : "SELL ")+DoubleToString(lots,LotDigits()),
       StringFormat("%s %s lots at %s, stop %s%s",buy ? "BUY" : "SELL",DoubleToString(lots,LotDigits()),DoubleToString(price,_Digits),
                    DoubleToString(sl,_Digits),tp>0 ? ", target "+DoubleToString(tp,_Digits) : ""));
   return(true);
  }

void HandleSignal(const int sig,const datetime bar)
  {
   g_last_sig=sig;
   g_last_sig_bar=bar;
   static datetime dbg_bar=0;
   if(InpDebug && bar!=dbg_bar)
      Print("DBG ",Stamp(bar),": signal ",sig>0 ? "BUY" : "SELL");
   dbg_bar=bar;
   if(!MarketOpen())
     {
      g_pend=sig;                                        // retried on the next ticks of this bar, dropped at the next bar
      g_pend_bar=bar;
      return;
     }
   g_pend=0;
   int pdir;
   ulong pt=FindPos(pdir);
   if(pt!=0)
     {
      if(pdir==sig)
         return;                                         // same side: ignored
      if(!g_trade.PositionClose(pt))
        {
         Say("close refused, code "+IntegerToString(g_trade.ResultRetcode()),"close refused ("+g_trade.ResultRetcodeDescription()+")");
         return;
        }
     }
   string b=EntryBlocked();
   if(b!="")
     {
      Say("skipped: "+b,InpDebug ? "entry skipped: "+b : "");
      return;
     }
   double atr=g_eng.atr[g_eng.n-1];
   if(atr==EMPTY_VALUE || atr<=0)
      return;
   OpenTrade(sig,atr);
  }

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void Draw(void)
  {
   g_cursor=0;
   Box("bg",0,0,UI_W,g_panel_h+UI_PAD,UiBack(),UiRule());
   Box("hd",0,0,UI_W,UI_HEAD-4,g_ui_light ? C'240,241,244' : C'32,35,40',UiRule());
   Text("title",UI_PAD,5,"Signal Trader",UiText(),g_ui_font+1,"Segoe UI Semibold");
   Text("ed",UI_W-UI_PAD-28,7,"FREE",UiDim(),g_ui_font-1);
   int y=Section("s_sig",UI_HEAD-6,"SIGNAL");
   y=Row("r_src",y,"Source",g_eng.Describe(),UiText());
   y=Row("r_tf",y,"Chart",_Symbol+" "+TfName((ENUM_TIMEFRAMES)_Period),UiText());
   y=Row("r_pair",y,"Preset",g_validated ? "validated" : "not validated",g_validated ? UiPos() : UiWarn());
   string last=(g_last_sig==0 ? "none yet" : (g_last_sig>0 ? "BUY " : "SELL ")+Stamp(g_last_sig_bar));
   y=Row("r_last",y,"Last signal",last,g_last_sig>0 ? UiPos() : (g_last_sig<0 ? UiNeg() : UiDim()));
   y=Section("s_pos",y,"POSITION");
   int dir;
   ulong t=FindPos(dir);
   if(t!=0)
     {
      y=Row("p_side",y,"Side",dir>0 ? "BUY" : "SELL",dir>0 ? UiPos() : UiNeg());
      y=Row("p_vol",y,"Volume",DoubleToString(PositionGetDouble(POSITION_VOLUME),LotDigits()),UiText());
      y=Row("p_sl",y,"Stop loss",DoubleToString(PositionGetDouble(POSITION_SL),_Digits),UiText());
      double pl=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      y=Row("p_pl",y,"Open P/L",SMoney(pl)+" "+AccountInfoString(ACCOUNT_CURRENCY),Sign(pl));
     }
   else
     {
      y=Row("p_side",y,"Side","flat",UiDim());
      y=Row("p_vol",y,"Volume","-",UiDim());
      y=Row("p_sl",y,"Stop loss","-",UiDim());
      y=Row("p_pl",y,"Open P/L","-",UiDim());
     }
   y=Section("s_st",y,"STATE");
   y=Row("s_lot",y,"Lot","0.01",UiText());
   if(g_msg!="" && TimeLocal()-g_msg_time<30)
      y=Row("msg2",y,"Last action",g_msg,UiDim());
   else
      if(ObjectFind(0,SGT_PREFIX+"msg2_l")>=0)
        {
         ObjectDelete(0,SGT_PREFIX+"msg2_l");
         ObjectDelete(0,SGT_PREFIX+"msg2_v");
         CacheClear();
        }
   if(y!=g_panel_h)
     {
      g_panel_h=y;
      CacheClear();
      Draw();
      return;
     }
   if(g_panel_dirty)
     {
      ChartRedraw();
      g_panel_dirty=false;
     }
  }

//+------------------------------------------------------------------+
//| Events                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpStopATR<=0 || InpTpR<0 || InpUtKey<=0 || InpUtATR<1 || InpStATR<1 || InpStMult<=0 || InpRfPeriod<2 || InpRfMult<=0)
     {
      Print(ST_NAME+": check the inputs (stop, target, periods and multipliers must be positive)");
      return(INIT_PARAMETERS_INCORRECT);
     }
   g_eng=MakeEngine(InpSource);
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.LogLevel(LOG_LEVEL_NO);
   g_validated=StPresetValidated(_Symbol,(ENUM_TIMEFRAMES)_Period,InpSource);
   if(!WarmUp())
      Print(ST_NAME+": waiting for history (",_Symbol," ",TfName((ENUM_TIMEFRAMES)_Period),")");
   g_bar0=iTime(_Symbol,_Period,0);
   PrintFormat("%s: %s on %s %s, %s",ST_NAME,g_eng.Describe(),_Symbol,TfName((ENUM_TIMEFRAMES)_Period),
               g_validated ? "validated preset" : "NOT a validated preset");
   if(!g_validated && !MQLInfoInteger(MQL_TESTER))
      Alert(ST_NAME+": "+_Symbol+" "+TfName((ENUM_TIMEFRAMES)_Period)+" with this source is not a validated preset. No orders will be sent.");
   if(InpPanel && (!MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_VISUAL_MODE)))
     {
      g_ui_light=(ChartGetInteger(0,CHART_COLOR_BACKGROUND)==clrWhite);
      g_ui_corner=SGT_RIGHT;
      EventSetTimer(2);
      Draw();
     }
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(CheckPointer(g_eng)==POINTER_DYNAMIC)
      delete g_eng;
   PanelDelete();
  }

void OnTick()
  {
   if(g_eng.n==0 && !WarmUp())
      return;
   datetime b=iTime(_Symbol,_Period,0);
   if(g_pend!=0 && b==g_bar0 && g_pend_bar==iTime(_Symbol,_Period,1) && MarketOpen())
     {
      int ps=g_pend;
      g_pend=0;
      HandleSignal(ps,g_pend_bar);
     }
   if(b==0 || b==g_bar0)
      return;
   g_pend=0;
   g_bar0=b;
   datetime sb;
   int sig=FeedNew(sb);
   if(sig!=0 && sb==iTime(_Symbol,_Period,1))
      HandleSignal(sig,sb);
  }

void OnTimer()
  {
   if(InpPanel && g_eng!=NULL && (!MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_VISUAL_MODE)))
      Draw();
  }

//--- debug: one line per closed trade (entry and exit time, side, prices, stop at entry) for the parity check
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
  {
   if(!InpDebug || trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.symbol!=_Symbol)
      return;
   if(!HistoryDealSelect(trans.deal) || HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=InpMagic)
      return;
   if(HistoryDealGetInteger(trans.deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT)
      return;
   ulong pid=(ulong)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
   if(!HistorySelectByPosition(pid))
      return;
   double pin=0,sl=0,vol=0,swap=0,profit=0;
   datetime tin=0,tout=0;
   int side=0;
   double pout=0;
   for(int i=0; i<HistoryDealsTotal(); i++)
     {
      ulong d=HistoryDealGetTicket(i);
      long e=HistoryDealGetInteger(d,DEAL_ENTRY);
      if(e==DEAL_ENTRY_IN)
        {
         pin=HistoryDealGetDouble(d,DEAL_PRICE);
         tin=(datetime)HistoryDealGetInteger(d,DEAL_TIME);
         side=(HistoryDealGetInteger(d,DEAL_TYPE)==DEAL_TYPE_BUY ? 1 : -1);
         vol=HistoryDealGetDouble(d,DEAL_VOLUME);
         ulong o=(ulong)HistoryDealGetInteger(d,DEAL_ORDER);
         if(HistoryOrderSelect(o))
            sl=HistoryOrderGetDouble(o,ORDER_SL);
        }
      else
         if(e==DEAL_ENTRY_OUT)
           {
            pout=HistoryDealGetDouble(d,DEAL_PRICE);
            tout=(datetime)HistoryDealGetInteger(d,DEAL_TIME);
            profit+=HistoryDealGetDouble(d,DEAL_PROFIT);
           }
      swap+=HistoryDealGetDouble(d,DEAL_SWAP);
     }
   PrintFormat("TRD %s %s %s %s %.*f %.*f %.*f %.2f %.2f",TimeToString(tin,TIME_DATE|TIME_MINUTES),TimeToString(tout,TIME_DATE|TIME_MINUTES),
               side>0 ? "BUY" : "SELL",DoubleToString(vol,2),_Digits,pin,_Digits,pout,_Digits,sl,profit,swap);
  }
//+------------------------------------------------------------------+
