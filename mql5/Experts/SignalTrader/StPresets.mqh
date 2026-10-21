//+------------------------------------------------------------------+
//|                                                    StPresets.mqh |
//|                                      Copyright 2026, Allan Niñal |
//|                                  https://www.allanninal.dev/mql5 |
//+------------------------------------------------------------------+
//| Validated presets: symbol, timeframe and signal source that      |
//| passed BOTH the Python out-of-sample screen and the Strategy     |
//| Tester (see the README). Live, the EA opens orders only here.    |
//+------------------------------------------------------------------+
// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 (see LICENSE)
#ifndef ST_PRESETS_MQH
#define ST_PRESETS_MQH
#define ST_PRESET_N 1
//--- one row per validated chart: its symbol, timeframe and signal source
struct StPreset { string sym; ENUM_TIMEFRAMES tf; int src; };
const StPreset g_st_presets[ST_PRESET_N]=
  {
   {"XAUUSD",PERIOD_H4,1}
  };
//--- the broker may add a suffix to the symbol ("XAUUSD.m"): the preset name must be its start
bool StPresetValidated(const string sym,const ENUM_TIMEFRAMES tf,const int src)
  {
   for(int i=0; i<ST_PRESET_N; i++)
      if(g_st_presets[i].src==src && g_st_presets[i].tf==tf && StringFind(sym,g_st_presets[i].sym)==0)
         return(true);
   return(false);
  }
#endif
