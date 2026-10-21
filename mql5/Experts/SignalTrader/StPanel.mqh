//+------------------------------------------------------------------+
//|                                                     StPanel.mqh |
//|                                      Copyright 2026, Allan Niñal |
//|                                  https://www.allanninal.dev/mql5 |
//+------------------------------------------------------------------+
//| Chart panel drawing: cached labels and boxes (unchanged text is  |
//| never resent), sections, "label  value" rows. Light and dark     |
//| themes.                                                          |
//+------------------------------------------------------------------+
// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 (see LICENSE)
#ifndef SGT_PANEL_MQH
#define SGT_PANEL_MQH

enum ENUM_SGT_CORNER
  {
   SGT_LEFT=0,          // Top left
   SGT_RIGHT=1          // Top right
  };

#define SGT_PREFIX  "SGT_"             // chart object prefix
#define UI_W        318                // panel width
#define UI_PAD      10                 // inner padding
#define UI_VAL      112                // value column
#define UI_ROW      16                 // row height
#define UI_HEAD     24                 // title bar height
#define UI_GAP      6                  // space above a section title
#define UI_CHAR     7                  // Consolas 9 advance width, px

ENUM_SGT_CORNER g_ui_corner=SGT_LEFT;
int  g_ui_x=10,g_ui_y=26,g_ui_font=9;
bool g_ui_light=false;
bool g_panel_dirty=false;

color UiBack()   { return(g_ui_light ? C'250,250,251' : C'24,26,30');    }
color UiText()   { return(g_ui_light ? C'44,48,56'    : C'206,212,220'); }
color UiLabel()  { return(g_ui_light ? C'124,131,142' : C'122,130,142'); }
color UiHead()   { return(g_ui_light ? C'92,100,112'  : C'150,160,175'); }
color UiDim()    { return(g_ui_light ? C'140,146,157' : C'96,102,112');  }
color UiPos()    { return(g_ui_light ? C'38,118,66'   : C'126,192,143'); }
color UiNeg()    { return(g_ui_light ? C'176,58,58'   : C'226,124,124'); }
color UiWarn()   { return(g_ui_light ? C'160,112,28'  : C'220,178,116'); }
color UiRule()   { return(g_ui_light ? C'220,223,228' : C'48,52,58');    }

//--- per-object cache of what was last sent
string g_cache_name[];
string g_cache_txt[];
color  g_cache_clr[],g_cache_fill[];
int    g_cache_x[],g_cache_y[],g_cache_w[],g_cache_h[];
int    g_cursor=0;

int CacheSlot(const string name)
  {
   int n=ArraySize(g_cache_name);
   if(g_cursor<n && g_cache_name[g_cursor]==name)
      return(g_cursor++);
   for(int i=0; i<n; i++)
      if(g_cache_name[i]==name)
        {
         g_cursor=i+1;
         return(i);
        }
   ArrayResize(g_cache_name,n+1,32);
   ArrayResize(g_cache_txt,n+1,32);
   ArrayResize(g_cache_clr,n+1,32);
   ArrayResize(g_cache_x,n+1,32);
   ArrayResize(g_cache_y,n+1,32);
   ArrayResize(g_cache_w,n+1,32);
   ArrayResize(g_cache_h,n+1,32);
   ArrayResize(g_cache_fill,n+1,32);
   g_cache_name[n]=name;
   g_cache_txt[n]="\x01";
   g_cache_clr[n]=clrNONE;
   g_cache_fill[n]=clrNONE;
   g_cache_x[n]=g_cache_y[n]=g_cache_w[n]=g_cache_h[n]=INT_MIN;
   g_cursor=n+1;
   return(n);
  }

void CacheClear(void)
  {
   ArrayResize(g_cache_name,0);
   ArrayResize(g_cache_txt,0);
   ArrayResize(g_cache_clr,0);
   ArrayResize(g_cache_x,0);
   ArrayResize(g_cache_y,0);
   ArrayResize(g_cache_w,0);
   ArrayResize(g_cache_h,0);
   ArrayResize(g_cache_fill,0);
   g_cursor=0;
   g_panel_dirty=true;
  }

void SetInt(const string name,const ENUM_OBJECT_PROPERTY_INTEGER prop,const long v,int &cache)
  {
   if(cache==(int)v)
      return;
   ObjectSetInteger(0,name,prop,v);
   cache=(int)v;
   g_panel_dirty=true;
  }

int PanelX(const int x) { return(g_ui_corner==SGT_LEFT ? g_ui_x+x : g_ui_x+UI_W-x); }
ENUM_BASE_CORNER PanelCorner(void) { return(g_ui_corner==SGT_LEFT ? CORNER_LEFT_UPPER : CORNER_RIGHT_UPPER); }

void Text(const string id,const int x,const int y,const string text,const color clr,
          const int size=0,const string font="Consolas")
  {
   string name=SGT_PREFIX+id;
   string txt=(text=="") ? " " : text;           // an empty label would show the word "Label"
   int slot=CacheSlot(name);
   if(g_cache_x[slot]==INT_MIN && ObjectFind(0,name)<0)
     {
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,PanelCorner());
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetString(0,name,OBJPROP_FONT,font);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,size>0 ? size : g_ui_font);
     }
   SetInt(name,OBJPROP_XDISTANCE,PanelX(x),g_cache_x[slot]);
   SetInt(name,OBJPROP_YDISTANCE,g_ui_y+y,g_cache_y[slot]);
   if(g_cache_txt[slot]!=txt)
     {
      ObjectSetString(0,name,OBJPROP_TEXT,txt);
      g_cache_txt[slot]=txt;
      g_panel_dirty=true;
     }
   if(g_cache_clr[slot]!=clr)
     {
      ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
      g_cache_clr[slot]=clr;
      g_panel_dirty=true;
     }
  }

void Box(const string id,const int x,const int y,const int w,const int h,const color fill,const color border)
  {
   string name=SGT_PREFIX+id;
   int slot=CacheSlot(name);
   if(g_cache_x[slot]==INT_MIN && ObjectFind(0,name)<0)
     {
      ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,PanelCorner());
      ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
     }
//--- a rectangle label is anchored at its top-left corner, so on the right corner shift it by its width
   SetInt(name,OBJPROP_XDISTANCE,g_ui_corner==SGT_LEFT ? g_ui_x+x : g_ui_x+UI_W-x,g_cache_x[slot]);
   SetInt(name,OBJPROP_YDISTANCE,g_ui_y+y,g_cache_y[slot]);
   SetInt(name,OBJPROP_XSIZE,MathMax(w,1),g_cache_w[slot]);
   SetInt(name,OBJPROP_YSIZE,MathMax(h,1),g_cache_h[slot]);
   if(g_cache_fill[slot]!=fill)
     {
      ObjectSetInteger(0,name,OBJPROP_BGCOLOR,fill);
      g_cache_fill[slot]=fill;
      g_panel_dirty=true;
     }
   if(g_cache_clr[slot]!=border)
     {
      ObjectSetInteger(0,name,OBJPROP_COLOR,border);
      g_cache_clr[slot]=border;
      g_panel_dirty=true;
     }
  }

//--- one "label  value" row; returns the next y
int Row(const string id,const int y,const string label,const string value,const color clr)
  {
   int fit=(UI_W-UI_VAL-UI_PAD)/UI_CHAR;
   Text(id+"_l",UI_PAD,y,label,UiLabel());
   Text(id+"_v",UI_VAL,y,StringLen(value)>fit ? StringSubstr(value,0,fit-1)+"~" : value,clr);
   return(y+UI_ROW);
  }

int Section(const string id,const int y,const string title)
  {
   int top=y+UI_GAP;
   Box(id+"_r",UI_PAD,top+UI_ROW-3,UI_W-2*UI_PAD,1,UiRule(),UiRule());
   Text(id+"_t",UI_PAD,top,title,UiHead(),g_ui_font-1);
   return(top+UI_ROW+2);
  }

void PanelDelete(void)
  {
   ObjectsDeleteAll(0,SGT_PREFIX);
   CacheClear();
  }

//+------------------------------------------------------------------+
//| Formatting                                                       |
//+------------------------------------------------------------------+
string Thousands(const double v,const int digits=2)
  {
   string s=DoubleToString(MathAbs(v),digits);
   int dot=StringFind(s,".");
   string ip=dot>=0 ? StringSubstr(s,0,dot) : s;
   string fp=dot>=0 ? StringSubstr(s,dot) : "";
   string out="";
   int n=StringLen(ip);
   for(int i=0; i<n; i++)
     {
      if(i>0 && (n-i)%3==0)
         out+=",";
      out+=StringSubstr(ip,i,1);
     }
   return((v<0 ? "-" : "")+out+fp);
  }
string SMoney(const double v) { return((v>0 ? "+" : "")+Thousands(v)); }
color  Sign(const double v)   { return(v>0 ? UiPos() : (v<0 ? UiNeg() : UiDim())); }

#endif
//+------------------------------------------------------------------+
