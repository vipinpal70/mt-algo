//+------------------------------------------------------------------+
//|                                                      mtf_new.mq5 |
//|                                         Copyright 2026, Vipin Pal|
//+------------------------------------------------------------------+
#property copyright "Vipin Pal"
#property link      ""
#property version   "1.01"

#include <Trade\Trade.mqh>

//--- Inputs
input int    InpEmaFast         = 9;
input int    InpEmaSlow         = 21;
input int    InpPP              = 5;
input int    InpCooldown        = 30;
input int    InpMinTouches      = 3;
input bool   InpUseAtr          = true;
input int    InpAtrLen          = 14;
input double InpAtrMult         = 0.15;
input double InpPctTol          = 0.10;
input bool   InpCountWick       = true;
input bool   InpCountClose      = true;
input bool   InpImmediateSignal = false;
input double InpStrongCandlePct = 0.60;
input double InpLotSize         = 0.1;
input ulong  InpMagicNumber     = 7060;

//--- SL / TP (in pips)
input int    InpSlPips          = 35;   // Stop Loss  : 35 pips = 3.5 $
input int    InpTpPips          = 85;   // Take Profit: 85 pips = 8.5 $ (≈ 2.43 RR)

//--- Debug verbosity
input bool   InpDebugPivot      = true;  // Print pivot search results
input bool   InpDebugBreakout   = true;  // Print breakout / touch details
input bool   InpDebugSignal     = true;  // Print signal & cooldown state

//--- Globals
int    g_hEmaFast = INVALID_HANDLE;
int    g_hEmaSlow = INVALID_HANDLE;
int    g_hAtr     = INVALID_HANDLE;
double g_EmaFast[];
double g_EmaSlow[];
double g_Atr[];
CTrade g_trade;
int    g_lastBuyBar  = -999;
int    g_lastSellBar = -999;
int    g_barCount    = 0;
double g_PipSize     = 0.0;   // one pip in price terms

//+------------------------------------------------------------------+
//| Pip helpers                                                        |
//+------------------------------------------------------------------+
double PipsToPrice(int pips)
{
   return pips * g_PipSize;
}

//+------------------------------------------------------------------+
int OnInit()
{
   //--- Determine pip size (handles 4/5-digit & JPY pairs)
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_PipSize  = (digits == 3 || digits == 5) ? _Point * 10.0 : _Point;

   Print("=== EA INIT === Symbol=", _Symbol,
         "  Digits=", digits,
         "  PipSize=", DoubleToString(g_PipSize, digits),
         "  SL=", InpSlPips, " pips (", DoubleToString(PipsToPrice(InpSlPips), digits), ")",
         "  TP=", InpTpPips, " pips (", DoubleToString(PipsToPrice(InpTpPips), digits), ")");

   g_trade.SetExpertMagicNumber(InpMagicNumber);

   g_hEmaFast = iMA(_Symbol, PERIOD_CURRENT, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaSlow = iMA(_Symbol, PERIOD_CURRENT, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hAtr     = iATR(_Symbol, PERIOD_CURRENT, InpAtrLen);

   if(g_hEmaFast == INVALID_HANDLE ||
      g_hEmaSlow == INVALID_HANDLE ||
      g_hAtr     == INVALID_HANDLE)
   {
      Print("ERROR: Indicator init failed. EmaFast=", g_hEmaFast,
            " EmaSlow=", g_hEmaSlow, " ATR=", g_hAtr);
      return INIT_FAILED;
   }

   ArraySetAsSeries(g_EmaFast, true);
   ArraySetAsSeries(g_EmaSlow, true);
   ArraySetAsSeries(g_Atr,     true);

   Print("=== EA INIT SUCCEEDED ===");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("=== EA DEINIT === Reason=", reason);
   IndicatorRelease(g_hEmaFast);
   IndicatorRelease(g_hEmaSlow);
   IndicatorRelease(g_hAtr);
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime s_lastTime = 0;
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t != s_lastTime)
   {
      s_lastTime = t;
      g_barCount++;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsNewBar()) return;

   //--- Copy indicator buffers
   if(CopyBuffer(g_hEmaFast, 0, 1, 3, g_EmaFast) < 3) { Print("WARN: EmaFast buffer copy failed"); return; }
   if(CopyBuffer(g_hEmaSlow, 0, 1, 3, g_EmaSlow) < 3) { Print("WARN: EmaSlow buffer copy failed"); return; }
   if(CopyBuffer(g_hAtr,     0, 1, 3, g_Atr)     < 3) { Print("WARN: ATR buffer copy failed");    return; }

   //--- Session filter: IST 07:00–23:59 → UTC+5:30 offset applied server-side
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int mins = dt.hour * 60 + dt.min;
   if(mins < 420)
   {
      if(InpDebugSignal)
         Print("[Bar ", g_barCount, "] SESSION BLOCKED — current UTC mins=", mins, " (need ≥420 / 07:00 IST)");
      return;
   }

   //--- EMA state
   bool emaBull = g_EmaFast[0] > g_EmaSlow[0];
   bool emaBear = g_EmaFast[0] < g_EmaSlow[0];

   if(InpDebugSignal)
      Print("[Bar ", g_barCount, "] EMA: fast=", DoubleToString(g_EmaFast[0], _Digits),
            "  slow=", DoubleToString(g_EmaSlow[0], _Digits),
            "  Bull=", emaBull, "  Bear=", emaBear,
            "  ATR=",  DoubleToString(g_Atr[0], _Digits));

   //--- Bar 1 (last closed bar)
   double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double o1 = iOpen (_Symbol, PERIOD_CURRENT, 1);
   double h1 = iHigh (_Symbol, PERIOD_CURRENT, 1);
   double l1 = iLow  (_Symbol, PERIOD_CURRENT, 1);

   double range = h1 - l1;
   double body  = MathAbs(c1 - o1);
   double bodyPct = (range > 0) ? body / range : 0.0;
   bool   strong     = (range > 0) && (bodyPct >= InpStrongCandlePct);
   bool   bullStrong = strong && c1 > o1;
   bool   bearStrong = strong && c1 < o1;

   if(InpDebugSignal)
      Print("[Bar ", g_barCount, "] Bar1: O=", DoubleToString(o1, _Digits),
            "  H=", DoubleToString(h1, _Digits),
            "  L=", DoubleToString(l1, _Digits),
            "  C=", DoubleToString(c1, _Digits),
            "  BodyPct=", DoubleToString(bodyPct * 100.0, 1), "%",
            "  Strong=", strong,
            "  BullStrong=", bullStrong, "  BearStrong=", bearStrong);

   //--- Tolerance
   double tol = InpUseAtr ? g_Atr[0] * InpAtrMult : c1 * InpPctTol / 100.0;

   if(InpDebugBreakout)
      Print("[Bar ", g_barCount, "] Tolerance=", DoubleToString(tol, _Digits),
            "  (UseATR=", InpUseAtr, ")");

   //--- Breakout checks
   bool bullBreak = CheckBreakout("Down", tol, c1, h1, l1);
   bool bearBreak = CheckBreakout("Up",   tol, c1, h1, l1);

   //--- Raw signals
   bool buyRaw  = InpImmediateSignal ? bullBreak : (bullBreak && bullStrong && emaBull);
   bool sellRaw = InpImmediateSignal ? bearBreak : (bearBreak && bearStrong && emaBear);

   //--- Cooldown
   int barsSinceLastBuy  = g_barCount - g_lastBuyBar;
   int barsSinceLastSell = g_barCount - g_lastSellBar;

   if(InpDebugSignal)
      Print("[Bar ", g_barCount, "] BullBreak=", bullBreak, "  BearBreak=", bearBreak,
            "  BuyRaw=",  buyRaw,  "  SellRaw=", sellRaw,
            "  BarsSinceBuy=",  barsSinceLastBuy,
            "  BarsSinceSell=", barsSinceLastSell,
            "  Cooldown=", InpCooldown);

   bool buySig  = buyRaw  && (barsSinceLastBuy  > InpCooldown);
   bool sellSig = sellRaw && (barsSinceLastSell > InpCooldown);

   //--- Execute BUY
   if(buySig)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = NormalizeDouble(ask - PipsToPrice(InpSlPips), _Digits);
      double tp  = NormalizeDouble(ask + PipsToPrice(InpTpPips), _Digits);

      Print("[Bar ", g_barCount, "] >>> BUY SIGNAL <<<",
            "  Ask=", DoubleToString(ask, _Digits),
            "  SL=",  DoubleToString(sl,  _Digits), " (", InpSlPips, " pips)",
            "  TP=",  DoubleToString(tp,  _Digits), " (", InpTpPips, " pips)",
            "  Lot=", InpLotSize);

      bool ok = g_trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "MTF_BUY");
      if(ok)
      {
         Print("[Bar ", g_barCount, "] BUY order sent. Ticket=", g_trade.ResultOrder(),
               "  RetCode=", g_trade.ResultRetcode(),
               "  RetMsg=",  g_trade.ResultRetcodeDescription());
      }
      else
      {
         Print("[Bar ", g_barCount, "] BUY FAILED. RetCode=", g_trade.ResultRetcode(),
               "  RetMsg=", g_trade.ResultRetcodeDescription());
      }

      g_lastBuyBar  = g_barCount;
      g_lastSellBar = g_barCount;
   }

   //--- Execute SELL
   if(sellSig)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + PipsToPrice(InpSlPips), _Digits);
      double tp  = NormalizeDouble(bid - PipsToPrice(InpTpPips), _Digits);

      Print("[Bar ", g_barCount, "] >>> SELL SIGNAL <<<",
            "  Bid=", DoubleToString(bid, _Digits),
            "  SL=",  DoubleToString(sl,  _Digits), " (", InpSlPips, " pips)",
            "  TP=",  DoubleToString(tp,  _Digits), " (", InpTpPips, " pips)",
            "  Lot=", InpLotSize);

      bool ok = g_trade.Sell(InpLotSize, _Symbol, bid, sl, tp, "MTF_SELL");
      if(ok)
      {
         Print("[Bar ", g_barCount, "] SELL order sent. Ticket=", g_trade.ResultOrder(),
               "  RetCode=", g_trade.ResultRetcode(),
               "  RetMsg=",  g_trade.ResultRetcodeDescription());
      }
      else
      {
         Print("[Bar ", g_barCount, "] SELL FAILED. RetCode=", g_trade.ResultRetcode(),
               "  RetMsg=", g_trade.ResultRetcodeDescription());
      }

      g_lastSellBar = g_barCount;
      g_lastBuyBar  = g_barCount;
   }
}

//+------------------------------------------------------------------+
//| FindPivot                                                          |
//|  type     : "H" (pivot high) or "L" (pivot low)                   |
//|  instance : 1 = most recent pivot, 2 = one before that, etc.      |
//+------------------------------------------------------------------+
int FindPivot(const string type, const int instance)
{
   int found = 0;
   for(int i = InpPP + 1; i < 1000; i++)
   {
      bool ok = true;
      if(type == "H")
      {
         double ch = iHigh(_Symbol, PERIOD_CURRENT, i);
         for(int j = 1; j <= InpPP && ok; j++)
            if(iHigh(_Symbol, PERIOD_CURRENT, i-j) > ch ||
               iHigh(_Symbol, PERIOD_CURRENT, i+j) >= ch) ok = false;
      }
      else
      {
         double cl = iLow(_Symbol, PERIOD_CURRENT, i);
         for(int j = 1; j <= InpPP && ok; j++)
            if(iLow(_Symbol, PERIOD_CURRENT, i-j) < cl ||
               iLow(_Symbol, PERIOD_CURRENT, i+j) <= cl) ok = false;
      }
      if(ok)
      {
         found++;
         if(InpDebugPivot)
            Print("[FindPivot] type=", type, "  instance=", instance,
                  "  found#", found, " at bar=", i,
                  "  price=", DoubleToString(
                     type == "H" ? iHigh(_Symbol, PERIOD_CURRENT, i)
                                 : iLow (_Symbol, PERIOD_CURRENT, i), _Digits));
         if(found == instance) return i;
         i += InpPP;
      }
   }
   if(InpDebugPivot)
      Print("[FindPivot] type=", type, "  instance=", instance, " — NOT FOUND");
   return -1;
}

//+------------------------------------------------------------------+
//| CheckBreakout                                                      |
//|  type  : "Up"   → ascending trendline on pivot Lows  (bull break) |
//|         "Down" → descending trendline on pivot Highs (bear break) |
//+------------------------------------------------------------------+
bool CheckBreakout(const string type, const double tol,
                   const double cp, const double hp, const double lp)
{
   string pt = (type == "Up") ? "L" : "H";
   int p1 = FindPivot(pt, 1);
   int p2 = FindPivot(pt, 2);

   if(p1 < 0 || p2 < 0)
   {
      if(InpDebugBreakout)
         Print("[CheckBreakout-", type, "] SKIP — pivot(s) not found. p1=", p1, "  p2=", p2);
      return false;
   }

   double pr1 = (type=="Up") ? iLow (_Symbol, PERIOD_CURRENT, p1)
                              : iHigh(_Symbol, PERIOD_CURRENT, p1);
   double pr2 = (type=="Up") ? iLow (_Symbol, PERIOD_CURRENT, p2)
                              : iHigh(_Symbol, PERIOD_CURRENT, p2);

   //--- Reject stale trendlines (older than 3 hours)
   datetime p2Time  = iTime(_Symbol, PERIOD_CURRENT, p2);
   long     age     = (long)(TimeCurrent() - p2Time);
   if(age > 10800)
   {
      if(InpDebugBreakout)
         Print("[CheckBreakout-", type, "] SKIP — p2 too old. Age=", age, "s (limit 10800s)");
      return false;
   }

   //--- Trendline slope: price = pr2 + m*(bar_index_from_p2)
   //    bar indices: p2 > p1 (p2 is older). slope in bars-from-p1 space.
   double dx      = (double)(p2 - p1);          // always > 0
   double m       = (pr1 - pr2) / dx;           // positive = ascending (bull), negative = descending (bear)
   double lineNow = pr1 - m * (double)p1;       // projected to bar 0

   if(InpDebugBreakout)
      Print("[CheckBreakout-", type, "]",
            "  p1=", p1, " (", DoubleToString(pr1, _Digits), ")",
            "  p2=", p2, " (", DoubleToString(pr2, _Digits), ")",
            "  slope=", DoubleToString(m, _Digits),
            "  lineNow=", DoubleToString(lineNow, _Digits),
            "  cp=", DoubleToString(cp, _Digits),
            "  ageP2=", age, "s");

   //--- Touch counting between p2 and p1
   int touches = 2;  // p1 and p2 themselves
   for(int i = p1+1; i < p2; i++)
   {
      double hl  = pr1 + m * (double)(i - p1);   // trendline level at bar i
      double ub  = hl + tol;
      double db  = hl - tol;
      double ih  = iHigh (_Symbol, PERIOD_CURRENT, i);
      double il  = iLow  (_Symbol, PERIOD_CURRENT, i);
      double ic  = iClose(_Symbol, PERIOD_CURRENT, i);
      bool hit = false;

      if(type == "Up")
         hit = (InpCountWick  && il >= db && il <= ub && ic > hl) ||
               (InpCountClose && MathAbs(ic - hl) <= tol && ic > hl);
      else
         hit = (InpCountWick  && ih >= db && ih <= ub && ic < hl) ||
               (InpCountClose && MathAbs(ic - hl) <= tol && ic < hl);

      if(hit)
      {
         touches++;
         if(InpDebugBreakout)
            Print("[CheckBreakout-", type, "] Touch #", touches,
                  " at bar=", i,
                  "  trendLine=", DoubleToString(hl, _Digits),
                  "  High=", DoubleToString(ih, _Digits),
                  "  Low=",  DoubleToString(il, _Digits),
                  "  Close=", DoubleToString(ic, _Digits));
      }
   }

   if(InpDebugBreakout)
      Print("[CheckBreakout-", type, "] Total touches=", touches,
            "  MinRequired=", InpMinTouches);

   if(touches < InpMinTouches) return false;

   //--- Breakout confirmation
   bool broken = false;
   if(type == "Up"   && cp < lineNow) broken = true;
   if(type == "Down" && cp > lineNow) broken = true;

   if(InpDebugBreakout)
      Print("[CheckBreakout-", type, "] Breakout=", broken,
            "  cp=", DoubleToString(cp, _Digits),
            "  lineNow=", DoubleToString(lineNow, _Digits));

   return broken;
}