from pathlib import Path

code = r'''//+------------------------------------------------------------------+
//| EA_XAUUSD_M15_Murphy2025.mq5                                     |
//| XAUUSD M15 EA (Murphy-style): Trend + Range Breakout + ATR risk   |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

//========================== Inputs ==========================
input string          InpSymbol               = "XAUUSD";
input ENUM_TIMEFRAMES InpEntryTF              = PERIOD_M15;
input ENUM_TIMEFRAMES InpTrendTF              = PERIOD_H1;

// Trend filter
input int             InpTrendEMAPeriod       = 200;

// Momentum confirm
input bool            InpUseRSI               = true;
input int             InpRSIPeriod            = 14;
input double          InpRSI_BuyMin           = 52.0;
input double          InpRSI_SellMax          = 48.0;

// Volatility (ATR) for SL/TP + trailing
input int             InpATRPeriod            = 14;
input double          InpSL_ATR_Mult          = 2.2;
input double          InpTP_ATR_Mult          = 3.3;
input double          InpTrail_ATR_Mult       = 1.6;

// Range breakout model (acts as S/R)
// IMPORTANT: hours are in BROKER SERVER TIME (TimeCurrent()).
input int             InpRangeStartHour       = 0;
input int             InpRangeEndHour         = 5;
input int             InpTradeStartHour       = 6;
input int             InpTradeEndHour         = 16;
input int             InpBreakoutBufferPoints = 80;

// Execution / risk
input double          InpRiskPercent          = 1.0;
input int             InpMaxSpreadPoints      = 40;
input bool            InpOneTradePerDay       = true;

// Equity guard (server-day)
input bool            InpUseDailyGuards       = true;
input double          InpDailyMaxLossPct      = 3.0;
input double          InpDailyMaxProfitPct    = 4.0;

input bool            InpUseBreakEven         = true;
input double          InpBE_At_R              = 1.0;
input int             InpBE_PlusPoints        = 10;

input ulong           InpMagic                = 25251224;

//========================== Handles ==========================
int hTrendEMA = INVALID_HANDLE;
int hRSI      = INVALID_HANDLE;
int hATR      = INVALID_HANDLE;

//========================== Day State ==========================
int    g_dayOfYear        = -1;
double g_dayEquityStart   = 0.0;

double g_rangeHigh        = -1.0;
double g_rangeLow         = -1.0;
bool   g_rangeLocked      = false;
bool   g_tradedToday      = false;

//========================== Helpers ==========================
string Sym() { return InpSymbol; }

double Point_(const string symbol)
{
   double p = SymbolInfoDouble(symbol, SYMBOL_POINT);
   return (p > 0.0 ? p : 0.0);
}

bool SpreadOK(const string symbol)
{
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double p   = Point_(symbol);
   if(p <= 0.0) return false;
   return ((ask - bid) / p) <= InpMaxSpreadPoints;
}

bool InHourWindow(int hour, int startHour, int endHour)
{
   if(startHour <= endHour)
      return (hour >= startHour && hour <= endHour);
   return (hour >= startHour || hour <= endHour);
}

void ResetDailyState(const MqlDateTime &dt)
{
   g_dayOfYear      = dt.day_of_year;
   g_dayEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   g_rangeHigh      = -1.0;
   g_rangeLow       = -1.0;
   g_rangeLocked    = false;
   g_tradedToday    = false;
}

bool DailyGuardsOK()
{
   if(!InpUseDailyGuards) return true;

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_dayEquityStart <= 0.0) return true;

   double chgPct = 100.0 * (eq - g_dayEquityStart) / g_dayEquityStart;

   if(chgPct <= -InpDailyMaxLossPct) return false;
   if(chgPct >=  InpDailyMaxProfitPct) return false;
   return true;
}

bool GetATR(double &atr)
{
   double a[2];
   ArraySetAsSeries(a, true);
   if(CopyBuffer(hATR, 0, 0, 2, a) < 2) return false;
   atr = a[1];
   return (atr > 0.0);
}

bool GetRSI(double &rsi1, double &rsi2)
{
   if(!InpUseRSI) { rsi1 = 50; rsi2 = 50; return true; }
   double r[3];
   ArraySetAsSeries(r, true);
   if(CopyBuffer(hRSI, 0, 0, 3, r) < 3) return false;
   rsi1 = r[1]; rsi2 = r[2];
   return true;
}

bool TrendAllows(bool isBuy)
{
   double ema[2];
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(hTrendEMA, 0, 0, 2, ema) < 2) return false;

   double closeHTF[2];
   ArraySetAsSeries(closeHTF, true);
   if(CopyClose(Sym(), InpTrendTF, 0, 2, closeHTF) < 2) return false;

   double lastClose = closeHTF[1];
   double emaVal    = ema[1];

   if(isBuy) return (lastClose > emaVal);
   return (lastClose < emaVal);
}

double PointValuePerLot(const string symbol)
{
   double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double p          = Point_(symbol);
   if(tick_size <= 0.0 || p <= 0.0) return 0.0;
   return tick_value * (p / tick_size);
}

double NormalizeLots(const string symbol, double lots)
{
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   lots = MathMax(minLot, MathMin(maxLot, lots));
   double steps = MathFloor(lots / step);
   double out   = steps * step;
   if(out < minLot) out = minLot;
   return out;
}

double LotsByRisk(const string symbol, int sl_points)
{
   if(sl_points <= 0) return 0.0;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (InpRiskPercent / 100.0);

   double pvpl = PointValuePerLot(symbol);
   if(pvpl <= 0.0) return 0.0;

   return NormalizeLots(symbol, riskMoney / (sl_points * pvpl));
}

bool HasEAOpenPosition(const string symbol)
{
   for(int i=0; i<PositionsTotal(); i++)
   {
      if(!PositionSelectByIndex(i)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      return true;
   }
   return false;
}

void ManagePosition()
{
   if(!InpUseBreakEven && InpTrail_ATR_Mult <= 0.0) return;

   string symbol = Sym();
   double p = Point_(symbol);
   if(p <= 0.0) return;

   double atr = 0.0;
   GetATR(atr);

   for(int i=0; i<PositionsTotal(); i++)
   {
      if(!PositionSelectByIndex(i)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);

      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);

      double R = 0.0;
      if(sl > 0.0)
         R = (type == POSITION_TYPE_BUY) ? (openPrice - sl) : (sl - openPrice);

      if(InpUseBreakEven && R > 0.0)
      {
         double profit = (type == POSITION_TYPE_BUY) ? (bid - openPrice) : (openPrice - ask);
         if(profit >= (InpBE_At_R * R))
         {
            double be = openPrice + (type == POSITION_TYPE_BUY ? +InpBE_PlusPoints*p : -InpBE_PlusPoints*p);

            bool improve = false;
            if(type == POSITION_TYPE_BUY) improve = (sl <= 0.0 || be > sl);
            else                          improve = (sl <= 0.0 || be < sl);

            if(improve) trade.PositionModify(symbol, be, tp);
         }
      }

      if(atr > 0.0 && InpTrail_ATR_Mult > 0.0)
      {
         double dist = InpTrail_ATR_Mult * atr;

         if(type == POSITION_TYPE_BUY)
         {
            double newSL = bid - dist;
            if(sl <= 0.0 || newSL > sl + 10*p) trade.PositionModify(symbol, newSL, tp);
         }
         else
         {
            double newSL = ask + dist;
            if(sl <= 0.0 || newSL < sl - 10*p) trade.PositionModify(symbol, newSL, tp);
         }
      }
   }
}

void UpdateRange(const MqlDateTime &dt)
{
   bool inRange = InHourWindow(dt.hour, InpRangeStartHour, InpRangeEndHour);

   if(inRange)
   {
      double h = iHigh(Sym(), InpEntryTF, 0);
      double l = iLow(Sym(),  InpEntryTF, 0);

      if(g_rangeHigh < 0.0 || h > g_rangeHigh) g_rangeHigh = h;
      if(g_rangeLow  < 0.0 || l < g_rangeLow)  g_rangeLow  = l;
   }
   else
   {
      if(!g_rangeLocked && g_rangeHigh > 0.0 && g_rangeLow > 0.0)
         g_rangeLocked = true;
   }
}

bool BreakoutSignal(bool &buy, bool &sell)
{
   buy = false; sell = false;
   if(!g_rangeLocked) return false;

   double p = Point_(Sym());
   if(p <= 0.0) return false;

   double buffer = InpBreakoutBufferPoints * p;

   double close1 = iClose(Sym(), InpEntryTF, 1);
   double high1  = iHigh(Sym(),  InpEntryTF, 1);
   double low1   = iLow(Sym(),   InpEntryTF, 1);

   if(close1 > g_rangeHigh + buffer && (high1 - g_rangeHigh) > buffer) buy = true;
   if(close1 < g_rangeLow  - buffer && (g_rangeLow - low1)  > buffer) sell = true;

   return (buy || sell);
}

//========================== Core ==========================
int OnInit()
{
   trade.SetExpertMagicNumber((int)InpMagic);

   hTrendEMA = iMA(Sym(), InpTrendTF, InpTrendEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hATR      = iATR(Sym(), InpEntryTF, InpATRPeriod);
   if(InpUseRSI) hRSI = iRSI(Sym(), InpEntryTF, InpRSIPeriod, PRICE_CLOSE);

   if(hTrendEMA==INVALID_HANDLE || hATR==INVALID_HANDLE || (InpUseRSI && hRSI==INVALID_HANDLE))
   {
      Print("Init failed: indicator handle invalid.");
      return INIT_FAILED;
   }

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   ResetDailyState(dt);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hTrendEMA!=INVALID_HANDLE) IndicatorRelease(hTrendEMA);
   if(hATR!=INVALID_HANDLE)      IndicatorRelease(hATR);
   if(hRSI!=INVALID_HANDLE)      IndicatorRelease(hRSI);
}

void OnTick()
{
   string symbol = Sym();
   if(symbol == "" || symbol == NULL) return;

   if(!SpreadOK(symbol)) return;

   // Daily reset
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != g_dayOfYear) ResetDailyState(dt);

   if(!DailyGuardsOK()) return;

   ManagePosition();

   if(HasEAOpenPosition(symbol)) return;
   if(InpOneTradePerDay && g_tradedToday) return;

   UpdateRange(dt);

   if(!InHourWindow(dt.hour, InpTradeStartHour, InpTradeEndHour)) return;

   bool buy=false, sell=false;
   if(!BreakoutSignal(buy, sell)) return;

   double rsi1=50, rsi2=50;
   if(!GetRSI(rsi1, rsi2)) return;

   if(buy)
   {
      if(!TrendAllows(true)) return;
      if(InpUseRSI && !(rsi1 >= InpRSI_BuyMin && rsi1 > rsi2)) return;
   }
   if(sell)
   {
      if(!TrendAllows(false)) return;
      if(InpUseRSI && !(rsi1 <= InpRSI_SellMax && rsi1 < rsi2)) return;
   }

   double atr;
   if(!GetATR(atr)) return;

   double p = Point_(symbol);
   double sl_dist = InpSL_ATR_Mult * atr;
   double tp_dist = InpTP_ATR_Mult * atr;

   int sl_points = (int)MathRound(sl_dist / p);
   if(sl_points < 10) return;

   double lots = LotsByRisk(symbol, sl_points);
   if(lots <= 0.0) return;

   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);

   if(buy)
   {
      double sl = ask - sl_dist;
      double tp = ask + tp_dist;
      if(trade.Buy(lots, symbol, ask, sl, tp, "Murphy2025 Breakout Buy"))
         g_tradedToday = true;
   }
   else if(sell)
   {
      double sl = bid + sl_dist;
      double tp = bid - tp_dist;
      if(trade.Sell(lots, symbol, bid, sl, tp, "Murphy2025 Breakout Sell"))
         g_tradedToday = true;
   }
}
//+------------------------------------------------------------------+
'''
path = Path("/mnt/data/EA_XAUUSD_M15_Murphy2025.mq5")
path.write_text(code, encoding="utf-8")
path.as_posix()

