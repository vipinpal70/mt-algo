//+------------------------------------------------------------------+
//|                                           TradeCartel Plus.mq5   |
//|                                  Copyright 2026, Vipin Pal|
//+------------------------------------------------------------------+
#property copyright "Vipin Pal"
#property link      ""
#property version   "1.00"

// Input Parameters
input double   InpKeyValue           = 2.0;      // UT Bot Key Value
input int      InpAtrPeriod          = 10;       // ATR Period
input double   InpEmaClosePercent    = 0.05;     // EMA Squeeze %
input double   InpBuyMoveMin         = 2.5;      // Min Points for Buy Candle
input int      InpOppositeCooldown   = 30;       // Bars between opposite signals
input int      InpSameCooldown       = 60;       // Bars between same signals
input double   InpDefaultSLPips      = 10.0;     // Fallback SL (Pips)
input double   InpMagic              = 123456;   // Magic Number
input double   InpLotSize            = 0.1;      // Fixed Lot Size

// Global Handles & Variables
int handleATR, handleEMA9, handleEMA15, handleEMA21;
double bufferATR[], bufferEMA9[], bufferEMA15[], bufferEMA21[];
double xATRTrailingStop = 0;
int lastSignalDirection = 0; // 1: Buy, -1: Sell
datetime lastSignalTime = 0;
int lastSignalBarIndex = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   handleATR   = iATR(_Symbol, _Period, InpAtrPeriod);
   handleEMA9  = iMA(_Symbol, _Period, 9, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA15 = iMA(_Symbol, _Period, 15, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA21 = iMA(_Symbol, _Period, 21, 0, MODE_EMA, PRICE_CLOSE);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check for New Bar
   static datetime lastBarTime;
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   // Update Buffers (Index 1 is the most recently closed candle)
   if(!FillBuffers()) return;

   double close1 = iClose(_Symbol, _Period, 1);
   double open1  = iOpen(_Symbol, _Period, 1);
   double atr1   = bufferATR[1];
   
   // --- UT BOT LOGIC ---
   double nLoss = InpKeyValue * atr1;
   double prevStop = xATRTrailingStop;
   double src = close1;
   double srcPrev = iClose(_Symbol, _Period, 2);

   if(src > prevStop && srcPrev > prevStop) xATRTrailingStop = MathMax(prevStop, src - nLoss);
   else if(src < prevStop && srcPrev < prevStop) xATRTrailingStop = MathMin(prevStop, src + nLoss);
   else if(src > prevStop) xATRTrailingStop = src - nLoss;
   else xATRTrailingStop = src + nLoss;

   bool utBuy = (src > xATRTrailingStop);
   bool utSell = (src < xATRTrailingStop);

   // --- EMA SQUEEZE LOGIC ---
   double emaHigh = MathMax(bufferEMA9[1], MathMax(bufferEMA15[1], bufferEMA21[1]));
   double emaLow  = MathMin(bufferEMA9[1], MathMin(bufferEMA15[1], bufferEMA21[1]));
   double emaSpread = emaHigh - emaLow;
   double threshold = close1 * (InpEmaClosePercent / 100.0);
   bool emasAreClose = (emaSpread <= threshold);

   // --- CANDLE MOVE ---
   bool buyCandleMove = (close1 - open1) >= (InpBuyMoveMin * _Point * 10); // Standardized for 5-digit brokers

   // --- COOLDOWN LOGIC ---
   int currentBarIndex = iBars(_Symbol, _Period);
   int barsSince = currentBarIndex - lastSignalBarIndex;
   
   bool canBuy = (lastSignalDirection != 1) ? (barsSince >= InpOppositeCooldown) : (barsSince >= InpSameCooldown);
   bool canSell = (lastSignalDirection != -1) ? (barsSince >= InpOppositeCooldown) : (barsSince >= InpSameCooldown);
   if(lastSignalDirection == 0) { canBuy = true; canSell = true; }

   // --- SIGNAL EXECUTION ---
   if(utBuy && emasAreClose && buyCandleMove && canBuy)
   {
      ExecuteOrder(ORDER_TYPE_BUY);
      lastSignalDirection = 1;
      lastSignalBarIndex = currentBarIndex;
   }
   else if(utSell && emasAreClose && canSell)
   {
      ExecuteOrder(ORDER_TYPE_SELL);
      lastSignalDirection = -1;
      lastSignalBarIndex = currentBarIndex;
   }
   
   ManageTrailingStop();
}

//+------------------------------------------------------------------+
//| Calculate Dynamic SL and TP                                      |
//+------------------------------------------------------------------+
void ExecuteOrder(ENUM_ORDER_TYPE type)
{
   double slPrice, tpPrice, rr;
   double currentPrice = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Find Swing High/Low in last 10 bars
   int swingBar = (type == ORDER_TYPE_BUY) ? iLowest(_Symbol, _Period, MODE_LOW, 10, 1) : iHighest(_Symbol, _Period, MODE_HIGH, 10, 1);
   slPrice = (type == ORDER_TYPE_BUY) ? iLow(_Symbol, _Period, swingBar) : iHigh(_Symbol, _Period, swingBar);

   double slDistancePoints = MathAbs(currentPrice - slPrice);
   double slPips = slDistancePoints / (_Point * 10);

   // Fallback to 10 pips if swing is too tight or not found
   if(slPips < 1.0) {
      slPrice = (type == ORDER_TYPE_BUY) ? currentPrice - (InpDefaultSLPips * _Point * 10) : currentPrice + (InpDefaultSLPips * _Point * 10);
      slPips = InpDefaultSLPips;
      slDistancePoints = InpDefaultSLPips * _Point * 10;
   }

   // Dynamic RR Logic
   if(slPips > 200)      rr = 1.5; // (Safety cap for huge SL)
   else if(slPips > 150) rr = 2.0;
   else if(slPips > 100) rr = 2.5;
   else                  rr = 3.0;

   tpPrice = (type == ORDER_TYPE_BUY) ? currentPrice + (slDistancePoints * rr) : currentPrice - (slDistancePoints * rr);

   // Clean structure initialization to avoid enum errors
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);
   
   request.action   = TRADE_ACTION_DEAL;
   request.symbol   = _Symbol;
   request.volume   = InpLotSize;
   request.type     = type;
   request.price    = currentPrice;
   request.sl       = slPrice;
   request.tp       = tpPrice;
   request.magic    = (long)InpMagic;
   request.type_filling = ORDER_FILLING_IOC;

   // Check return value to resolve the compiler warning
   if(!OrderSend(request, result))
   {
      Print("OrderSend failed. Error code: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Extra Trailing Stop after 1:1 RR                                 |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == InpMagic)
      {
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double curPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
         double sl = PositionGetDouble(POSITION_SL);
         double tp = PositionGetDouble(POSITION_TP);
         
         double risk = MathAbs(openPrice - sl);
         
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         {
            if(curPrice > openPrice + risk && sl < openPrice) 
            {
               MqlTradeRequest req; MqlTradeResult res;
               ZeroMemory(req); ZeroMemory(res);
               
               req.action = TRADE_ACTION_SLTP; 
               req.position = ticket;
               req.sl = openPrice + (_Point * 10); // Move to BE + 1 pip
               req.tp = tp;
               
               if(!OrderSend(req, res))
               {
                  Print("Failed to move SL to BE for Buy. Error: ", GetLastError());
               }
            }
         }
         else // Sell Position
         {
            if(curPrice < openPrice - risk && (sl > openPrice || sl == 0))
            {
               MqlTradeRequest req; MqlTradeResult res;
               ZeroMemory(req); ZeroMemory(res);
               
               req.action = TRADE_ACTION_SLTP; 
               req.position = ticket;
               req.sl = openPrice - (_Point * 10); // Move to BE + 1 pip
               req.tp = tp;
               
               if(!OrderSend(req, res))
               {
                  Print("Failed to move SL to BE for Sell. Error: ", GetLastError());
               }
            }
         }
      }
   }
}

bool FillBuffers()
{
   if(CopyBuffer(handleATR, 0, 0, 3, bufferATR) < 0) return false;
   if(CopyBuffer(handleEMA9, 0, 0, 3, bufferEMA9) < 0) return false;
   if(CopyBuffer(handleEMA15, 0, 0, 3, bufferEMA15) < 0) return false;
   if(CopyBuffer(handleEMA21, 0, 0, 3, bufferEMA21) < 0) return false;
   ArraySetAsSeries(bufferATR, true);
   ArraySetAsSeries(bufferEMA9, true);
   ArraySetAsSeries(bufferEMA15, true);
   ArraySetAsSeries(bufferEMA21, true);
   return true;
}