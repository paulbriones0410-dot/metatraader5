//+------------------------------------------------------------------+
//| EA_MA_Cross_Risk.mq5                                             |
//| Simple MA crossover EA with risk-based lot sizing, SL/TP, trail   |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

// ---- Inputs
input ENUM_TIMEFRAMES InpTF              = PERIOD_M15;
input int            InpFastMAPeriod     = 9;
input int            InpSlowMAPeriod     = 21;
input ENUM_MA_METHOD InpMAMethod         = MODE_EMA;
input ENUM_APPLIED_PRICE InpPrice        = PRICE_CLOSE;

input double         InpRiskPercent      = 1.0;   // % balance risk per trade
input int            InpStopLossPoints   = 300;   // points
input int            InpTakeProfitPoints = 600;   // points
input bool           InpUseTrailing      = true;
input int            InpTrailStartPoints = 250;   // start trailing after this profit (points)
input int            InpTrailStepPoints  = 50;    // trailing step (points)

input int            InpMaxSpreadPoints  = 30;    // filter
input ulong          InpMagic            = 20251219;

// ---- Globals
int fastHandle = INVALID_HANDLE;
int slowHandle = INVALID_HANDLE;

double PointValuePerLot()
{
   // Value of 1 point for 1 lot in account currency (approx.)
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(tick_size <= 0.0) return 0.0;
   return tick_value * (point / tick_size);
}

double NormalizeLots(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathMax(minLot, MathMin(maxLot, lots));
   // align to step
   double steps = MathFloor(lots / step);
   double out   = steps * step;

   // in case rounding below min
   if(out < minLot) out = minLot;
   return out;
}

bool SpreadOK()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0) return false;

   double spread_points = (ask - bid) / point;
   return (spread_points <= InpMaxSpreadPoints);
}

bool HasOpenPosition()
{
   for(int i=0; i<PositionsTotal(); i++)
   {
      if(PositionSelectByIndex(i))
      {
         string sym = PositionGetString(POSITION_SYMBOL);
         ulong  mg  = (ulong)PositionGetInteger(POSITION_MAGIC);
         if(sym == _Symbol && mg == InpMagic)
            return true;
      }
   }
   return false;
}

void ApplyTrailing()
{
   if(!InpUseTrailing) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0) return;

   for(int i=0; i<PositionsTotal(); i++)
   {
      if(!PositionSelectByIndex(i)) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      ulong  mg  = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(sym != _Symbol || mg != InpMagic) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(type == POSITION_TYPE_BUY)
      {
         double profitPoints = (bid - openPrice) / point;
         if(profitPoints < InpTrailStartPoints) continue;

         double newSL = bid - (InpTrailStartPoints * point);
         // step filter
         if(sl <= 0.0 || (newSL - sl) >= (InpTrailStepPoints * point))
         {
            trade.PositionModify(_Symbol, newSL, tp);
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profitPoints = (openPrice - ask) / point;
         if(profitPoints < InpTrailStartPoints) continue;

         double newSL = ask + (InpTrailStartPoints * point);
         if(sl <= 0.0 || (sl - newSL) >= (InpTrailStepPoints * point))
         {
            trade.PositionModify(_Symbol, newSL, tp);
         }
      }
   }
}

double CalcLotsByRisk(int sl_points)
{
   if(sl_points <= 0) return 0.0;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (InpRiskPercent / 100.0);

   double pvpl = PointValuePerLot();
   if(pvpl <= 0.0) return 0.0;

   double lots = riskMoney / (sl_points * pvpl);
   return NormalizeLots(lots);
}

bool GetMACrossSignal(bool &buySignal, bool &sellSignal)
{
   buySignal = false;
   sellSignal = false;

   // Need at least 3 bars to compare previous and current closed bar
   double fastBuf[3], slowBuf[3];
   ArraySetAsSeries(fastBuf, true);
   ArraySetAsSeries(slowBuf, true);

   if(CopyBuffer(fastHandle, 0, 0, 3, fastBuf) < 3) return false;
   if(CopyBuffer(slowHandle, 0, 0, 3, slowBuf) < 3) return false;

   // Use closed bars: index 1 (last closed) and 2 (previous closed)
   double fast1 = fastBuf[1], fast2 = fastBuf[2];
   double slow1 = slowBuf[1], slow2 = slowBuf[2];

   if(fast2 <= slow2 && fast1 > slow1) buySignal = true;     // cross up
   if(fast2 >= slow2 && fast1 < slow1) sellSignal = true;    // cross down

   return true;
}

int OnInit()
{
   trade.SetExpertMagicNumber((int)InpMagic);

   fastHandle = iMA(_Symbol, InpTF, InpFastMAPeriod, 0, InpMAMethod, InpPrice);
   slowHandle = iMA(_Symbol, InpTF, InpSlowMAPeriod, 0, InpMAMethod, InpPrice);

   if(fastHandle == INVALID_HANDLE || slowHandle == INVALID_HANDLE)
   {
      Print("Failed to create MA handles.");
      return INIT_FAILED;
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(fastHandle != INVALID_HANDLE) IndicatorRelease(fastHandle);
   if(slowHandle != INVALID_HANDLE) IndicatorRelease(slowHandle);
}

void OnTick()
{
   if(!SpreadOK()) return;

   // trailing for existing position
   ApplyTrailing();

   // Avoid multiple simultaneous positions (simple mode)
   if(HasOpenPosition()) return;

   bool buySignal=false, sellSignal=false;
   if(!GetMACrossSignal(buySignal, sellSignal)) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0) return;

   double lots = CalcLotsByRisk(InpStopLossPoints);
   if(lots <= 0.0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(buySignal)
   {
      double sl = ask - (InpStopLossPoints * point);
      double tp = (InpTakeProfitPoints > 0) ? ask + (InpTakeProfitPoints * point) : 0.0;

      trade.Buy(lots, _Symbol, ask, sl, tp, "MA Cross Buy");
   }
   else if(sellSignal)
   {
      double sl = bid + (InpStopLossPoints * point);
      double tp = (InpTakeProfitPoints > 0) ? bid - (InpTakeProfitPoints * point) : 0.0;

      trade.Sell(lots, _Symbol, bid, sl, tp, "MA Cross Sell");
   }
}
