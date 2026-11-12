//+------------------------------------------------------------------+
//| PLASA M15 CANDLE CYCLE v1.01                                      |
//| Brand-new strategy: candle color cycle, multi-position SL ladder. |
//| Demo / Strategy Tester only. No take profit in this version.      |
//+------------------------------------------------------------------+
#property strict
#property version "1.01"
#property description "M15 candle cycle, chained SL to newest position stop, opposite candle protection. DEMO/TESTER."
#include <Trade/Trade.mqh>

input double InpLots             = 0.01;
input double InpPipSize          = 0.10;   // XAUUSD: 1 pip = 0.10 price units
input int    InpInitialSLPips    = 50;
input int    InpSameColorStep    = 10;     // Legacy setting, unused: same color uses chained stops
input int    InpOppositeStep1    = 25;     // Tighten on first opposite M15
input int    InpOppositeStep2    = 50;     // Tighten on second opposite M15
input int    InpMaxPositions     = 10;     // Safety cap; adjustable
input ulong  InpMagic            = 26111290;
input bool   InpDemoOnly         = true;
input bool   InpEnableTrading    = true;
input int    InpDeviationPoints  = 30;
input bool   InpShowChartLines   = true;
input bool   InpShowCandleLabels = true;

CTrade trade;
datetime g_lastBar=0;
int g_streakSide=0,g_streakCount=0;
int g_cycleSide=0,g_oppositeCount=0,g_waitFourthSide=0;
bool g_needClose=false;
int g_closeSide=0;
string g_action="Waiting for first completed M15 candle";
string g_prefix="";

string SideName(int side){return side>0?"BUY":side<0?"SELL":"NONE";}
bool ResultDone()
{
 uint c=trade.ResultRetcode();
 return c==TRADE_RETCODE_DONE || c==TRADE_RETCODE_DONE_PARTIAL;
}
bool Owned(ulong ticket)
{
 if(ticket==0||!PositionSelectByTicket(ticket))return false;
 return PositionGetString(POSITION_SYMBOL)==_Symbol &&
        (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic;
}
int CountOwned(int &buys,int &sells)
{
 buys=0;sells=0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong t=PositionGetTicket(i);
  if(!Owned(t))continue;
  if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)buys++;
  else sells++;
 }
 return buys+sells;
}
double FloatingProfit()
{
 double sum=0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong t=PositionGetTicket(i);
  if(Owned(t))sum+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
 }
 return sum;
}
bool CanTrade()
{
 return InpEnableTrading &&
        TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) &&
        MQLInfoInteger(MQL_TRADE_ALLOWED);
}
double RoundStop(double value,int side)
{
 double step=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
 if(step<=0)step=_Point;
 double rounded=side>0?MathFloor(value/step)*step:MathCeil(value/step)*step;
 return NormalizeDouble(rounded,_Digits);
}
bool StopAllowed(double sl,int side,const MqlTick &q)
{
 double minStop=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
 double freeze=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)*_Point;
 double safety=MathMax(minStop,freeze)+_Point;
 return side>0?sl<q.bid-safety:sl>q.ask+safety;
}
bool OpenPosition(int side)
{
 if(!CanTrade()){g_action="BLOCKED: algo trading disabled";return false;}
 int buy,sell;
 int count=CountOwned(buy,sell);
 if(count>=InpMaxPositions){g_action="WAIT: maximum positions reached";return false;}
 if((side>0 && sell>0)||(side<0 && buy>0))
 {g_action="BLOCKED: opposite positions still open";return false;}
 MqlTick q;
 if(!SymbolInfoTick(_Symbol,q)||q.ask<=0||q.bid<=0)
 {g_action="BLOCKED: no valid quote";return false;}
 double entry=side>0?q.ask:q.bid;
 double sl=RoundStop(entry+(side>0?-1.0:1.0)*InpInitialSLPips*InpPipSize,side);
 if(!StopAllowed(sl,side,q))
 {g_action="BLOCKED: 50-pip SL too close for spread/broker";return false;}
 bool sent=side>0?
      trade.Buy(InpLots,_Symbol,0.0,sl,0.0,"PLASA M15 cycle BUY"):
      trade.Sell(InpLots,_Symbol,0.0,sl,0.0,"PLASA M15 cycle SELL");
 if(sent && ResultDone())
 {
  // Existing same-direction positions adopt the NEWEST position's SL,
  // provided it is more protective and broker permits the modification.
  int moved=0;
  int skipped=0;
  ulong newestTicket=0;
  long newestTime=-1;
  for(int i=PositionsTotal()-1;i>=0;i--)
  {
    ulong ticket=PositionGetTicket(i);
    if(!Owned(ticket))continue;
    int ps=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1;
    if(ps!=side)continue;
    long openedAt=PositionGetInteger(POSITION_TIME_MSC);
    if(openedAt>newestTime || (openedAt==newestTime && ticket>newestTicket))
    {newestTime=openedAt;newestTicket=ticket;}
  }
  // Use the actual server SL of the new position as the chain reference.
  if(newestTicket!=0 && PositionSelectByTicket(newestTicket))
  {
    double chainSL=PositionGetDouble(POSITION_SL);
    MqlTick current;
    if(chainSL>0.0 && SymbolInfoTick(_Symbol,current))
    {
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
        ulong ticket=PositionGetTicket(i);
        if(ticket==newestTicket || !Owned(ticket))continue;
        int ps=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1;
        if(ps!=side)continue;
        double old=PositionGetDouble(POSITION_SL);
        if(old>0 && (side>0?chainSL<=old+_Point*0.1:chainSL>=old-_Point*0.1))
        {skipped++;continue;}
        if(!StopAllowed(chainSL,side,current)){skipped++;continue;}
        double tp=PositionGetDouble(POSITION_TP);
        if(trade.PositionModify(ticket,chainSL,tp)&&ResultDone())moved++;
        else {skipped++;PrintFormat("CHAIN SL failed #%I64u: %s",ticket,trade.ResultRetcodeDescription());}
      }
    }
  }
  g_action=StringFormat("%s %.2f lots opened | SL %.2f | CHAIN: %d updated, %d skipped",SideName(side),InpLots,sl,moved,skipped);
  Print("PLASA M15: ",g_action);
  return true;
 }
 g_action="OPEN FAILED: "+trade.ResultRetcodeDescription();
 Print("PLASA M15: ",g_action);
 return false;
}
// A step moves an existing stop TOWARDS price by N pips from its
// last SL, never backwards. If broker constraints disallow it,
// skip; do not widen or remove protection.
void TightenStops(int stepPips)
{
 if(stepPips<=0||!CanTrade())return;
 MqlTick q;
 if(!SymbolInfoTick(_Symbol,q))return;
 int moved=0,skipped=0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong ticket=PositionGetTicket(i);
  if(!Owned(ticket))continue;
  int side=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1;
  double oldSL=PositionGetDouble(POSITION_SL);
  double tp=PositionGetDouble(POSITION_TP);
  if(oldSL<=0){skipped++;continue;}
  double newSL=RoundStop(oldSL+(side>0?1.0:-1.0)*stepPips*InpPipSize,side);
  if((side>0 && newSL<=oldSL)||(side<0 && newSL>=oldSL))continue;
  if(!StopAllowed(newSL,side,q)){skipped++;continue;}
  if(trade.PositionModify(ticket,newSL,tp)&&ResultDone())moved++;
  else
  {
   skipped++;
   PrintFormat("SL modify failed #%I64u: %s",ticket,trade.ResultRetcodeDescription());
  }
 }
 g_action=StringFormat("SL tighten %dp: %d updated, %d skipped",stepPips,moved,skipped);
}
bool CloseAllPositions()
{
 if(!CanTrade()){g_action="BLOCKED: cannot close without Algo Trading";return false;}
 bool allOK=true;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong t=PositionGetTicket(i);
  if(!Owned(t))continue;
  if(!trade.PositionClose(t)||!ResultDone())
  {
   allOK=false;
   PrintFormat("Close failed #%I64u: %s",t,trade.ResultRetcodeDescription());
  }
 }
 int buys,sells;
 return allOK && CountOwned(buys,sells)==0;
}
void ContinueClose()
{
 if(!g_needClose)return;
 if(!CloseAllPositions()){g_action="CLOSE RETRY: still closing cycle";return;}
 g_needClose=false;
 g_cycleSide=0;
 g_oppositeCount=0;
 g_waitFourthSide=g_closeSide;
 g_closeSide=0;
 g_action="CLOSED on 3rd opposite candle; wait for 4th";
}
void DrawM15Label(const MqlRates &bar,int side)
{
 if(!InpShowCandleLabels)return;
 string name=g_prefix+"BAR_"+IntegerToString((long)bar.time);
 if(ObjectFind(0,name)<0)ObjectCreate(0,name,OBJ_TEXT,0,bar.time,bar.high+20*InpPipSize);
 ObjectSetString(0,name,OBJPROP_TEXT,
     StringFormat("%s %d",side>0?"GREEN":"RED",g_streakCount));
 ObjectSetInteger(0,name,OBJPROP_COLOR,side>0?clrLime:clrTomato);
 ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
 ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LOWER);
 ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
}
void RemovePositionLines()
{
 for(int i=ObjectsTotal(0,0,-1)-1;i>=0;i--)
 {
  string name=ObjectName(0,i,0,-1);
  if(StringFind(name,g_prefix+"ENTRY_")==0 ||
     StringFind(name,g_prefix+"STOP_")==0)
     ObjectDelete(0,name);
 }
}
void PositionLines()
{
 if(!InpShowChartLines)return;
 RemovePositionLines();
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong ticket=PositionGetTicket(i);
  if(!Owned(ticket))continue;
  double entry=PositionGetDouble(POSITION_PRICE_OPEN);
  double sl=PositionGetDouble(POSITION_SL);
  bool buy=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY;
  string id=IntegerToString((long)ticket);
  string entryName=g_prefix+"ENTRY_"+id;
  string stopName=g_prefix+"STOP_"+id;
  ObjectCreate(0,entryName,OBJ_HLINE,0,0,entry);
  ObjectSetInteger(0,entryName,OBJPROP_COLOR,buy?clrLime:clrTomato);
  ObjectSetInteger(0,entryName,OBJPROP_STYLE,STYLE_DOT);
  ObjectSetInteger(0,entryName,OBJPROP_WIDTH,1);
  ObjectSetString(0,entryName,OBJPROP_TOOLTIP,
     StringFormat("%s #%s ENTRY %.2f",buy?"BUY":"SELL",id,entry));
  if(sl>0)
  {
   ObjectCreate(0,stopName,OBJ_HLINE,0,0,sl);
   ObjectSetInteger(0,stopName,OBJPROP_COLOR,clrOrange);
   ObjectSetInteger(0,stopName,OBJPROP_WIDTH,2);
   ObjectSetString(0,stopName,OBJPROP_TOOLTIP,
      StringFormat("#%s STOP %.2f",id,sl));
  }
 }
 ChartRedraw(0);
}
void DisplayStatus()
{
 int buys,sells;
 int positions=CountOwned(buys,sells);
 datetime next=iTime(_Symbol,PERIOD_M15,0)+PeriodSeconds(PERIOD_M15);
 int remaining=(int)(next-TimeCurrent());
 if(remaining<0)remaining=0;
 string msg="PLASA | M15 CANDLE CYCLE 1.00\n";
 msg+=StringFormat("M15 closes: %s | %02d:%02d left (server)\n",
                 TimeToString(next,TIME_DATE|TIME_MINUTES),remaining/60,remaining%60);
 msg+=StringFormat("LAST CANDLE STREAK: %s %d\n",SideName(g_streakSide),g_streakCount);
 msg+=StringFormat("ACTIVE: %s | OPPOSITE %d/3 | FOURTH WAIT: %s\n",
       SideName(g_cycleSide),g_oppositeCount,SideName(g_waitFourthSide));
 msg+=StringFormat("POSITIONS: %d (BUY %d/SELL %d) | FLOAT $%.2f\n",
       positions,buys,sells,FloatingProfit());
 msg+=StringFormat("SL: initial %dp | NEW SL -> older SL | opposite 1:%dp 2:%dp\n",
       InpInitialSLPips,InpOppositeStep1,InpOppositeStep2);
 msg+="NEXT ACTION: "+g_action+"\n";
 msg+="CHAIN: older positions follow newest SL when tighter\n";
 msg+="ENTRY lines: green/red dotted | SL lines: orange solid\n";
 msg+="DEMO / TESTER ONLY | no TP";
 Comment(msg);
}
int OnInit()
{
 if(InpLots<=0||InpPipSize<=0||InpInitialSLPips<=0||
    InpSameColorStep<0||InpOppositeStep1<0||InpOppositeStep2<0||
    InpMaxPositions<1)return INIT_PARAMETERS_INCORRECT;
 if(InpDemoOnly&&!MQLInfoInteger(MQL_TESTER)&&
    AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO)
 {Print("PLASA M15: demo/tester only");return INIT_FAILED;}
 if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
 {Print("PLASA M15: hedging account required");return INIT_FAILED;}
 if(StringFind(_Symbol,"XAUUSD")!=0)
 {Print("PLASA M15: select XAUUSD / broker suffix");return INIT_FAILED;}
 double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
 double minVol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
 if(step<=0||InpLots<minVol||
    MathAbs(InpLots/step-MathRound(InpLots/step))>0.00001)
 {Print("PLASA M15: invalid lot for broker");return INIT_PARAMETERS_INCORRECT;}
 trade.SetExpertMagicNumber(InpMagic);
 trade.SetDeviationInPoints(InpDeviationPoints);
 trade.SetTypeFillingBySymbol(_Symbol);
 g_prefix="PLASA_M15_"+IntegerToString((long)InpMagic)+"_";
 g_lastBar=iTime(_Symbol,PERIOD_M15,0);
 DisplayStatus();
 Print("PLASA M15 Candle Cycle v1.01: newest position SL chains older stops");
 return INIT_SUCCEEDED;
}
void ProcessM15()
{
 MqlRates b[];
 ArraySetAsSeries(b,true);
 if(CopyRates(_Symbol,PERIOD_M15,1,1,b)!=1)return;
 int side=b[0].close>b[0].open?1:b[0].close<b[0].open?-1:0;
 if(side==0)
 {
  g_streakSide=0;g_streakCount=0;
  g_action="DOJI M15: no candle color, no action";
  return;
 }
 if(side==g_streakSide)g_streakCount++;
 else{g_streakSide=side;g_streakCount=1;}
 DrawM15Label(b[0],side);
 if(g_needClose)
 {
  ContinueClose();
  if(g_needClose)return;
 }
 if(g_cycleSide==0)
 {
  if(g_waitFourthSide!=0)
  {
   if(g_waitFourthSide==side && g_streakCount==4)
   {
    if(OpenPosition(side))
    {g_cycleSide=side;g_waitFourthSide=0;g_oppositeCount=0;}
    return;
   }
   if(side!=g_waitFourthSide)g_waitFourthSide=0;
   else {g_action="WAIT: fourth same-color M15";return;}
  }
  if(g_streakCount>=2 && OpenPosition(side))
  {g_cycleSide=side;g_oppositeCount=0;}
  return;
 }
 if(side==g_cycleSide)
 {
  g_oppositeCount=0;
  // No fixed 10-pip step on same color: the newest trade SL is the chain level.
  OpenPosition(side);
  return;
 }
 g_oppositeCount++;
 if(g_oppositeCount==1)
 {
  TightenStops(InpOppositeStep1);
  g_action="First opposite M15: SL tighter by 25 pips";
 }
 else if(g_oppositeCount==2)
 {
  TightenStops(InpOppositeStep2);
  g_action="Second opposite M15: SL tighter by 50 pips";
 }
 else
 {
  g_needClose=true;
  g_closeSide=side;
  ContinueClose();
 }
}
void OnTick()
{
 if(g_needClose)ContinueClose();
 datetime now=iTime(_Symbol,PERIOD_M15,0);
 if(now!=0 && now!=g_lastBar)
 {
  g_lastBar=now;
  ProcessM15();
  PositionLines();
 }
 DisplayStatus();
}
void OnDeinit(const int reason)
{
 Comment("");
 RemovePositionLines();
}
