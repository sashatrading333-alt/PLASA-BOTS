//+------------------------------------------------------------------+
//| PLASA H1 Wick Balance EA v5.07                                    |
//| Groups of five CLOSED H1 candles; no overlapping groups.         |
//| DEMO/Strategy Tester research EA.                                 |
//+------------------------------------------------------------------+
#property strict
#property version   "5.07"
#property description "H1 5-candle upper/lower wick balance EA - demo/test only"
#include <Trade/Trade.mqh>

input double InpLots                   = 0.01;    // Base position lot
input double InpMaxLotsPerPosition     = 0.05;    // Strict lot ceiling per order
input int    InpMaxOrdersPerSignal     = 2;       // At most two orders per five-H1 decision
input bool   InpM15BonusEnabled       = true;    // M15 is a size bonus, NEVER mandatory for entry
input double InpPipSize                = 0.10;    // XAUUSD pip: 0.10 price units
input double InpMinimumDifferencePips  = 20.0;    // Minimum absolute sum difference
input int    InpMaximumPositions       = 10;      // Safety: maximum open EA positions
input bool   InpDemoOnly               = true;    // Reject live accounts by default
input bool   InpEnableTrading          = true;    // Allow trades on demo/tester
input int    InpMaxSpreadPips          = 35;      // Filter only at new entry
input ulong  InpMagic                  = 26051210;
input double InpMaxNewSignalRiskUSD    = 80.0;    // Sum of initial risk for new batch
input double InpMaxTotalOpenRiskUSD   = 150.0;   // Combined remaining SL downside
input double InpATRStopMultiplier      = 1.2;     // Initial SL at H1 ATR multiple
input int    InpATRPeriod              = 14;
input double InpBasketLockStartUSD     = 60.0;   // Activate early basket protection
input double InpBasketRetainPercent    = 70.0;    // Protect 65% of best basket profit
input double InpBasketMinLockedUSD     = 25.0;    // Minimum basket floor at activation
input int    InpDeviationPoints        = 30;
input int    InpKeepChartGroups        = 12;
input bool   InpShowPanel              = true;
input double InpProfitTriggerUSD       = 200.0;   // First ladder activation at +$200
input double InpProfitFloorUSD         = 160.0;   // First protected floor +$160
input double InpProfitStepUSD          = 50.0;    // Every additional +$50 raises floor by +$50
input double InpPostLockMaxRiskUSD     = 40.0;    // Max projected risk on a new position
input double InpRiskReserveUSD         = 2.0;     // Reserve for spread/commission/slippage (not a guarantee)
input int    InpPanelRefreshSeconds    = 5;       // Panel refresh on live chart

CTrade trade;
int g_atrHandle=INVALID_HANDLE;
double g_basketPeak=0.0;
string g_signalStrength="WAIT";
int g_lastTier=0;
int g_lastOrders=0;
double g_lastOrderLot=0.0;
int g_signalScore=0;
string g_prefix;
datetime g_lastH1Open=0;
int g_count=0;
double g_upper=0.0;
double g_lower=0.0;
int g_red=0,g_green=0,g_doji=0;
double g_redWicks=0.0,g_greenWicks=0.0;
int g_lastRed=0,g_lastGreen=0;
double g_lastRedWicks=0,g_lastGreenWicks=0;
int g_groupSerial=0;
int g_lastDirection=0;
double g_lastUpper=0,g_lastLower=0,g_lastDelta=0;
double g_closeSum=0.0,g_lastClose=0.0;
string g_priceConfirm="WAIT";
string g_lastAction="Starting / waiting for first closed H1";
string g_lastReason="";
bool g_profitLocked=false;
bool g_lockNeedsFlatten=false;
double g_ladderPeak=0.0;
double g_ladderFloor=0.0;
double g_nextStep=200.0;
double g_todayRealized=0.0;
bool g_historyDirty=true;
int g_dayId=0;
datetime g_lastPanelRefresh=0;
string g_riskAction="Waiting for +$200";

bool IsOwnedPosition(const ulong ticket);
int OwnedCount(int &buys,int &sells);
double BasketFloating();
bool CloseOwned(const string why);
int DayId(const datetime t)
{
   MqlDateTime dt; TimeToStruct(t,dt);
   return dt.year*10000+dt.mon*100+dt.day;
}
datetime DayStart(const datetime t)
{
   MqlDateTime dt; TimeToStruct(t,dt);dt.hour=0;dt.min=0;dt.sec=0;
   return StructToTime(dt);
}
string LockKey()
{
   return StringFormat("PLASA504_%I64d_%I64u_%s_%d",
       AccountInfoInteger(ACCOUNT_LOGIN),InpMagic,_Symbol,g_dayId);
}
string LadderKey() { return LockKey()+"_RUNG"; }
void ResetDay()
{
   int id=DayId(TimeCurrent());
   if(id==g_dayId) return;
   g_dayId=id;
   g_profitLocked=(GlobalVariableCheck(LockKey()) && GlobalVariableGet(LockKey())>0.5);
   int rung=0;
   if(GlobalVariableCheck(LadderKey()))rung=(int)GlobalVariableGet(LadderKey());
   if(!g_profitLocked)rung=0;
   g_ladderFloor=g_profitLocked?InpProfitFloorUSD+rung*InpProfitStepUSD:0.0;
   g_nextStep=InpProfitTriggerUSD+(g_profitLocked?rung+1:0)*InpProfitStepUSD;
   g_ladderPeak=0.0;
   g_lockNeedsFlatten=false;
   g_historyDirty=true;
   g_riskAction=g_profitLocked?"Profit ladder restored":"Waiting for first rung";
}
void RefreshRealized()
{
   if(!g_historyDirty) return;
   if(!HistorySelect(DayStart(TimeCurrent()),TimeCurrent()))return;
   double pnl=0.0;
   for(int i=0;i<HistoryDealsTotal();i++)
   {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0 || HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol ||
         (ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagic)continue;
      pnl+=HistoryDealGetDouble(deal,DEAL_PROFIT)
          +HistoryDealGetDouble(deal,DEAL_SWAP)
          +HistoryDealGetDouble(deal,DEAL_COMMISSION)
          +HistoryDealGetDouble(deal,DEAL_FEE);
   }
   g_todayRealized=pnl;
   g_historyDirty=false;
}
double DayResult()
{
   RefreshRealized();
   return g_todayRealized+BasketFloating();
}
// Project the net result if every protected position is stopped.
// With no SL, projected risk is unlimited and a new order must not be added.
bool WorstCaseAtStops(double &projected)
{
   RefreshRealized();
   projected=g_todayRealized;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOwnedPosition(ticket))continue;
      double sl=PositionGetDouble(POSITION_SL);
      if(sl<=0.0)return false;
      ENUM_ORDER_TYPE type=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
      double pl=0.0;
      if(!OrderCalcProfit(type,_Symbol,PositionGetDouble(POSITION_VOLUME),
                         PositionGetDouble(POSITION_PRICE_OPEN),sl,pl))return false;
      projected+=pl+PositionGetDouble(POSITION_SWAP);
   }
   return true;
}
// Choose an SL to cap the expected loss of one NEW trade.
// Uses a monetary-risk search rather than assuming a fixed gold contract size.
bool CalculateMoneySL(const int side,const double maxRisk,const double volume,const MqlTick &tick,double &sl)
{
   if(maxRisk<=0.0)return false;
   double entry=side>0?tick.ask:tick.bid;
   double minStop=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0)tickSize=_Point;
   // Need to include spread and at least the minimum broker stop distance.
   double minDist=MathMax(minStop+2*tickSize,2*tickSize);
   double minSL=side>0?tick.bid-minDist:tick.ask+minDist;
   ENUM_ORDER_TYPE typ=side>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double minPL=0.0;
   if(!OrderCalcProfit(typ,_Symbol,volume,entry,minSL,minPL) || -minPL>maxRisk)return false;
   double nearDist=MathAbs(entry-minSL),low=nearDist,high=MathMax(nearDist*2.0,_Point*100);
   for(int j=0;j<24;j++)
   {
      double p=0.0,probe=entry+(side>0?-high:high);
      if(!OrderCalcProfit(typ,_Symbol,volume,entry,probe,p))return false;
      if(-p>=maxRisk)break;
      high*=2.0;
   }
   for(int j=0;j<35;j++)
   {
      double mid=(low+high)/2.0;
      double p=0.0,probe=entry+(side>0?-mid:mid);
      if(!OrderCalcProfit(typ,_Symbol,InpLots,entry,probe,p))return false;
      if(-p>maxRisk)high=mid;else low=mid;
   }
   // Round to the safer side (closer to entry), then validate once more.
   double raw=entry+(side>0?-low:low);
   sl=NormalizeDouble((side>0?MathCeil(raw/tickSize):MathFloor(raw/tickSize))*tickSize,_Digits);
   double check=0.0;
   if((side>0 && sl>=tick.bid-minStop)||(side<0 && sl<=tick.ask+minStop))return false;
   if(!OrderCalcProfit(typ,_Symbol,volume,entry,sl,check))return false;
   return -check<=maxRisk+0.01;
}
void CheckProfitLock()
{
   ResetDay();
   double now=DayResult();
   g_ladderPeak=MathMax(g_ladderPeak,now);
   // Each confirmed rung is permanent for this broker day, including restart.
   if(now>=g_nextStep)
   {
      int rung=(int)MathFloor((now-InpProfitTriggerUSD+0.0000001)/InpProfitStepUSD);
      if(rung<0)rung=0;
      int previous=g_profitLocked?(int)MathRound((g_ladderFloor-InpProfitFloorUSD)/InpProfitStepUSD):-1;
      if(rung>previous)
      {
         g_profitLocked=true;
         g_ladderFloor=InpProfitFloorUSD+rung*InpProfitStepUSD;
         g_nextStep=InpProfitTriggerUSD+(rung+1)*InpProfitStepUSD;
         g_lockNeedsFlatten=true;
         GlobalVariableSet(LockKey(),1.0);
         GlobalVariableSet(LadderKey(),(double)rung);
         g_riskAction=StringFormat("RUNG %d: floor $%.0f; banking basket",rung,g_ladderFloor);
         Print("PLASA PROFIT LADDER: ",g_riskAction);
      }
   }
   if(!g_profitLocked)return;
   int buys,sells;
   int total=OwnedCount(buys,sells);
   double atStops=0.0;
   bool allProtected=WorstCaseAtStops(atStops);
   // Bank exposure at every newly reached rung. Also flatten on floor danger.
   if(total>0 && (g_lockNeedsFlatten || !allProtected ||
                  atStops<g_ladderFloor+InpRiskReserveUSD ||
                  now<=g_ladderFloor+InpRiskReserveUSD))
   {
      bool closed=CloseOwned("profit ladder: bank rung / guard floor");
      g_lockNeedsFlatten=!closed;
      g_historyDirty=true;
      RefreshRealized();
      g_riskAction=closed?"Basket banked; ladder continues":"CLOSE FAILED: retrying";
   }
   else if(total==0)g_lockNeedsFlatten=false;
}


bool IsOwnedPosition(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return false;
   return PositionGetString(POSITION_SYMBOL)==_Symbol &&
          (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic;
}
int OwnedCount(int &buys,int &sells)
{
   buys=0;sells=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOwnedPosition(ticket)) continue;
      if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) buys++;
      else sells++;
   }
   return buys+sells;
}
double BasketFloating()
{
   double p=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOwnedPosition(ticket)) continue;
      p+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   }
   return p;
}
bool TradeSucceeded()
{
   uint r=trade.ResultRetcode();
   return r==TRADE_RETCODE_DONE || r==TRADE_RETCODE_DONE_PARTIAL;
}
// Close all EA positions only; never close manual or other EAs' positions.
bool CloseOwned(const string why)
{
   bool allClosed=true;
   for(int pass=0;pass<3;pass++)
   {
      bool any=false;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong ticket=PositionGetTicket(i);
         if(!IsOwnedPosition(ticket)) continue;
         any=true;
         if(!trade.PositionClose(ticket) || !TradeSucceeded())
         {
            allClosed=false;
            PrintFormat("PLASA CLOSE FAIL ticket=%I64u retcode=%u %s",ticket,
                        trade.ResultRetcode(),trade.ResultRetcodeDescription());
         }
      }
      if(!any) break;
   }
   int buys,sells;
   if(OwnedCount(buys,sells)!=0) allClosed=false;
   if(allClosed) g_lastAction="CLOSED positions: "+why;
   g_historyDirty=true;
   return allClosed;
}
bool VolumeValid()
{
   double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   return InpLots>=vmin-0.0000001 && InpLots<=vmax+0.0000001 &&
          step>0 && MathAbs(InpLots/step-MathRound(InpLots/step))<0.00001;
}
// Risk and size are calculated from the broker contract data and stop distance.
// Every position receives a protective SL even BEFORE the first daily ladder rung.
bool InitialStop(const int side,const MqlTick &tick,double &sl)
{
   double atrBuf[]; ArraySetAsSeries(atrBuf,true);
   if(g_atrHandle==INVALID_HANDLE || CopyBuffer(g_atrHandle,0,1,1,atrBuf)!=1)return false;
   double atr=atrBuf[0];
   if(atr<=0.0)return false;
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(ts<=0.0)ts=_Point;
   double brokerMin=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   double freeze=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)*_Point;
   double distance=MathMax(atr*InpATRStopMultiplier,MathMax(brokerMin,freeze)+3.0*ts);
   double raw=side>0?tick.bid-distance:tick.ask+distance;
   sl=NormalizeDouble((side>0?MathFloor(raw/ts):MathCeil(raw/ts))*ts,_Digits);
   return side>0?sl<tick.bid-brokerMin:sl>tick.ask+brokerMin;
}
bool VolumeForBroker(const double v)
{
   double lo=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double hi=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   return st>0 && v>=lo-1e-8 && v<=hi+1e-8 &&
          MathAbs(v/st-MathRound(v/st))<1e-5;
}
double NormalizedVolumeDown(const double desired)
{
   double minVol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxVol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0.0)return 0.0;
   double v=MathFloor(MathMin(desired,maxVol)/step+1e-7)*step;
   v=NormalizeDouble(v,8);
   return v>=minVol-1e-8?v:0.0;
}
// Strength is ONLY used for position sizing, not for filtering valid 5-H1 signals.
// Existing entry tests remain unchanged; M15 adds only a size bonus.
int SignalTier(const int side)
{
   const int majority=side>0?g_green:g_red;
   const double own=side>0?g_greenWicks:g_redWicks;
   const double other=side>0?g_redWicks:g_greenWicks;
   const double difference=MathAbs(g_lastDelta);
   int tier=1;
   if(majority>=4 && own>=other*1.25 && difference>=35.0) tier=2;
   if(majority>=4 && own>=other*1.50 && difference>=60.0) tier=3;
   if(majority==5 && own>=other*1.8 && difference>=90.0) tier=4;
   if(InpM15BonusEnabled && tier<4)
   {
      MqlRates m15[];ArraySetAsSeries(m15,true);
      if(CopyRates(_Symbol,PERIOD_M15,1,1,m15)==1)
      {
         bool aligned=(side>0?m15[0].close>m15[0].open:m15[0].close<m15[0].open);
         if(aligned && tier>=2)tier++;
      }
   }
   return tier;
}
// Respects available post-ladder loss buffer and the maximum initial risk on a signal.
bool OpenSide(const int side,const string why)
{
   if(g_lockNeedsFlatten) {g_lastAction="WAIT: closing basket for ladder";return false;}
   if(!InpEnableTrading) {g_lastAction="ORDER BLOCKED: trading disabled";return false;}
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
   {g_lastAction="ORDER BLOCKED: Algo Trading disabled";return false;}
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))return false;
   if((tick.ask-tick.bid)/InpPipSize>InpMaxSpreadPips)
   {g_lastAction="ORDER BLOCKED: spread too wide";return false;}
   int buys,sells;
   int already=OwnedCount(buys,sells);
   if(already>=InpMaximumPositions)
   {g_lastAction="ORDER BLOCKED: max open positions";return false;}
   // Stronger 5-H1 balance increases desired exposure, within dollar-risk caps.
   // T1: 1x0.01; T2: 1x0.02; T3: 2x0.02; T4: 2x0.05.
   int tier=SignalTier(side);
   int count=(tier>=3?2:1);
   count=MathMin(count,InpMaxOrdersPerSignal);
   const double requested=(tier==1?InpLots:tier==2?0.02:tier==3?0.02:0.05);
   const double desiredLot=MathMin(InpMaxLotsPerPosition,requested);
   g_lastTier=tier;
   g_lastOrders=count;
   g_lastOrderLot=desiredLot;
   g_signalScore=tier;
   g_signalStrength=StringFormat("T%d %dx%.2f",tier,count,desiredLot);
   double sl=0.0;
   if(!InitialStop(side,tick,sl))
   {g_lastAction="WAIT: cannot calculate H1 ATR stop";return false;}
   ENUM_ORDER_TYPE typ=side>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double price=side>0?tick.ask:tick.bid;
   double oneLotRisk=0.0;
   if(!OrderCalcProfit(typ,_Symbol,1.0,price,sl,oneLotRisk))
   {g_lastAction="WAIT: cannot estimate contract risk";return false;}
   oneLotRisk=MathMax(0.0,-oneLotRisk);
   if(oneLotRisk<=0.0)return false;
   double existingOpenRisk=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(!IsOwnedPosition(t))continue;
      double oldSL=PositionGetDouble(POSITION_SL),stopPL=0.0;
      if(oldSL<=0.0)return false;
      ENUM_ORDER_TYPE oldType=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
      if(!OrderCalcProfit(oldType,_Symbol,PositionGetDouble(POSITION_VOLUME),
                  PositionGetDouble(POSITION_PRICE_OPEN),oldSL,stopPL))return false;
      existingOpenRisk+=MathMax(0.0,-stopPL);
   }
   double available=MathMin(InpMaxNewSignalRiskUSD,InpMaxTotalOpenRiskUSD-existingOpenRisk);
   if(g_profitLocked)
   {
      double atStops=0.0;
      if(!WorstCaseAtStops(atStops))
      {g_lastAction="WAIT: old positions lack protective stop";return false;}
      available=MathMin(available,MathMin(InpPostLockMaxRiskUSD,atStops-g_ladderFloor-InpRiskReserveUSD));
   }
   if(available<=0.0)
   {g_lastAction="WAIT: no permitted risk over ladder floor";return false;}
   bool any=false;
   g_lastAction="WAIT: no safe lot fits risk cap";
   double remaining=available;
   int filled=0;
   double filledVolume=0.0;
   for(int i=0;i<count && already+filled<InpMaximumPositions;i++)
   {
      double lot=NormalizedVolumeDown(MathMin(desiredLot,remaining/oneLotRisk));
      if(!VolumeForBroker(lot))break;
      double risk=0.0;
      if(!OrderCalcProfit(typ,_Symbol,lot,price,sl,risk))break;
      risk=MathMax(0.0,-risk);
      if(risk>remaining+0.01)break;
      bool sent=side>0?trade.Buy(lot,_Symbol,0.0,sl,0.0,why):trade.Sell(lot,_Symbol,0.0,sl,0.0,why);
      if(!sent || !TradeSucceeded())
      {
         g_lastAction="ORDER FAILED: "+trade.ResultRetcodeDescription();
         Print(g_lastAction);
         break;
      }
      remaining-=risk;
      filled++;filledVolume+=lot;
      any=true;
      g_historyDirty=true;
      PrintFormat("PLASA %s %.2f lot SL %.*f estimated-risk=$%.2f",
                  side>0?"BUY":"SELL",lot,_Digits,sl,risk);
   }
   if(any)g_lastAction=StringFormat("%s %d order(s), %.2f lots total (T%d, risk-capped)",
                       side>0?"BUY":"SELL",filled,filledVolume,tier);
   else if(g_lastAction=="")g_lastAction="WAIT: position size exceeds risk budget";
   return any;
}
// This is an EARLY exit on accumulated floating basket profit; not an SL substitute.
void CheckBasketProfit()
{
   int buys,sells;
   int n=OwnedCount(buys,sells);
   if(n==0){g_basketPeak=0.0;return;}
   double floating=BasketFloating();
   if(floating>g_basketPeak)g_basketPeak=floating;
   if(g_basketPeak<InpBasketLockStartUSD)return;
   double floor=MathMax(InpBasketMinLockedUSD,g_basketPeak*InpBasketRetainPercent/100.0);
   if(floating<=floor)
   {
      g_lastAction=StringFormat("EARLY BANK: peak %.2f basket %.2f floor %.2f",g_basketPeak,floating,floor);
      Print("PLASA ",g_lastAction);
      if(CloseOwned("basket peak giveback"))g_basketPeak=0.0;
   }
}

void MakeCountLabel(const datetime t,const double high,const int number,const int candleColor)
{
   string id=g_prefix+"COUNT_"+IntegerToString((long)t);
   if(ObjectFind(0,id)<0) ObjectCreate(0,id,OBJ_TEXT,0,t,high+InpPipSize*30.0);
   else ObjectMove(0,id,0,t,high+InpPipSize*30.0);
   ObjectSetString(0,id,OBJPROP_TEXT,IntegerToString(number));
   ObjectSetInteger(0,id,OBJPROP_COLOR,number==5?clrGold:(candleColor<0?clrTomato:candleColor>0?clrLime:clrSilver));
   ObjectSetInteger(0,id,OBJPROP_FONTSIZE,number==5?12:10);
   ObjectSetInteger(0,id,OBJPROP_ANCHOR,ANCHOR_LOWER);
   ObjectSetInteger(0,id,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,id,OBJPROP_HIDDEN,true);
}
void MakeDecisionLabel(const datetime t,const double high,const int side)
{
   string id=g_prefix+"DEC_"+IntegerToString((long)t);
   if(ObjectFind(0,id)<0) ObjectCreate(0,id,OBJ_TEXT,0,t,high+InpPipSize*65.0);
   else ObjectMove(0,id,0,t,high+InpPipSize*65.0);
   ObjectSetString(0,id,OBJPROP_TEXT,StringFormat("R%d/G%d  %s",g_red,g_green,side>0?"BUY":side<0?"SELL":"WAIT"));
   ObjectSetInteger(0,id,OBJPROP_COLOR,side>0?clrLime:side<0?clrTomato:clrSilver);
   ObjectSetInteger(0,id,OBJPROP_FONTSIZE,10);
   ObjectSetInteger(0,id,OBJPROP_ANCHOR,ANCHOR_LOWER);
   ObjectSetInteger(0,id,OBJPROP_SELECTABLE,false);
}
void TrimLabels()
{
   int maxLabels=MathMax(1,InpKeepChartGroups)*6;
   // Oldest objects first by name timestamp: do not touch non-EA chart objects.
   while(true)
   {
      int count=0;string oldest="";long stamp=LONG_MAX;
      for(int i=ObjectsTotal(0,0,-1)-1;i>=0;i--)
      {
         string name=ObjectName(0,i,0,-1);
         if(StringFind(name,g_prefix+"COUNT_")==0 || StringFind(name,g_prefix+"DEC_")==0)
         {
            count++;
            int pos=StringFind(name,"_",StringLen(g_prefix));
            if(pos<0) continue;
            long ts=(long)StringToInteger(StringSubstr(name,pos+1));
            if(ts<stamp){stamp=ts;oldest=name;}
         }
      }
      if(count<=maxLabels || oldest=="") break;
      ObjectDelete(0,oldest);
   }
}
void Decision()
{
   g_groupSerial++;
   g_lastUpper=g_upper;g_lastLower=g_lower;
   g_lastDelta=g_upper-g_lower;
   int side=0;
   // Three independent tests: candle majority, wick strength by candle color,
   // and upper/lower directional wick imbalance. Equal-color or doji ties => WAIT.
   bool sellPrice=true; // Removed last-H1 close-average filter
   bool buyPrice=true;
   if(g_red>=3 && g_red>g_green && g_redWicks>g_greenWicks &&
      g_lastDelta>=InpMinimumDifferencePips && sellPrice) side=-1;
   else if(g_green>=3 && g_green>g_red && g_greenWicks>g_redWicks &&
           g_lastDelta<=-InpMinimumDifferencePips && buyPrice) side=1;
   g_priceConfirm=side<0?"SELL wick OK":side>0?"BUY wick OK":"WICKS WAIT";
   g_lastDirection=side;
   g_lastRed=g_red;g_lastGreen=g_green;
   g_lastRedWicks=g_redWicks;g_lastGreenWicks=g_greenWicks;
   g_lastReason=StringFormat("GROUP %d R%d/G%d/Doji%d | red wicks %.1f green %.1f | upper %.1f lower %.1f diff %+.1f",
              g_groupSerial,g_red,g_green,g_doji,g_redWicks,g_greenWicks,g_upper,g_lower,g_lastDelta);
   if(side==0){g_lastAction="WAIT: wick / majority";g_signalStrength="WAIT";g_signalScore=0;return;}
   int buys,sells;
   int total=OwnedCount(buys,sells);
   bool opposite=(side>0?sells>0:buys>0);
   if(opposite)
   {
      if(!CloseOwned("opposite five-H1 wick signal"))
      {g_lastAction="REVERSAL BLOCKED: old positions could not all close";return;}
      g_basketPeak=0.0;
   }
   if(total>0 && !opposite && (side>0?buys==0:sells==0))
   {g_lastAction="BLOCKED: mixed position state";return;}
   OpenSide(side,opposite?"5H1 reversal":"5H1 wick dominance/add");
}
void ProcessClosedH1()
{
   MqlRates h1[];ArraySetAsSeries(h1,true);
   if(CopyRates(_Symbol,PERIOD_H1,1,1,h1)!=1) return;
   double upper=(h1[0].high-MathMax(h1[0].open,h1[0].close))/InpPipSize;
   double lower=(MathMin(h1[0].open,h1[0].close)-h1[0].low)/InpPipSize;
   upper=MathMax(0.0,upper);lower=MathMax(0.0,lower);
   g_upper+=upper;g_lower+=lower;
   g_closeSum+=h1[0].close;
   g_lastClose=h1[0].close;
   int candleColor=0;
   if(h1[0].close>h1[0].open){candleColor=1;g_green++;g_greenWicks+=upper+lower;}
   else if(h1[0].close<h1[0].open){candleColor=-1;g_red++;g_redWicks+=upper+lower;}
   else g_doji++;
   g_count++;
   MakeCountLabel(h1[0].time,h1[0].high,g_count,candleColor);
   if(g_count==5)
   {
      int direction=0;
      double diff=g_upper-g_lower;
      if(g_red>=3 && g_red>g_green && g_redWicks>g_greenWicks && diff>=InpMinimumDifferencePips) direction=-1;
      else if(g_green>=3 && g_green>g_red && g_greenWicks>g_redWicks && diff<=-InpMinimumDifferencePips) direction=1;
      MakeDecisionLabel(h1[0].time,h1[0].high,direction);
      Decision();
      g_count=0;g_upper=0.0;g_lower=0.0;g_closeSum=0.0;g_lastClose=0.0;
      g_red=0;g_green=0;g_doji=0;g_redWicks=0.0;g_greenWicks=0.0;
      TrimLabels();
   }
}
void PanelLine(const int n,const string value,const color txt)
{
   string id=g_prefix+"P_"+IntegerToString(n);
   if(ObjectFind(0,id)<0)
   {
      ObjectCreate(0,id,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,id,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,id,OBJPROP_XDISTANCE,24);
      ObjectSetInteger(0,id,OBJPROP_YDISTANCE,27+n*21);
      ObjectSetString(0,id,OBJPROP_FONT,"Consolas");
      ObjectSetInteger(0,id,OBJPROP_FONTSIZE,10);
      ObjectSetInteger(0,id,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,id,OBJPROP_HIDDEN,true);
   }
   ObjectSetInteger(0,id,OBJPROP_COLOR,txt);
   ObjectSetString(0,id,OBJPROP_TEXT,value);
}
void UpdatePanel()
{
   if(!InpShowPanel)return;
   string bg=g_prefix+"P_BG";
   if(ObjectFind(0,bg)<0)
   {
      ObjectCreate(0,bg,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,bg,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,bg,OBJPROP_XDISTANCE,12);
      ObjectSetInteger(0,bg,OBJPROP_YDISTANCE,14);
      ObjectSetInteger(0,bg,OBJPROP_XSIZE,348);
      ObjectSetInteger(0,bg,OBJPROP_YSIZE,245);
      ObjectSetInteger(0,bg,OBJPROP_BGCOLOR,C'17,27,42');
      ObjectSetInteger(0,bg,OBJPROP_COLOR,C'68,91,117');
      ObjectSetInteger(0,bg,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,bg,OBJPROP_BACK,false);
      ObjectSetInteger(0,bg,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,bg,OBJPROP_HIDDEN,true);
   }
   int buys,sells;
   int positions=OwnedCount(buys,sells);
   double net=DayResult();
   double protectedBudget=g_profitLocked?MathMax(0.0,net-g_ladderFloor-InpRiskReserveUSD):0.0;
   string direction=g_lastDirection>0?"BUY":g_lastDirection<0?"SELL":"WAIT";
   PanelLine(0,"PLASA  |  WICK BALANCE 5.07",clrAqua);
   PanelLine(1,StringFormat("H1 GROUP  %d/5    SIGNAL  %s",g_count,direction),g_lastDirection>0?clrLime:g_lastDirection<0?clrTomato:clrWhite);
   PanelLine(2,StringFormat("UP %.0fp  DOWN %.0fp  R%d/G%d",g_upper,g_lower,g_red,g_green),clrWhite);
   PanelLine(3,StringFormat("OPEN %d  |  FLOAT $%.2f",positions,BasketFloating()),clrWhite);
   PanelLine(4,StringFormat("DAY P/L  $%.2f",net),net>=0?clrLime:clrTomato);
   PanelLine(5,StringFormat("FLOOR $%.0f  | NEXT $%.0f",g_ladderFloor,g_nextStep),g_profitLocked?clrLime:clrYellow);
   PanelLine(6,StringFormat("BUFFER $%.2f | PEAK $%.0f",protectedBudget,g_ladderPeak),clrWhite);
   PanelLine(7,"POSITION: "+g_signalStrength,clrWhite);
   PanelLine(8,StringFormat("BASKET PEAK $%.0f | EARLY FLOOR $%.0f",g_basketPeak,
                            g_basketPeak>=InpBasketLockStartUSD?MathMax(InpBasketMinLockedUSD,g_basketPeak*InpBasketRetainPercent/100.0):0.0),clrYellow);
   PanelLine(9,"ACTION: "+StringSubstr(g_lastAction,0,38),clrSilver);
}
int OnInit()
{
   if(InpPipSize<=0 || InpLots<=0 || InpMaxLotsPerPosition<InpLots || InpMaxLotsPerPosition>0.05 ||
      InpMaxOrdersPerSignal<1 || InpMaxOrdersPerSignal>2 || InpBasketMinLockedUSD<0 || InpMinimumDifferencePips<0 ||
      InpMaxNewSignalRiskUSD<=0 || InpMaxTotalOpenRiskUSD<=0 || InpATRStopMultiplier<=0 || InpATRPeriod<2 ||
      InpBasketLockStartUSD<=0 || InpBasketRetainPercent<=0 || InpBasketRetainPercent>=100 ||
      InpMaximumPositions<1 || InpKeepChartGroups<1 || InpPanelRefreshSeconds<1 ||
      InpProfitTriggerUSD<=InpProfitFloorUSD || InpProfitStepUSD<=0 || InpPostLockMaxRiskUSD<=0 ||
      InpRiskReserveUSD<0)
      return INIT_PARAMETERS_INCORRECT;
   if(InpDemoOnly && !MQLInfoInteger(MQL_TESTER) && AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO)
   {Print("PLASA demo/test only: refusing to run on a live account.");return INIT_FAILED;}
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {Print("PLASA requires a hedging account to add independent positions.");return INIT_FAILED;}
   if(StringFind(_Symbol,"XAUUSD")!=0)
   {Print("PLASA supports XAUUSD with optional broker suffix only.");return INIT_FAILED;}
   if(!VolumeValid())
   {Print("PLASA invalid lot for this broker.");return INIT_PARAMETERS_INCORRECT;}
   g_atrHandle=iATR(_Symbol,PERIOD_H1,InpATRPeriod);
   if(g_atrHandle==INVALID_HANDLE){Print("PLASA: unable to create H1 ATR");return INIT_FAILED;}
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   g_prefix="PLASA_WB_"+IntegerToString((long)InpMagic)+"_";
   g_lastH1Open=iTime(_Symbol,PERIOD_H1,0);
   ResetDay();RefreshRealized();
   if(!MQLInfoInteger(MQL_TESTER))EventSetTimer(InpPanelRefreshSeconds);
   UpdatePanel();
   Print("PLASA v5.07 start. Counts five new closed H1 bars from EA initialization.");
   return INIT_SUCCEEDED;
}
void OnTick()
{
   CheckProfitLock();
   CheckBasketProfit();
   datetime h1=iTime(_Symbol,PERIOD_H1,0);
   if(h1!=0 && h1!=g_lastH1Open)
   {
      g_lastH1Open=h1;
      ProcessClosedH1();
      UpdatePanel();
   }
}
void OnTimer()
{
   CheckProfitLock();
   CheckBasketProfit();
   UpdatePanel();
}
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD)g_historyDirty=true;
}
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_atrHandle!=INVALID_HANDLE)IndicatorRelease(g_atrHandle);
   for(int i=0;i<10;i++) ObjectDelete(0,g_prefix+"P_"+IntegerToString(i));
   ObjectDelete(0,g_prefix+"P_BG");
   // Keep historical count and decision labels on chart for reviewing test.
}