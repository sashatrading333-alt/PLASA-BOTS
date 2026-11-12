//+------------------------------------------------------------------+
//| PLASA M15 FOURTH CANDLE STOP v1.00                                |
//| Fresh EA: first closed candle color enters; fourth candle sets SL |
//| Demo / Strategy Tester only.                                      |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"
#property description "M15 first green BUY/red SELL, initial 50-pip SL, fourth-candle low/high profit-lock SL. Demo/tester."
#include <Trade/Trade.mqh>

input double InpLots=0.01;
input double InpPipSize=0.10;          // Gold pip convention: 0.10 price units
input int InpInitialStopPips=50;
input int InpBarsToProtect=4;         // 4 completed M15 candles after entry
input ulong InpMagic=26111291;
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
void UpdateLines()
{
 if(!InpDrawTradeLines)return;
 ulong t=FindPosition();
 if(t==0)
 {
  ObjectDelete(0,gPrefix+"ENTRY");
  ObjectDelete(0,gPrefix+"SL");
  ObjectDelete(0,gPrefix+"CANDLE4");
  return;
 }
 double entry=PositionGetDouble(POSITION_PRICE_OPEN);
 double sl=PositionGetDouble(POSITION_SL);
 int side=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1;
 UpsertHLine(gPrefix+"ENTRY",entry,side>0?clrLime:clrTomato,STYLE_DOT);
 if(sl>0)UpsertHLine(gPrefix+"SL",sl,clrOrange,STYLE_SOLID);
 if(gPlannedStop>0)UpsertHLine(gPrefix+"CANDLE4",gPlannedStop,clrAqua,STYLE_DASH);
 else ObjectDelete(0,gPrefix+"CANDLE4");
}
bool OpenOnClosedCandle(int side)
{
 if(!TradesEnabled())
 {
  gStatus="BLOCKED: MT5 Algo Trading is OFF";
  return false;
 }
 if(FindPosition()!=0)return false; // Only one position at a time
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
  gProtection="WAIT: four completed M15 candles";
  gStatus=StringFormat("OPEN %s %.2f lot | initial SL %.2f",SideName(side),InpLots,sl);
  Print("PLASA M15 ",gStatus);
  UpdateLines();
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
void ManageFourthCandleStop()
{
 ulong ticket=FindPosition();
 if(ticket==0)
 {
  gBarsElapsed=0;gPlannedStop=0.0;gProtection="No open position";
  return;
 }
 datetime opened=(datetime)PositionGetInteger(POSITION_TIME);
 int side=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1;
 double entry=PositionGetDouble(POSITION_PRICE_OPEN);
 double currentSL=PositionGetDouble(POSITION_SL);
 int shift=iBarShift(_Symbol,PERIOD_M15,opened,false);
 if(shift<0){gProtection="WAIT: M15 history unavailable";return;}
 gBarsElapsed=shift;
 if(shift<InpBarsToProtect)
 {
  gProtection=StringFormat("WAIT: M15 bars after entry %d/%d",shift,InpBarsToProtect);
  gPlannedStop=0.0;
  return;
 }
 int targetShift=shift-InpBarsToProtect+1;
 MqlRates fourth[];
 ArraySetAsSeries(fourth,true);
 if(CopyRates(_Symbol,PERIOD_M15,targetShift,1,fourth)!=1)
 {gProtection="WAIT: cannot read fourth M15 candle";return;}
 double raw=side>0?fourth[0].low:fourth[0].high;
 double candidate=RoundStop(raw,side);
 gPlannedStop=candidate;
 bool locksProfit=side>0?candidate>entry:candidate<entry;
 if(!locksProfit)
 {
  gProtection=StringFormat("4th candle %.2f does NOT lock profit; initial SL kept",candidate);
  return;
 }
 // Stops move only in the profitable direction.
 if(currentSL>0 && (side>0?candidate<=currentSL:candidate>=currentSL))
 {
  gProtection=StringFormat("LOCKED: SL %.2f (4th M15 level %.2f)",currentSL,candidate);
  return;
 }
 MqlTick q;
 if(!SymbolInfoTick(_Symbol,q)||!StopCanBeSet(side,candidate,q))
 {
  gProtection=StringFormat("WAIT: 4th candle stop %.2f too close to market",candidate);
  return;
 }
 if(!TradesEnabled())
 {
  gProtection="WAIT: Algo Trading disabled - cannot protect";
  return;
 }
 double tp=PositionGetDouble(POSITION_TP);
 if(tr.PositionModify(ticket,candidate,tp)&&TradeSuccess())
 {
  gProtection=StringFormat("PROFIT LOCK APPLIED: SL %.2f",candidate);
  gStatus=gProtection;
  Print("PLASA M15 ",gProtection);
  UpdateLines();
 }
 else
 {
  gProtection="SL MODIFY FAILED: "+tr.ResultRetcodeDescription();
  Print("PLASA M15 ",gProtection);
 }
}
void ShowStatus()
{
 ulong ticket=FindPosition();
 datetime nowBar=iTime(_Symbol,PERIOD_M15,0);
 datetime nextBar=nowBar+PeriodSeconds(PERIOD_M15);
 int secs=(int)(nextBar-TimeCurrent());if(secs<0)secs=0;
 string msg="PLASA M15 | FOURTH CANDLE SL 1.00\n";
 msg+=StringFormat("NEXT M15: %s (%02d:%02d) SERVER\n",
                   TimeToString(nextBar,TIME_MINUTES),secs/60,secs%60);
 msg+=StringFormat("LAST CLOSED SIGNAL: %s\n",SideName(gLastSignal));
 msg+=StringFormat("POSITION: %s | BARS %d/%d\n",ticket>0?"OPEN":"NONE",gBarsElapsed,InpBarsToProtect);
 if(ticket>0)
 {
  int side=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1;
  msg+=StringFormat("%s ENTRY %.2f | SL %.2f | FLOAT $%.2f\n",
         SideName(side),PositionGetDouble(POSITION_PRICE_OPEN),
         PositionGetDouble(POSITION_SL),PositionGetDouble(POSITION_PROFIT));
 }
 msg+="FOURTH M15 SL: "+gProtection+"\n";
 msg+="ACTION: "+gStatus+"\n";
 msg+="GREEN/RED dotted: entry | ORANGE: SL | AQUA dashed: M15-4 level\n";
 msg+="DEMO / TESTER ONLY | NO FIXED TP";
 Comment(msg);
}
int OnInit()
{
 if(InpLots<=0 || InpPipSize<=0 || InpInitialStopPips<1 ||
    InpBarsToProtect<1)return INIT_PARAMETERS_INCORRECT;
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
 ShowStatus();
 return INIT_SUCCEEDED;
}
void OnTick()
{
 ManageFourthCandleStop(); // Check on every tick for broker-allowed SL move
 datetime bar=iTime(_Symbol,PERIOD_M15,0);
 if(bar!=0&&bar!=gLastM15)
 {
  gLastM15=bar;
  MqlRates last[];
  ArraySetAsSeries(last,true);
  if(CopyRates(_Symbol,PERIOD_M15,1,1,last)==1)
  {
   int color=last[0].close>last[0].open?1:last[0].close<last[0].open?-1:0;
   gLastSignal=color;
   if(color!=0)
   {
    MarkSignal(last[0],color);
    if(FindPosition()==0)OpenOnClosedCandle(color);
   }
  }
  UpdateLines();
 }
 ShowStatus();
}
void OnDeinit(const int reason)
{
 Comment("");
 ObjectDelete(0,gPrefix+"ENTRY");
 ObjectDelete(0,gPrefix+"SL");
 ObjectDelete(0,gPrefix+"CANDLE4");
}
