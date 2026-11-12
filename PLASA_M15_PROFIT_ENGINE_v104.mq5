//+------------------------------------------------------------------+
//| PLASA M15 FOURTH CANDLE STOP v1.04                                |
//| Fresh EA: first closed candle color enters; fourth candle sets SL |
//| Demo / Strategy Tester only.                                      |
//+------------------------------------------------------------------+
#property strict
#property version "1.04"
#property description "One-direction M15 basket, fourth-candle SL per trade; optimized new-M15 updates."
#include <Trade/Trade.mqh>

input double InpLots=0.01;
input double InpPipSize=0.10;          // Gold pip convention: 0.10 price units
input int InpInitialStopPips=50;
input int InpMaxPositions=10;       // One new entry per M15, up to this total
input int InpBarsToProtect=4;         // 4 completed M15 candles after entry
input double InpBasketStartUSD=100.0; // Start protection once basket float reaches $100
input double InpBasketKeepPct=85.0;  // Preserve 85% of observed basket high-water P/L
input double InpProtectedRatio=0.70; // 70% tight trailing / 30% wide runners
input int InpTrailActivationPips=50;
input int InpTightTrailPips=40;
input int InpRunnerTrailPips=110;
input int InpMinSLMovePips=10;
input double InpMaxStopRiskUSD=100.0;
input ulong InpMagic=26111292;
input bool InpCloseIfFourthStopPassed=true; // When 4th low/high already passed and position is in profit
input bool InpDemoOnly=true;
input bool InpAllowOrders=true;
input int InpDeviationPoints=30;
input bool InpDrawTradeLines=true;
input bool InpMarkCandles=true;

CTrade tr;
datetime gLastM15=0;
string gPrefix="";
string gStatus="Waiting for first CLOSED M15 candle";
string gProtection="No position";
int gLastSignal=0;
double gPlannedStop=0.0;
int gBarsElapsed=0;
double gPeakFloat=0.0,gFloorFloat=0.0,gCurrentFloat=0.0;
bool gExitingBasket=false,gPauseUntilNextBar=false;
string gProfitStatus="No protection active";
int gTightCount=0,gRunnerCount=0;

string SideName(int s){return s>0?"BUY":s<0?"SELL":"WAIT";}
bool TradeSuccess()
{
 uint code=tr.ResultRetcode();
 return code==TRADE_RETCODE_DONE || code==TRADE_RETCODE_DONE_PARTIAL;
}
bool Owned(ulong t)
{
 if(t==0 || !PositionSelectByTicket(t))return false;
 return PositionGetString(POSITION_SYMBOL)==_Symbol &&
        (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic;
}
ulong FindPosition()
{
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
   ulong ticket=PositionGetTicket(i);
   if(Owned(ticket))return ticket;
 }
 return 0;
}
bool TradesEnabled()
{
 return InpAllowOrders &&
       TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) &&
       MQLInfoInteger(MQL_TRADE_ALLOWED);
}
double RoundStop(double price,int side)
{
 double step=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
 if(step<=0)step=_Point;
 double v=(side>0?MathFloor(price/step):MathCeil(price/step))*step;
 return NormalizeDouble(v,_Digits);
}
bool StopCanBeSet(int side,double stop,const MqlTick &quote)
{
 double stops=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
 double freeze=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)*_Point;
 double minDist=MathMax(stops,freeze)+_Point;
 return side>0?stop<quote.bid-minDist:stop>quote.ask+minDist;
}
void MarkSignal(const MqlRates &bar,int side)
{
 if(!InpMarkCandles)return;
 string name=gPrefix+"C_"+IntegerToString((long)bar.time);
 if(ObjectFind(0,name)<0)ObjectCreate(0,name,OBJ_TEXT,0,bar.time,bar.high+10*InpPipSize);
 ObjectSetString(0,name,OBJPROP_TEXT,SideName(side));
 ObjectSetInteger(0,name,OBJPROP_COLOR,side>0?clrLime:clrTomato);
 ObjectSetInteger(0,name,OBJPROP_FONTSIZE,8);
 ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LOWER);
 ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
}
void UpsertHLine(const string name,double price,color c,int style)
{
 if(ObjectFind(0,name)<0)ObjectCreate(0,name,OBJ_HLINE,0,0,price);
 else ObjectMove(0,name,0,0,price);
 ObjectSetInteger(0,name,OBJPROP_COLOR,c);
 ObjectSetInteger(0,name,OBJPROP_STYLE,style);
 ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
 ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
}
// Each ticket gets OWN entry and stop line; never overlay only the first.
// Update visible entry and SL levels once per M15 candle.
// Reuse objects rather than deleting/recreating everything each update.
void UpdateLines()
{
 if(!InpDrawTradeLines)return;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong ticket=PositionGetTicket(i);
  if(!Owned(ticket))continue;
  string id=IntegerToString((long)ticket);
  double entry=PositionGetDouble(POSITION_PRICE_OPEN);
  double sl=PositionGetDouble(POSITION_SL);
  bool buy=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY;
  UpsertHLine(gPrefix+"ENTRY_"+id,entry,buy?clrLime:clrTomato,STYLE_DOT);
  if(sl>0)UpsertHLine(gPrefix+"SL_"+id,sl,clrOrange,STYLE_SOLID);
 }
 for(int i=ObjectsTotal(0,0,-1)-1;i>=0;i--)
 {
  string name=ObjectName(0,i,0,-1);
  int offset=-1;
  if(StringFind(name,gPrefix+"ENTRY_")==0)offset=StringLen(gPrefix)+6;
  else if(StringFind(name,gPrefix+"SL_")==0)offset=StringLen(gPrefix)+3;
  if(offset<0)continue;
  ulong ticket=(ulong)StringToInteger(StringSubstr(name,offset));
  if(!Owned(ticket))ObjectDelete(0,name);
 }
}
double BotFloat()
{
 double sum=0.0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong t=PositionGetTicket(i);
  if(Owned(t))sum+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
 }
 return sum;
}
int BotCount()
{
 int n=0;
 for(int i=PositionsTotal()-1;i>=0;i--)
  if(Owned(PositionGetTicket(i)))n++;
 return n;
}
double NegativeStopRisk()
{
 double risk=0.0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong t=PositionGetTicket(i);
  if(!Owned(t))continue;
  double sl=PositionGetDouble(POSITION_SL);
  if(sl<=0){risk+=InpMaxStopRiskUSD;continue;}
  ENUM_ORDER_TYPE type=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?
              ORDER_TYPE_BUY:ORDER_TYPE_SELL;
  double p=0.0;
  if(!OrderCalcProfit(type,_Symbol,PositionGetDouble(POSITION_VOLUME),
       PositionGetDouble(POSITION_PRICE_OPEN),sl,p)){risk+=InpMaxStopRiskUSD;continue;}
  if(p<0)risk-=p;
 }
 return risk;
}
bool RiskAllowsEntry(int side)
{
 MqlTick q;
 if(!SymbolInfoTick(_Symbol,q))return false;
 double entry=side>0?q.ask:q.bid;
 double sl=entry+(side>0?-1.0:1.0)*InpInitialStopPips*InpPipSize;
 double p=0.0;
 if(!OrderCalcProfit(side>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL,
                      _Symbol,InpLots,entry,sl,p))return false;
 return NegativeStopRisk()+MathMax(0.0,-p)<=InpMaxStopRiskUSD+0.001;
}
bool CloseAllOwnedFast()
{
 bool success=true;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong ticket=PositionGetTicket(i);
  if(!Owned(ticket))continue;
  if(!tr.PositionClose(ticket)||!TradeSuccess())
  {
   success=false;
   PrintFormat("PLASA PROFIT CLOSE ERROR #%I64u: %s",ticket,tr.ResultRetcodeDescription());
  }
 }
 return success && BotCount()==0;
}
void TrailProfitablePositions()
{
 int total=BotCount();
 if(total==0){gTightCount=0;gRunnerCount=0;return;}
 int tight=(int)MathCeil(total*InpProtectedRatio);
 gTightCount=tight;gRunnerCount=total-tight;
 MqlTick q;
 if(!SymbolInfoTick(_Symbol,q))return;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong ticket=PositionGetTicket(i);
  if(!Owned(ticket))continue;
  int side=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1;
  double entry=PositionGetDouble(POSITION_PRICE_OPEN);
  double quote=side>0?q.bid:q.ask;
  double favorable=(side>0?quote-entry:entry-quote)/InpPipSize;
  if(favorable<InpTrailActivationPips)continue;
  long openMs=PositionGetInteger(POSITION_TIME_MSC);
  int rank=0;
  for(int j=PositionsTotal()-1;j>=0;j--)
  {
   ulong other=PositionGetTicket(j);
   if(other==ticket||!Owned(other))continue;
   long ms=PositionGetInteger(POSITION_TIME_MSC);
   if(ms<openMs||(ms==openMs&&other<ticket))rank++;
  }
  if(!PositionSelectByTicket(ticket))continue;
  bool isTight=rank<tight;
  int trail=isTight?InpTightTrailPips:InpRunnerTrailPips;
  double newSL=RoundStop(quote+(side>0?-1.0:1.0)*trail*InpPipSize,side);
  double oldSL=PositionGetDouble(POSITION_SL);
  if(oldSL>0 && (side>0?newSL<oldSL+InpMinSLMovePips*InpPipSize:
                            newSL>oldSL-InpMinSLMovePips*InpPipSize))continue;
  if(!StopCanBeSet(side,newSL,q))continue;
  if(!tr.PositionModify(ticket,newSL,PositionGetDouble(POSITION_TP))||!TradeSuccess())
    PrintFormat("PLASA TRAIL ERROR #%I64u: %s",ticket,tr.ResultRetcodeDescription());
 }
}
void ProtectOnEveryTick()
{
 int n=BotCount();
 if(n==0)
 {
  gCurrentFloat=0.0;
  gFloorFloat=0.0;
  if(!gExitingBasket)gPeakFloat=0.0;
  return;
 }
 if(gExitingBasket)
 {
  if(CloseAllOwnedFast())
  {
   gExitingBasket=false;
   gPauseUntilNextBar=true;
   gPeakFloat=0.0;gFloorFloat=0.0;
   gProfitStatus="Basket closed; wait for next completed M15";
  }
  return;
 }
 gCurrentFloat=BotFloat();
 if(gCurrentFloat>gPeakFloat)gPeakFloat=gCurrentFloat;
 gFloorFloat=gPeakFloat>=InpBasketStartUSD?
             gPeakFloat*InpBasketKeepPct/100.0:0.0;
 if(gFloorFloat>0.0 && gCurrentFloat<=gFloorFloat)
 {
  gProfitStatus=StringFormat("BASKET EXIT peak %.2f floor %.2f actual %.2f",
            gPeakFloat,gFloorFloat,gCurrentFloat);
  Print("PLASA ",gProfitStatus);
  gExitingBasket=true;
  if(CloseAllOwnedFast())
  {
   gExitingBasket=false;
   gPauseUntilNextBar=true;
   gPeakFloat=0.0;gFloorFloat=0.0;gCurrentFloat=0.0;
  }
  return;
 }
 TrailProfitablePositions();
}

bool OpenOnClosedCandle(int side)
{
 if(!TradesEnabled())
 {
  gStatus="BLOCKED: MT5 Algo Trading is OFF";
  return false;
 }
 int active=0,buys=0,sells=0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong ticket=PositionGetTicket(i);
  if(!Owned(ticket))continue;
  active++;
  if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)buys++;
  else sells++;
 }
 if((side>0 && sells>0)||(side<0 && buys>0))
 {
  gStatus=StringFormat("WAIT: %s signal blocked; active basket %s",
        SideName(side),buys>0?"BUY":"SELL");
  return false;
 }
 if(gExitingBasket||gPauseUntilNextBar)
 {
  gStatus="WAIT: profit basket exit";
  return false;
 }
 if(!RiskAllowsEntry(side))
 {
  gStatus="WAIT: aggregate stop loss risk cap";
  return false;
 }
 if(active>=InpMaxPositions)
 {
  gStatus=StringFormat("WAIT: %d active positions (max %d)",active,InpMaxPositions);
  return false;
 }
 MqlTick quote;
 if(!SymbolInfoTick(_Symbol,quote)||quote.bid<=0||quote.ask<=0)
 {
  gStatus="WAIT: invalid broker quote";
  return false;
 }
 double entry=side>0?quote.ask:quote.bid;
 double sl=RoundStop(entry+(side>0?-1.0:1.0)*InpInitialStopPips*InpPipSize,side);
 if(!StopCanBeSet(side,sl,quote))
 {
  gStatus="WAIT: broker spread/stop level disallows 50-pip SL";
  return false;
 }
 bool sent=side>0?
       tr.Buy(InpLots,_Symbol,0.0,sl,0.0,"PLASA M15 fourth BUY"):
       tr.Sell(InpLots,_Symbol,0.0,sl,0.0,"PLASA M15 fourth SELL");
 if(sent&&TradeSuccess())
 {
  gBarsElapsed=0;gPlannedStop=0.0;
  gProtection="Each position independently counts four M15";
  gStatus=StringFormat("OPEN %s %.2f lot | initial SL %.2f",SideName(side),InpLots,sl);
  Print("PLASA M15 ",gStatus);
  return true;
 }
 gStatus="ORDER FAILED: "+tr.ResultRetcodeDescription();
 Print("PLASA M15 ",gStatus);
 return false;
}
// The entry is placed at the first tick of a NEW M15 bar after the
// signaling candle closes. At shift=4, exactly four M15 bars have closed.
// Fourth candle's LOW for BUY / HIGH for SELL is the proposed protective
// stop. It may be applied later if broker rules block it at first.
// NEVER widen a stop and NEVER claim a profit lock if level < entry profit.
// Evaluate each active ticket independently: its fourth FULL M15 candle
// after entry is a fixed reference. Once closed, move SL to fourth
// candle LOW (BUY) or HIGH (SELL), but only when profitable and legal.
// If price has already crossed that level and position is in profit,
// optionally close at market (cannot place a stop beyond current price).
void ManageFourthCandleStop()
{
 int active=0,protectedCount=0,notReady=0,unavailable=0;
 gPlannedStop=0;gBarsElapsed=0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong ticket=PositionGetTicket(i);
  if(!Owned(ticket))continue;
  active++;
  datetime opened=(datetime)PositionGetInteger(POSITION_TIME);
  int side=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1;
  double entry=PositionGetDouble(POSITION_PRICE_OPEN);
  double oldSL=PositionGetDouble(POSITION_SL);
  double profit=PositionGetDouble(POSITION_PROFIT);
  int shift=iBarShift(_Symbol,PERIOD_M15,opened,false);
  if(shift<0){unavailable++;continue;}
  if(shift>gBarsElapsed)gBarsElapsed=shift;
  if(shift<InpBarsToProtect){notReady++;continue;}
  int targetShift=shift-InpBarsToProtect+1;
  MqlRates fourth[];
  ArraySetAsSeries(fourth,true);
  if(CopyRates(_Symbol,PERIOD_M15,targetShift,1,fourth)!=1)
  {unavailable++;continue;}
  double target=RoundStop(side>0?fourth[0].low:fourth[0].high,side);
  gPlannedStop=target;
  // A stop that does not improve the risk and does not lock profit
  // cannot serve as profit-taking. Do not widen stops.
  bool locksProfit=side>0?target>entry:target<entry;
  bool tighter=oldSL<=0 || (side>0?target>oldSL+_Point*0.1:target<oldSL-_Point*0.1);
  if(!locksProfit || !tighter){unavailable++;continue;}
  MqlTick q;
  if(!SymbolInfoTick(_Symbol,q)){unavailable++;continue;}
  if(StopCanBeSet(side,target,q))
  {
   if(!TradesEnabled()){unavailable++;continue;}
   if(tr.PositionModify(ticket,target,PositionGetDouble(POSITION_TP))&&TradeSuccess())
   {
    protectedCount++;
    PrintFormat("PLASA M15 ticket #%I64u: fourth candle SL locked %.2f",ticket,target);
   }
   else
   {
    unavailable++;
    PrintFormat("PLASA M15 ticket #%I64u: SL modify failed: %s",ticket,tr.ResultRetcodeDescription());
   }
  }
  else if(InpCloseIfFourthStopPassed && profit>0 && TradesEnabled())
  {
   // Cannot place protective stop at a price already crossed.
   // Close PROFITABLE position instead; not a guaranteed fill.
   if(tr.PositionClose(ticket)&&TradeSuccess())
   {
    protectedCount++;
    PrintFormat("PLASA M15 ticket #%I64u: fourth candle passed, profit closed",ticket);
   }
   else
   {
    unavailable++;
    PrintFormat("PLASA M15 ticket #%I64u: close failed: %s",ticket,tr.ResultRetcodeDescription());
   }
  }
  else unavailable++;
 }
 gProtection=StringFormat("ACTIVE %d | 4TH WAIT %d | MOVED/CLOSED %d | NO LOCK %d",
     active,notReady,protectedCount,unavailable);
 if(active==0)gProtection="No open positions; waiting for next closed M15";
}
void ShowStatus()
{
 datetime nowBar=iTime(_Symbol,PERIOD_M15,0);
 datetime nextBar=nowBar+PeriodSeconds(PERIOD_M15);
 int seconds=(int)(nextBar-TimeCurrent());if(seconds<0)seconds=0;
 int total=0,buys=0,sells=0;
 double floating=0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong ticket=PositionGetTicket(i);
  if(!Owned(ticket))continue;
  total++;
  if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)buys++;
  else sells++;
  floating+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
 }
 string msg="PLASA M15 | PROFIT ENGINE v1.04\n";
 msg+=StringFormat("NEXT M15 %s | %02d:%02d (SERVER)\n",
   TimeToString(nextBar,TIME_MINUTES),seconds/60,seconds%60);
 msg+=StringFormat("LAST CLOSED CANDLE: %s\n",SideName(gLastSignal));
 msg+=StringFormat("POSITIONS %d/%d | BUY %d SELL %d | FLOAT $%.2f\n",
   total,InpMaxPositions,buys,sells,floating);
 msg+=StringFormat("INITIAL SL %d pips | FOURTH M15 LOW/HIGH\n",InpInitialStopPips);
 msg+="FOURTH CANDLE: "+gProtection+"\n";
 msg+=StringFormat("BASKET FLOAT $%.2f | PEAK $%.2f | FLOOR $%.2f\n",
       gCurrentFloat,gPeakFloat,gFloorFloat);
 msg+=StringFormat("TRAIL: TIGHT %d | RUNNER %d | STOP RISK $%.2f\n",
       gTightCount,gRunnerCount,NegativeStopRisk());
 msg+="PROFIT STATUS: "+gProfitStatus+"\n";
 msg+="LAST ACTION: "+gStatus+"\n";
 msg+="DOT ENTRY: GREEN/RED | SOLID ORANGE: EACH SL\n";
 msg+="DEMO/TESTER ONLY | NO FIXED TP";
 Comment(msg);
}
int OnInit()
{
 if(InpLots<=0 || InpPipSize<=0 || InpInitialStopPips<1 ||
    InpBarsToProtect<1 || InpMaxPositions<1 ||
    InpBasketStartUSD<=0 || InpBasketKeepPct<=0 || InpBasketKeepPct>=100 ||
    InpProtectedRatio<=0 || InpProtectedRatio>=1 ||
    InpTrailActivationPips<1 || InpTightTrailPips<1 ||
    InpRunnerTrailPips<=InpTightTrailPips || InpMinSLMovePips<1 ||
    InpMaxStopRiskUSD<=0)return INIT_PARAMETERS_INCORRECT;
 if(InpDemoOnly && !MQLInfoInteger(MQL_TESTER) &&
    AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO)
 {Print("PLASA M15: demo or tester only");return INIT_FAILED;}
 if(StringFind(_Symbol,"XAUUSD")!=0)
 {Print("PLASA M15: only XAUUSD or broker suffix");return INIT_FAILED;}
 if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
 {Print("PLASA M15: requires HEDGING account");return INIT_FAILED;}
 double volStep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
 double minVol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
 double maxVol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
 if(volStep<=0||InpLots<minVol||InpLots>maxVol||
    MathAbs(InpLots/volStep-MathRound(InpLots/volStep))>1e-6)
 {Print("PLASA M15: invalid volume for broker");return INIT_PARAMETERS_INCORRECT;}
 tr.SetExpertMagicNumber(InpMagic);
 tr.SetDeviationInPoints(InpDeviationPoints);
 tr.SetTypeFillingBySymbol(_Symbol);
 gPrefix="PLASA_M15_4TH_"+IntegerToString((long)InpMagic)+"_";
 gLastM15=iTime(_Symbol,PERIOD_M15,0);
 ManageFourthCandleStop();
 UpdateLines();
 ShowStatus();
 return INIT_SUCCEEDED;
}
void OnTick()
{
 ProtectOnEveryTick();
 datetime bar=iTime(_Symbol,PERIOD_M15,0);
 if(bar==0 || bar==gLastM15)return;
 gLastM15=bar;
 if(gPauseUntilNextBar)gPauseUntilNextBar=false;
 // Fourth-candle management and panel update only on completed M15.
 ManageFourthCandleStop();
 MqlRates last[];
 ArraySetAsSeries(last,true);
 if(CopyRates(_Symbol,PERIOD_M15,1,1,last)==1)
 {
  int candleSide=last[0].close>last[0].open?1:last[0].close<last[0].open?-1:0;
  gLastSignal=candleSide;
  if(candleSide!=0)
  {
    MarkSignal(last[0],candleSide);
    OpenOnClosedCandle(candleSide);
  }
 }
 UpdateLines();
 ShowStatus();
}
void OnDeinit(const int reason)
{
 Comment("");
 for(int i=ObjectsTotal(0,0,-1)-1;i>=0;i--)
 {
  string name=ObjectName(0,i,0,-1);
  if(StringFind(name,gPrefix+"ENTRY_")==0 ||
     StringFind(name,gPrefix+"SL_")==0)
   ObjectDelete(0,name);
 }
}
