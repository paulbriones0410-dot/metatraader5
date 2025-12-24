//+------------------------------------------------------------------+
//| Trend + Stochastic + ATR EA                                     |
//| Enters in direction of MA trend with stochastic triggers.        |
//| SL/TP calculated from ATR multipliers.                           |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//---- Inputs
input ENUM_TIMEFRAMES InpTimeframe      = PERIOD_M15; // Timeframe for indicators
input int            InpMAPeriod        = 50;          // MA period for trend
input ENUM_MA_METHOD InpMAMethod        = MODE_EMA;    // MA method
input ENUM_APPLIED_PRICE InpMAPrice     = PRICE_CLOSE; // MA applied price

input int            InpKPeriod         = 14;          // Stochastic K period
input int            InpDPeriod         = 3;           // Stochastic D period
input int            InpSlowing         = 3;           // Stochastic slowing
input ENUM_MA_METHOD InpStoMA           = MODE_SMA;    // Stochastic MA method
input ENUM_STO_PRICE InpStoPrice        = STO_LOWHIGH; // Stochastic price field
input double         InpOverbought      = 80.0;        // Overbought level
input double         InpOversold        = 20.0;        // Oversold level

input int            InpATRPeriod       = 14;          // ATR period
input ENUM_TIMEFRAMES InpATRTimeframe   = PERIOD_M15;  // ATR timeframe
input double         InpSLMultiplier    = 1.5;         // ATR multiplier for SL
input double         InpTPMultiplier    = 3.0;         // ATR multiplier for TP

input double         InpLotSize         = 0.10;        // Fixed lot size
input double         InpMaxSpreadPoints = 30;          // Max allowed spread (points)
input ulong          InpMagic           = 26042025;    // Magic number
input bool           InpOnlyOnePosition = true;        // Prevent multiple positions

//---- Globals
int maHandle   = INVALID_HANDLE;
int stoHandle  = INVALID_HANDLE;
int atrHandle  = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Utility functions                                                |
//+------------------------------------------------------------------+
bool SpreadOK()
{
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0) return false;

   double spreadPoints = (ask - bid) / point;
   return (spreadPoints <= InpMaxSpreadPoints);
}

bool HasOpenPosition()
{
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      ulong  mg  = (ulong)PositionGetInteger(POSITION_MAGIC);

      if(sym == _Symbol && mg == InpMagic)
         return true;
   }
   return false;
}

// Determine trend direction using MA on last closed bar
int GetTrend()
{
   double maBuff[];
   ArrayResize(maBuff, 2);
   ArraySetAsSeries(maBuff, true);
   if(CopyBuffer(maHandle, 0, 0, 2, maBuff) < 2)
      return 0; // no data

   double closePrice = iClose(_Symbol, InpTimeframe, 1);
   if(closePrice == 0.0)
      return 0;

   if(closePrice > maBuff[1])
      return 1; // bullish
   if(closePrice < maBuff[1])
      return -1; // bearish
   return 0;
}

bool GetStochasticSignals(bool &buySignal, bool &sellSignal)
{
   buySignal  = false;
   sellSignal = false;

   double mainBuf[], signalBuf[];
   ArrayResize(mainBuf, 3);
   ArrayResize(signalBuf, 3);
   ArraySetAsSeries(mainBuf, true);
   ArraySetAsSeries(signalBuf, true);

   if(CopyBuffer(stoHandle, 0, 0, 3, mainBuf) < 3)
      return false;
   if(CopyBuffer(stoHandle, 1, 0, 3, signalBuf) < 3)
      return false;

   double main1   = mainBuf[1], main2   = mainBuf[2];
   double signal1 = signalBuf[1], signal2 = signalBuf[2];

   // Bullish trigger: main crosses above signal in oversold zone
   if(main2 < signal2 && main1 > signal1 && main1 < InpOversold && signal1 < InpOversold)
      buySignal = true;

   // Bearish trigger: main crosses below signal in overbought zone
   if(main2 > signal2 && main1 < signal1 && main1 > InpOverbought && signal1 > InpOverbought)
      sellSignal = true;

   return true;
}

// Calculate SL/TP prices using ATR multipliers
bool CalcLevels(bool isBuy, double &sl, double &tp)
{
   sl = 0.0; tp = 0.0;

   double atrBuf[];
   ArrayResize(atrBuf, 1);
   if(CopyBuffer(atrHandle, 0, 1, 1, atrBuf) < 1)
      return false; // use last closed ATR

   double atrValue = atrBuf[0];
   double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0 || atrValue <= 0.0)
      return false;

   double slDistance = atrValue * InpSLMultiplier;
   double tpDistance = atrValue * InpTPMultiplier;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(isBuy)
   {
      sl = (InpSLMultiplier > 0.0) ? ask - slDistance : 0.0;
      tp = (InpTPMultiplier > 0.0) ? ask + tpDistance : 0.0;
   }
   else
   {
      sl = (InpSLMultiplier > 0.0) ? bid + slDistance : 0.0;
      tp = (InpTPMultiplier > 0.0) ? bid - tpDistance : 0.0;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber((int)InpMagic);

   maHandle  = iMA(_Symbol, InpTimeframe, InpMAPeriod, 0, InpMAMethod, InpMAPrice);
   stoHandle = iStochastic(_Symbol, InpTimeframe, InpKPeriod, InpDPeriod, InpSlowing,
                           InpStoMA, InpStoPrice);
   atrHandle = iATR(_Symbol, InpATRTimeframe, InpATRPeriod);

   if(maHandle == INVALID_HANDLE || stoHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles.");
      return INIT_FAILED;
   }

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(maHandle  != INVALID_HANDLE) IndicatorRelease(maHandle);
   if(stoHandle != INVALID_HANDLE) IndicatorRelease(stoHandle);
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!SpreadOK())
      return;

   if(InpOnlyOnePosition && HasOpenPosition())
      return;

   static datetime lastSignalBar = 0;
   datetime currentBarTime = iTime(_Symbol, InpTimeframe, 0);
   if(currentBarTime == lastSignalBar)
      return; // ensure only one evaluation per bar

   int trend = GetTrend();
   if(trend == 0)
      return;

   bool stoBuy=false, stoSell=false;
   if(!GetStochasticSignals(stoBuy, stoSell))
      return;

   double sl=0.0, tp=0.0;
   double lotSize = InpLotSize;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(trend > 0 && stoBuy)
   {
      if(!CalcLevels(true, sl, tp))
         return;
      if(trade.Buy(lotSize, _Symbol, ask, sl, tp, "Trend-Sto Buy"))
         lastSignalBar = currentBarTime;
   }
   else if(trend < 0 && stoSell)
   {
      if(!CalcLevels(false, sl, tp))
         return;
      if(trade.Sell(lotSize, _Symbol, bid, sl, tp, "Trend-Sto Sell"))
         lastSignalBar = currentBarTime;
   }
}
//+------------------------------------------------------------------+
