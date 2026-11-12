//+------------------------------------------------------------------+
//| PLASA H1 SWING HUNTER v1.03                                       |
//| New independent EA: confirmed H1 swings -> M15 candle confirmation |
//| XAUUSD, hedging, demo/tester only.                                |
//+------------------------------------------------------------------+
#property strict
#property version "1.03"
#property description "Early H1 swing (one right bar), M15 rejection confirmation after touch, M15 add-ons, SL150 trailing."
#include <Trade/Trade.mqh>

input double InpLots                 = 0.01;
input double InpPipSize              = 0.10;  // XAUUSD pip definition
input int    InpInitialSLPips        = 150;   // Initial SL, adjustable
input int    InpH1Lookback           = 60;    // Historical H1 bars scanned
input int    InpSwingStrength        = 1;     // One CLOSED H1 bar on each side for earlier confirmed swing
input double InpEqualTolerancePips   = 30.0;  // Equal-high/low matching tolerance
input double InpTouchTolerancePips   = 20.0;  // Distance from confirmed H1 level
input int    InpConfirmExpiryM15      = 4;     // Expiry after touch in M15 bars
input int    InpMaxPositions         = 5;
input int    InpTrailActivationPips  = 50;    // Start profit protection
input int    InpTrailDistancePips    = 45;    // Distance behind favorable quote
input int    InpTrailStepPips        = 10;    // Minimum change before updating SL
input double InpMaxOpenStopRiskUSD   = 100.0; // Aggregate potential loss to current stops
input ulong  InpMagic               = 26111298;
input bool   InpDemoOnly            = true;
input bool   InpEnableTrading       = true;
input bool   InpShowChart           = true;

CTrade tr;
datetime gLastH1=0,gLastM15=0;
datetime gHighTime=0,gLowTime=0;
double gHigh=0,gLow=0;
bool gEqualHigh=false,gEqualLow=false;
datetime gUsedHigh=0,gUsedLow=0;
int gPendingSide=0;
datetime gPendingTouch=0,gPendingLevelTime=0;
double gPendingLevel=0;
int gActiveSide=0;
datetime gLastEntryM15=0;
string gAction="Scanning confirmed H1 swings";
string gPrefix="PLASA_H1M15_";

string Direction(const int side){return side>0?"BUY":side<0?"SELL":"WAIT";}
bool Done(){uint x=tr.ResultRetcode();return x==TRADE_RETCODE_DONE || x==TRADE_RETCODE_DONE_PARTIAL;}
bool Own(const ulong ticket)
{
 if(ticket==0 || !PositionSelectByTicket(ticket))return false;
 return PositionGetString(POSITION_SYMBOL)==_Symbol &&
        (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic;
}
int CountPositions(int &buys,int &sells)
{
 buys=0;sells=0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong ticket=PositionGetTicket(i);
  if(!Own(ticket))continue;
  if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)buys++;
  else sells++;
 }
 return buys+sells;
}
bool TradeEnabled()
{
 return InpEnableTrading &&
    TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) &&
    MQLInfoInteger(MQL_TRADE_ALLOWED);
}
double TickRound(const double price,const int side)
{
 double step=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
 if(step<=0.0)step=_Point;
 return NormalizeDouble((side>0?MathFloor(price/step):MathCeil(price/step))*step,_Digits);
}
bool ValidSL(const int side,const double sl,const MqlTick &q)
{
 double minD=MathMax((double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),
                     (double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL))*_Point+_Point;
 return side>0?sl<q.bid-minD:sl>q.ask+minD;
}
string LevelKey(const string direction)
{
 return StringFormat("P_H1_%I64d_%s_%I64u_%s",
    AccountInfoInteger(ACCOUNT_LOGIN),_Symbol,InpMagic,direction);
}
void LoadUsedLevels()
{
 string a=LevelKey("HIGH"),b=LevelKey("LOW");
 if(GlobalVariableCheck(a))gUsedHigh=(datetime)(long)GlobalVariableGet(a);
 if(GlobalVariableCheck(b))gUsedLow=(datetime)(long)GlobalVariableGet(b);
}
void UseLevel(const int side,const datetime bar)
{
 if(side<0){gUsedHigh=bar;GlobalVariableSet(LevelKey("HIGH"),(double)(long)bar);}
 else {gUsedLow=bar;GlobalVariableSet(LevelKey("LOW"),(double)(long)bar);}
}
void HLine(const string key,const double price,const color c,const int style)
{
 if(!InpShowChart)return;
 string id=gPrefix+key;
 if(ObjectFind(0,id)<0)ObjectCreate(0,id,OBJ_HLINE,0,0,price);
 else ObjectMove(0,id,0,0,price);
 ObjectSetInteger(0,id,OBJPROP_COLOR,c);
 ObjectSetInteger(0,id,OBJPROP_STYLE,style);
 ObjectSetInteger(0,id,OBJPROP_WIDTH,2);
 ObjectSetInteger(0,id,OBJPROP_SELECTABLE,false);
}
void UpdateLevelLines()
{
 if(gHigh>0)HLine("H1_HIGH",gHigh,clrTomato,STYLE_SOLID);
 if(gLow>0)HLine("H1_LOW",gLow,clrLime,STYLE_SOLID);
}
void PositionLines()
{
 if(!InpShowChart)return;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong t=PositionGetTicket(i);
  if(!Own(t))continue;
  string id=IntegerToString((long)t);
  int side=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1;
  HLine("ENTRY_"+id,PositionGetDouble(POSITION_PRICE_OPEN),
        side>0?clrLime:clrTomato,STYLE_DOT);
  double sl=PositionGetDouble(POSITION_SL);
  if(sl>0)HLine("STOP_"+id,sl,clrOrange,STYLE_DASH);
 }
 // Prune only obsolete ticket lines, once per M15 event.
 for(int i=ObjectsTotal(0,0,-1)-1;i>=0;i--)
 {
  string name=ObjectName(0,i,0,-1);
  int offset=-1;
  if(StringFind(name,gPrefix+"ENTRY_")==0)offset=StringLen(gPrefix)+6;
  else if(StringFind(name,gPrefix+"STOP_")==0)offset=StringLen(gPrefix)+5;
  if(offset<0)continue;
  ulong ticket=(ulong)StringToInteger(StringSubstr(name,offset));
  if(!Own(ticket))ObjectDelete(0,name);
 }
}
bool IsHighSwing(MqlRates &bars[],const int k,const int n)
{
 for(int j=1;j<=n;j++)
 {
  if(bars[k].high<=bars[k-j].high || bars[k].high<=bars[k+j].high)return false;
 }
 return true;
}
bool IsLowSwing(MqlRates &bars[],const int k,const int n)
{
 for(int j=1;j<=n;j++)
 {
  if(bars[k].low>=bars[k-j].low || bars[k].low>=bars[k+j].low)return false;
 }
 return true;
}
// Find last confirmed swing levels from CLOSED H1 candles only.
// An equal-high/low label is marked if another confirmed swing exists
// within InpEqualTolerancePips. These are zones, not exact-identical quotes.
void RefreshH1Levels()
{
 int count=InpH1Lookback+InpSwingStrength+1;
 MqlRates b[];
 ArraySetAsSeries(b,true);
 if(CopyRates(_Symbol,PERIOD_H1,1,count,b)!=count)
 {gAction="WAIT: insufficient H1 history";return;}
 double newHigh=0,newLow=0;
 datetime highTime=0,lowTime=0;
 bool eqHigh=false,eqLow=false;
 for(int k=InpSwingStrength;k<count-InpSwingStrength;k++)
 {
  if(IsHighSwing(b,k,InpSwingStrength))
  {
   if(newHigh==0){newHigh=b[k].high;highTime=b[k].time;}
   else if(MathAbs(newHigh-b[k].high)<=InpEqualTolerancePips*InpPipSize)eqHigh=true;
  }
  if(IsLowSwing(b,k,InpSwingStrength))
  {
   if(newLow==0){newLow=b[k].low;lowTime=b[k].time;}
   else if(MathAbs(newLow-b[k].low)<=InpEqualTolerancePips*InpPipSize)eqLow=true;
  }
 }
 if(newHigh>0){gHigh=newHigh;gHighTime=highTime;gEqualHigh=eqHigh;}
 if(newLow>0){gLow=newLow;gLowTime=lowTime;gEqualLow=eqLow;}
 UpdateLevelLines();
}
double NegativeStopRisk()
{
 double total=0.0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong t=PositionGetTicket(i);
  if(!Own(t))continue;
  double sl=PositionGetDouble(POSITION_SL),p=0.0;
  if(sl<=0){total+=InpMaxOpenStopRiskUSD;continue;}
  ENUM_ORDER_TYPE type=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?
                        ORDER_TYPE_BUY:ORDER_TYPE_SELL;
  if(!OrderCalcProfit(type,_Symbol,PositionGetDouble(POSITION_VOLUME),
             PositionGetDouble(POSITION_PRICE_OPEN),sl,p))
  {total+=InpMaxOpenStopRiskUSD;continue;}
  if(p<0)total-=p;
 }
 return total;
}
bool OpenTrade(const int side,const datetime m15BarTime)
{
 if(!TradeEnabled()){gAction="WAIT: Algo Trading disabled";return false;}
 int buys,sells;
 if(CountPositions(buys,sells)>=InpMaxPositions)
 {gAction="WAIT: max positions reached";return false;}
 if((side>0&&sells>0)||(side<0&&buys>0))
 {gAction="WAIT: opposite basket still active";return false;}
 MqlTick q;
 if(!SymbolInfoTick(_Symbol,q)||q.bid<=0||q.ask<=0)return false;
 double entry=side>0?q.ask:q.bid;
 double sl=TickRound(entry+(side>0?-1.0:1.0)*InpInitialSLPips*InpPipSize,side);
 if(!ValidSL(side,sl,q)){gAction="WAIT: SL too close for broker";return false;}
 double risk=0;
 if(!OrderCalcProfit(side>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL,
                    _Symbol,InpLots,entry,sl,risk))return false;
 if(NegativeStopRisk()+MathMax(0.0,-risk)>InpMaxOpenStopRiskUSD)
 {gAction="WAIT: stop-risk budget reached";return false;}
 bool sent=side>0?tr.Buy(InpLots,_Symbol,0,sl,0,"H1 swing M15 BUY"):
                  tr.Sell(InpLots,_Symbol,0,sl,0,"H1 swing M15 SELL");
 if(sent&&Done())
 {
  gActiveSide=side;
  gLastEntryM15=m15BarTime;
  gAction=StringFormat("OPEN %s at M15 confirmation | SL %.2f",Direction(side),sl);
  Print("PLASA SWING ",gAction);
  return true;
 }
 gAction="ORDER FAILED: "+tr.ResultRetcodeDescription();
 return false;
}
// Profit-only stepped trailing, never widens old stops.
// Cheap check each tick, no history scans or chart redraw.
void TrailStops()
{
 MqlTick q;
 if(!SymbolInfoTick(_Symbol,q))return;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong ticket=PositionGetTicket(i);
  if(!Own(ticket))continue;
  int side=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1;
  double price=side>0?q.bid:q.ask;
  double entry=PositionGetDouble(POSITION_PRICE_OPEN);
  double advance=(side>0?price-entry:entry-price)/InpPipSize;
  if(advance<InpTrailActivationPips)continue;
  double candidate=TickRound(price+(side>0?-1.0:1.0)*InpTrailDistancePips*InpPipSize,side);
  double previous=PositionGetDouble(POSITION_SL);
  // Require SL beyond entry to protect realized potential profit.
  if(!(side>0?candidate>entry:candidate<entry))continue;
  if(previous>0 && (side>0?candidate<previous+InpTrailStepPips*InpPipSize:
                             candidate>previous-InpTrailStepPips*InpPipSize))continue;
  if(!ValidSL(side,candidate,q))continue;
  if(!tr.PositionModify(ticket,candidate,PositionGetDouble(POSITION_TP))||!Done())
    PrintFormat("TRAIL ERROR #%I64u: %s",ticket,tr.ResultRetcodeDescription());
 }
}
void DetectTouch()
{
 if(gPendingSide!=0)return;
 int buys,sells;
 if(CountPositions(buys,sells)>0)return;
 MqlTick q;
 if(!SymbolInfoTick(_Symbol,q)||q.bid<=0||q.ask<=0)return;
 double midpoint=(q.bid+q.ask)*0.5;
 double tol=InpTouchTolerancePips*InpPipSize;
 bool highTouch=gHigh>0 && gHighTime>gUsedHigh && MathAbs(midpoint-gHigh)<=tol;
 bool lowTouch=gLow>0 && gLowTime>gUsedLow && MathAbs(midpoint-gLow)<=tol;
 if(highTouch && lowTouch)return; // Ambiguous: no directional choice
 if(highTouch)
 {
  gPendingSide=-1;gPendingTouch=TimeCurrent();gPendingLevelTime=gHighTime;gPendingLevel=gHigh;
  gAction=StringFormat("H1 HIGH %.2f TOUCHED: waiting RED M15",gHigh);
 }
 else if(lowTouch)
 {
  gPendingSide=1;gPendingTouch=TimeCurrent();gPendingLevelTime=gLowTime;gPendingLevel=gLow;
  gAction=StringFormat("H1 LOW %.2f TOUCHED: waiting GREEN M15",gLow);
 }
}
void NewM15Closed()
{
 MqlRates h[];
 ArraySetAsSeries(h,true);
 if(CopyRates(_Symbol,PERIOD_M15,1,2,h)!=2)return;
 int side=h[0].close>h[0].open?1:h[0].close<h[0].open?-1:0;
 datetime lastClose=h[0].time+PeriodSeconds(PERIOD_M15);
 int buys,sells;
 int total=CountPositions(buys,sells);
 if(total>0)
 {
  gPendingSide=0; // Do not open opposing signal while positions exist.
  gActiveSide=buys>0?1:-1;
  // Add only when M15 closed in direction, with progressing close.
  bool progress=gActiveSide>0?h[0].close>h[1].close:h[0].close<h[1].close;
  if(side==gActiveSide && progress && h[0].time>gLastEntryM15)
     OpenTrade(gActiveSide,h[0].time);
  else gAction="M15 closed: no qualifying same-direction addition";
  return;
 }
 gActiveSide=0;
 if(gPendingSide==0)return;
 // Early reaction: permit the just-closed M15 candle to confirm,
 // provided it CLOSED after the touch. This may be the same M15 bar
 // in which the H1 level was touched; the candle is never unfinished.
 if(lastClose<=gPendingTouch)return;
 if(lastClose-gPendingTouch>InpConfirmExpiryM15*PeriodSeconds(PERIOD_M15))
 {
  gAction="M15 confirmation expired; wait new H1 touch";
  UseLevel(gPendingSide,gPendingLevelTime);
  gPendingSide=0;
  return;
 }
 if(side==gPendingSide)
 {
  int desired=gPendingSide;
  if(OpenTrade(desired,h[0].time))
  {
   UseLevel(desired,gPendingLevelTime); // Each confirmed level once
   gPendingSide=0;
  }
 }
 else gAction=StringFormat("H1 level touched: waiting %s M15 candle",Direction(gPendingSide));
}
void ShowStatus()
{
 if(!InpShowChart)return;
 int buys,sells;
 int total=CountPositions(buys,sells);
 double profit=0.0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong t=PositionGetTicket(i);
  if(Own(t))profit+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
 }
 string msg="PLASA H1 SWING HUNTER v1.03\n";
 msg+=StringFormat("H1 HIGH %.2f %s | H1 LOW %.2f %s\n",
   gHigh,gEqualHigh?"EQUAL HIGHS":"SWING",gLow,gEqualLow?"EQUAL LOWS":"SWING");
 msg+=StringFormat("ACTIVE %s | POS %d/%d | BUY %d SELL %d | FLOAT $%.2f\n",
   Direction(gActiveSide),total,InpMaxPositions,buys,sells,profit);
 msg+=StringFormat("TOUCH: %s %.2f | WAIT M15 %s\n",
   Direction(gPendingSide),gPendingLevel,Direction(gPendingSide));
 msg+=StringFormat("TRAIL: activate %d p | distance %d p | step %d p\n",
   InpTrailActivationPips,InpTrailDistancePips,InpTrailStepPips);
 msg+="ACTION: "+gAction+"\n";
 msg+="RED/GREEN = H1 levels | dotted entry | orange stop\n";
 msg+="DEMO/TESTER ONLY";
 Comment(msg);
}
int OnInit()
{
 if(InpLots<=0||InpPipSize<=0||InpInitialSLPips<=0||
    InpH1Lookback<10||InpSwingStrength<1||InpH1Lookback<InpSwingStrength*2+3||
    InpEqualTolerancePips<0||InpTouchTolerancePips<=0||
    InpConfirmExpiryM15<1||InpMaxPositions<1||InpTrailActivationPips<1||
    InpTrailDistancePips<1||InpTrailStepPips<1||InpMaxOpenStopRiskUSD<=0)
   return INIT_PARAMETERS_INCORRECT;
 if(InpDemoOnly&&!MQLInfoInteger(MQL_TESTER)&&
    AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO)
 {Print("PLASA SWING: demo/tester only");return INIT_FAILED;}
 if(StringFind(_Symbol,"XAUUSD")!=0)
 {Print("PLASA SWING: XAUUSD only");return INIT_FAILED;}
 if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
 {Print("PLASA SWING: hedging required");return INIT_FAILED;}
 double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
 double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
 double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
 if(step<=0||InpLots<mn||InpLots>mx||
    MathAbs(InpLots/step-MathRound(InpLots/step))>0.00001)
 {Print("PLASA SWING: invalid volume");return INIT_PARAMETERS_INCORRECT;}
 tr.SetExpertMagicNumber(InpMagic);
 tr.SetDeviationInPoints(30);
 tr.SetTypeFillingBySymbol(_Symbol);
 gPrefix="PLASA_SWING_"+IntegerToString((long)InpMagic)+"_";
 LoadUsedLevels();
 gLastH1=iTime(_Symbol,PERIOD_H1,0);
 gLastM15=iTime(_Symbol,PERIOD_M15,0);
 RefreshH1Levels();
 ShowStatus();
 return INIT_SUCCEEDED;
}
void OnTick()
{
 TrailStops();
 datetime h1=iTime(_Symbol,PERIOD_H1,0);
 datetime m15=iTime(_Symbol,PERIOD_M15,0);
 bool changed=false;
 if(h1>0&&h1!=gLastH1)
 {
  gLastH1=h1;
  RefreshH1Levels();
  changed=true;
 }
 if(m15>0&&m15!=gLastM15)
 {
  gLastM15=m15;
  NewM15Closed();
  PositionLines();
  changed=true;
 }
 DetectTouch();
 if(changed)ShowStatus();
}
void OnDeinit(const int reason)
{
 Comment("");
 for(int i=ObjectsTotal(0,0,-1)-1;i>=0;i--)
 {
  string name=ObjectName(0,i,0,-1);
  if(StringFind(name,gPrefix)==0)ObjectDelete(0,name);
 }
}
