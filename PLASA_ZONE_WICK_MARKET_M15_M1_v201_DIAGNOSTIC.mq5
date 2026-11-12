//+------------------------------------------------------------------+
//| PLASA ZONE + WICK BALANCE v2.01                                   |
//| 5 closed M1 wick sums + M15 Supply/Demand reaction areas          |
//| Independent research EA. TESTER / DEMO only.                     |
//| NOT an integration with the WOW Market indicator.                |
//+------------------------------------------------------------------+
#property strict
#property version "2.01"
#property description "DIAGNOSTIC M15 Market zones + 5 M1 wicks. No trading without installed Market indicator."
#include <Trade/Trade.mqh>

#property tester_indicator "Market\\Supply Demand Zones Base Impulse ATR.ex5"
input string InpMarketIndicatorName = "Market\\Supply Demand Zones Base Impulse ATR";
input double InpLots                 = 0.01;
input double InpPipSize              = 0.10; // XAUUSD: 1 pip = 0.10 price units
input double InpWickMinDiffPips      = 10.0;
input int    InpM1Bars              = 5;
input int    InpZoneValidM15Bars     = 48;   // 12h from first recorded closed M15 zone
input bool   InpShowWickCounts       = true;
input int    InpKeepCountGroups      = 20;
input double InpZoneTolerancePips   = 20.0; // Above and below M15 zone
input int    InpStopLossPips        = 100;
input double InpRiskReward          = 1.0; // TP 100 pips for SL 100
input int    InpMaxPositions        = 3;
input double InpMaxStopRiskUSD      = 100.0;
input bool   InpDemoOnly           = true;
input bool   InpEnableTrading      = true;
input bool   InpShowLines          = true;
input ulong  InpMagic              = 26111302;
input int    InpDeviationPoints    = 30;

CTrade tr;
int gExternal=INVALID_HANDLE;
int gIndicatorLoadError=0;
bool gIndicatorUnavailable=false;
datetime gM1Bar=0, gM15Bar=0;
int gCount=0;
double gUp=0.0,gDown=0.0;
double gSupplyHigh=0,gSupplyLow=0,gDemandHigh=0,gDemandLow=0;
datetime gSupplyTime=0,gDemandTime=0;
datetime gSupplyConfirmed=0,gDemandConfirmed=0;

double gLastUp=0.0,gLastDown=0.0;
int gLastSide=0;
string gLastDecision="WAIT: first five-M1 group";
string gStatus="WAIT: M15 zone history",gPrefix="";
int gWaitWicks=0,gWaitZones=0,gEntries=0;
bool gZoneReady=false;

bool Owned(ulong t)
{
 if(t==0 || !PositionSelectByTicket(t))return false;
 return PositionGetString(POSITION_SYMBOL)==_Symbol &&
        (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic;
}
bool Done()
{
 uint r=tr.ResultRetcode();
 return r==TRADE_RETCODE_DONE || r==TRADE_RETCODE_DONE_PARTIAL;
}
int MyCount(int &buys,int &sells)
{
 buys=0;sells=0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
   ulong ticket=PositionGetTicket(i);
   if(!Owned(ticket))continue;
   if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)buys++;
   else sells++;
 }
 return buys+sells;
}
double RiskAtStops()
{
 double r=0.0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong t=PositionGetTicket(i);
  if(!Owned(t))continue;
  double sl=PositionGetDouble(POSITION_SL);
  if(sl<=0){r+=InpMaxStopRiskUSD;continue;}
  ENUM_ORDER_TYPE direction=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?
     ORDER_TYPE_BUY:ORDER_TYPE_SELL;
  double p=0.0;
  if(!OrderCalcProfit(direction,_Symbol,PositionGetDouble(POSITION_VOLUME),
        PositionGetDouble(POSITION_PRICE_OPEN),sl,p))
   {r+=InpMaxStopRiskUSD;continue;}
  if(p<0)r-=p;
 }
 return r;
}
double StopPrice(const double price,const int side)
{
 double unit=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
 if(unit<=0)unit=_Point;
 return NormalizeDouble((side>0?MathFloor(price/unit):MathCeil(price/unit))*unit,_Digits);
}
bool AllowedSLTP(const int side,const double sl,const double tp,const MqlTick &q)
{
 double minimum=((double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL))*_Point+
       SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
 if(side>0)return sl<q.bid-minimum && tp>q.bid+minimum;
 return sl>q.ask+minimum && tp<q.ask-minimum;
}
// Real external Market indicator, with documented MT5 buffers:
// 0 demand top, 1 demand bottom, 2 demand touches,
// 3 supply top, 4 supply bottom, 5 supply touches.
// Read only completed M15 (shift=1). No substitute swing/ATR zones.
bool ExternalValue(int buffer,int shift,double &out)
{
 double v[];
 if(gExternal==INVALID_HANDLE || CopyBuffer(gExternal,buffer,shift,1,v)!=1)return false;
 out=v[0];
 if(!MathIsValidNumber(out))return false;
 if(out==EMPTY_VALUE)out=0.0;
 return true;
}
// Derive earliest closed-bar buffer appearance within the last 48 bars.
// Historical birth is approximate if the provider changes historical buffers.
// If history is insufficient, refuse the zone rather than misdate it.
datetime ZoneBorn(int topBuf,int bottomBuf,double top,double bottom)
{
 datetime born=0;
 double epsilon=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE)*0.5;
 if(epsilon<=0)epsilon=_Point*0.5;
 for(int shift=1;shift<=InpZoneValidM15Bars+1;shift++)
 {
  double a=0,b=0;
  if(!ExternalValue(topBuf,shift,a) || !ExternalValue(bottomBuf,shift,b))return 0;
  if(MathAbs(a-top)>epsilon || MathAbs(b-bottom)>epsilon)break;
  if(shift>InpZoneValidM15Bars)return 0;
  datetime t=iTime(_Symbol,PERIOD_M15,shift);
  if(t>0)born=t+PeriodSeconds(PERIOD_M15);
 }
 return born;
}
bool FromExternalZones()
{
 if(gExternal==INVALID_HANDLE)
 {
  gZoneReady=false;
  gStatus=StringFormat("NO TRADES: Market indicator not loaded (MT5 error %d)",gIndicatorLoadError);
  return false;
 }
 gSupplyHigh=0;gSupplyLow=0;gDemandHigh=0;gDemandLow=0;
 gSupplyConfirmed=0;gDemandConfirmed=0;
 if(gExternal==INVALID_HANDLE || BarsCalculated(gExternal)<InpZoneValidM15Bars+2)
 {gStatus="WAIT: external M15 zone buffers loading";return false;}
 double dt,db,dc,st,sb,sc;
 if(!ExternalValue(0,1,dt)||!ExternalValue(1,1,db)||!ExternalValue(2,1,dc)||
    !ExternalValue(3,1,st)||!ExternalValue(4,1,sb)||!ExternalValue(5,1,sc))
 {gStatus="WAIT: external zone buffers unavailable";return false;}
 if(dt>db && db>0)
 {
  datetime born=ZoneBorn(0,1,dt,db);
  if(born>0 && TimeCurrent()<born+InpZoneValidM15Bars*PeriodSeconds(PERIOD_M15))
  {gDemandHigh=dt;gDemandLow=db;gDemandConfirmed=born;}
 }
 if(st>sb && sb>0)
 {
  datetime born=ZoneBorn(3,4,st,sb);
  if(born>0 && TimeCurrent()<born+InpZoneValidM15Bars*PeriodSeconds(PERIOD_M15))
  {gSupplyHigh=st;gSupplyLow=sb;gSupplyConfirmed=born;}
 }
 if(gSupplyHigh==0&&gDemandHigh==0)
  gStatus="WAIT: no unbroken external zone younger than 12h";
 return gSupplyHigh>0||gDemandHigh>0;
}
// Draw M15 zones as filled rectangles, not just two horizontal lines.
// Box spans from confirmed zone to its lifetime expiry (6h by default).
void ZoneBox(string key,double low,double high,datetime confirmed,color tint)
{
 string name=gPrefix+"ZONE_"+key;
 string label=gPrefix+"ZONE_LABEL_"+key;
 if(!InpShowLines || low<=0 || high<=low || confirmed<=0)
 {
  ObjectDelete(0,name);ObjectDelete(0,label);
  return;
 }
 datetime until=confirmed+InpZoneValidM15Bars*PeriodSeconds(PERIOD_M15);
 if(until<=TimeCurrent()){ObjectDelete(0,name);ObjectDelete(0,label);return;}
 datetime left=confirmed;
 if(ObjectFind(0,name)<0)ObjectCreate(0,name,OBJ_RECTANGLE,0,left,high,until,low);
 else
 {
  ObjectMove(0,name,0,left,high);
  ObjectMove(0,name,1,until,low);
 }
 ObjectSetInteger(0,name,OBJPROP_COLOR,ColorToARGB(tint,65));
 ObjectSetInteger(0,name,OBJPROP_FILL,true);
 ObjectSetInteger(0,name,OBJPROP_BACK,true);
 ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
 ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
 // Label at zone middle, readable against chart.
 datetime labelTime=TimeCurrent();
 if(labelTime<left)labelTime=left;
 if(ObjectFind(0,label)<0)ObjectCreate(0,label,OBJ_TEXT,0,labelTime,(low+high)*0.5);
 else ObjectMove(0,label,0,labelTime,(low+high)*0.5);
 ObjectSetInteger(0,label,OBJPROP_COLOR,tint);
 ObjectSetInteger(0,label,OBJPROP_FONTSIZE,10);
 ObjectSetString(0,label,OBJPROP_TEXT,
    StringFormat("%s %.2f - %.2f | %dm left",key,low,high,
                 (int)MathMax(0,(until-TimeCurrent())/60)));
 ObjectSetInteger(0,label,OBJPROP_SELECTABLE,false);
}
void DrawZones()
{
 ZoneBox("SUPPLY",gSupplyLow,gSupplyHigh,gSupplyConfirmed,clrTomato);
 ZoneBox("DEMAND",gDemandLow,gDemandHigh,gDemandConfirmed,clrLimeGreen);
}
void CandleNumber(const MqlRates &bar,int number)
{
 if(!InpShowWickCounts)return;
 string name=gPrefix+"COUNT_"+IntegerToString((long)bar.time);
 if(ObjectFind(0,name)<0)
  ObjectCreate(0,name,OBJ_TEXT,0,bar.time,bar.high+12*InpPipSize);
 ObjectSetString(0,name,OBJPROP_TEXT,IntegerToString(number));
 ObjectSetInteger(0,name,OBJPROP_COLOR,number==5?clrGold:
     (bar.close>bar.open?clrLime:bar.close<bar.open?clrTomato:clrSilver));
 ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LOWER);
 ObjectSetInteger(0,name,OBJPROP_FONTSIZE,10);
 ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
}
void DecisionLabel(const MqlRates &bar)
{
 if(!InpShowWickCounts)return;
 string name=gPrefix+"DECISION_"+IntegerToString((long)bar.time);
 if(ObjectFind(0,name)<0)
  ObjectCreate(0,name,OBJ_TEXT,0,bar.time,bar.high+35*InpPipSize);
 ObjectSetString(0,name,OBJPROP_TEXT,StringFormat("%s %.0f/%.0f",
   gLastSide>0?"BUY":gLastSide<0?"SELL":"WAIT",gLastUp,gLastDown));
 ObjectSetInteger(0,name,OBJPROP_COLOR,
    gLastSide>0?clrLime:gLastSide<0?clrTomato:clrSilver);
 ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
 ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LOWER);
 ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
}
void PruneCountLabels()
{
 if(!InpShowWickCounts)return;
 datetime oldest=iTime(_Symbol,PERIOD_M1,InpKeepCountGroups*InpM1Bars);
 if(oldest<=0)return;
 for(int i=ObjectsTotal(0,0,-1)-1;i>=0;i--)
 {
  string name=ObjectName(0,i,0,-1);
  if(StringFind(name,gPrefix+"COUNT_")!=0 && StringFind(name,gPrefix+"DECISION_")!=0)continue;
  int pos=StringFind(name,gPrefix+"COUNT_")==0?StringLen(gPrefix)+6:StringLen(gPrefix)+9;
  datetime t=(datetime)(long)StringToInteger(StringSubstr(name,pos));
  if(t<oldest)ObjectDelete(0,name);
 }
}
bool RefreshZones()
{
 gZoneReady=FromExternalZones();
 DrawZones();
 return gZoneReady;
}
// The PRICE INTERSECTION must have happened in the same five CLOSED M1
// bars used for the wick signal, not many candles ago.
// Require current quote near or inside zone too, to prevent late chases.
bool MatchesZone(const int side,const MqlRates &five[],const MqlTick &q)
{
 double lo=side>0?gDemandLow:gSupplyLow;
 double hi=side>0?gDemandHigh:gSupplyHigh;
 if(lo<=0 || hi<=lo)return false;
 double tol=InpZoneTolerancePips*InpPipSize;
 bool touched=false;
 for(int i=0;i<InpM1Bars;i++)
  if(five[i].high>=lo-tol && five[i].low<=hi+tol){touched=true;break;}
 double price=side>0?q.ask:q.bid;
 return touched && price>=lo-tol && price<=hi+tol;
}
void ProcessWickGroup()
{
 MqlRates b[];
 ArraySetAsSeries(b,true);
 if(CopyRates(_Symbol,PERIOD_M1,1,InpM1Bars,b)!=InpM1Bars)
 {gStatus="WAIT: closed M1 candles unavailable";return;}
 double upper=0.0,lower=0.0;
 for(int i=0;i<InpM1Bars;i++)
 {
  upper+=MathMax(0.0,b[i].high-MathMax(b[i].open,b[i].close))/InpPipSize;
  lower+=MathMax(0.0,MathMin(b[i].open,b[i].close)-b[i].low)/InpPipSize;
 }
 gLastUp=upper;gLastDown=lower;
 int side=0;
 if(upper-lower>=InpWickMinDiffPips)side=-1;
 else if(lower-upper>=InpWickMinDiffPips)side=1;
 gLastSide=side;
 DecisionLabel(b[0]);
 gLastDecision=StringFormat("WICKS U %.1f D %.1f -> %s",
         upper,lower,side>0?"BUY":side<0?"SELL":"WAIT");
 if(side==0)
 {
  gWaitWicks++;
  gStatus=StringFormat("WAIT: wick UP %.1f / DOWN %.1f < %.1f diff",
                       upper,lower,InpWickMinDiffPips);
  return;
 }
 if(!gZoneReady && !RefreshZones())
 {
  gLastDecision+=" | BLOCKED: external indicator zones unavailable";
  return;
 }
 MqlTick q;
 if(!SymbolInfoTick(_Symbol,q) || q.bid<=0.0 || q.ask<=0.0)return;
 if(!MatchesZone(side,b,q))
 {
   gLastDecision+=" | BLOCKED: outside matching zone";
  gWaitZones++;
  gStatus=StringFormat("WAIT: %s wick signal; no matching M15 %s zone",
              side>0?"BUY":"SELL",side>0?"DEMAND":"SUPPLY");
  return;
 }
 if(!InpEnableTrading || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)||
    !MQLInfoInteger(MQL_TRADE_ALLOWED))
 {gStatus="SIGNAL CONFIRMED: MT5 Algo Trading is disabled";return;}
 int buys,sells,total=MyCount(buys,sells);
 if(total>=InpMaxPositions){gStatus="WAIT: max positions";return;}
 if((side>0&&sells>0)||(side<0&&buys>0))
 {gStatus="WAIT: opposite position basket active";return;}
 double entry=side>0?q.ask:q.bid;
 double riskDistance=InpStopLossPips*InpPipSize;
 double rewardDistance=riskDistance*InpRiskReward;
 double sl=StopPrice(entry+(side>0?-riskDistance:riskDistance),side);
 double tp=StopPrice(entry+(side>0?rewardDistance:-rewardDistance),-side);
 if(!AllowedSLTP(side,sl,tp,q))
 {gStatus="WAIT: broker stop level / spread prevents SL TP";return;}
 double loss=0.0;
 if(!OrderCalcProfit(side>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL,
            _Symbol,InpLots,entry,sl,loss))
 {gStatus="WAIT: OrderCalcProfit failed";return;}
 if(RiskAtStops()+MathMax(0.0,-loss)>InpMaxStopRiskUSD)
 {gStatus="WAIT: stop-risk budget exceeded";return;}
 bool success=side>0?tr.Buy(InpLots,_Symbol,0,sl,tp,"PLASA ZONE+WICK BUY"):
                     tr.Sell(InpLots,_Symbol,0,sl,tp,"PLASA ZONE+WICK SELL");
 if(success && Done())
 {
  gEntries++;
  gLastDecision+=" | ENTRY OPEN";
  gStatus=StringFormat("%s OPEN: 5 M1 wicks %.0f/%.0f | M15 zone | SL %.2f TP %.2f",
                        side>0?"BUY":"SELL",upper,lower,sl,tp);
 }
 else {gStatus="ORDER FAILED: "+tr.ResultRetcodeDescription();gLastDecision+=" | ORDER FAIL";}
 Print("PLASA ZONE WICK: ",gStatus);
}
void Display()
{
 int buys,sells,total=MyCount(buys,sells);
 double floating=0.0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong t=PositionGetTicket(i);
  if(Owned(t))floating+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
 }
 string mode="MT5 MARKET BASE IMPULSE ATR";
 string msg="PLASA | ZONE + WICK v2.01 DIAGNOSTIC\n";
 if(gIndicatorUnavailable)
   msg+=StringFormat("INDICATOR ERROR %d | no zone data | NO TRADES\n",gIndicatorLoadError);
 msg+=StringFormat("ZONE SOURCE: %s | READY %s\n",mode,gZoneReady?"YES":"NO");
 msg+=StringFormat("M15 SUPPLY: %.2f - %.2f | %dm left\n",
     gSupplyLow,gSupplyHigh,(int)MathMax(0,(gSupplyConfirmed+InpZoneValidM15Bars*900-TimeCurrent())/60));
 msg+=StringFormat("M15 DEMAND: %.2f - %.2f | %dm left\n",
     gDemandLow,gDemandHigh,(int)MathMax(0,(gDemandConfirmed+InpZoneValidM15Bars*900-TimeCurrent())/60));
 msg+=StringFormat("M1 GROUP %d/%d | MIN WICK DIFF %.1f pips\n",gCount,InpM1Bars,InpWickMinDiffPips);
 msg+=StringFormat("POSITIONS %d/%d B%d S%d | FLOAT $%.2f\n",total,InpMaxPositions,buys,sells,floating);
 msg+=StringFormat("WAIT WICKS %d | WAIT ZONES %d | ENTRIES %d\n",gWaitWicks,gWaitZones,gEntries);
 msg+="WICK DECISION: "+gLastDecision+"\n";
 msg+="ACTION: "+gStatus+"\n";
 msg+="GREEN = DEMAND | RED = SUPPLY | SL/TP INDIVIDUAL\n";
 msg+="DEMO / TESTER ONLY";
 Comment(msg);
}
int OnInit()
{
 if(InpLots<=0 || InpPipSize<=0 || InpWickMinDiffPips<0 ||
    InpM1Bars!=5 ||
    InpZoneTolerancePips<0 || InpZoneValidM15Bars<1 || InpKeepCountGroups<1 || InpStopLossPips<=0 ||
    InpRiskReward<=0 || InpMaxPositions<1 || InpMaxStopRiskUSD<=0)
   return INIT_PARAMETERS_INCORRECT;
 if(InpDemoOnly&&!MQLInfoInteger(MQL_TESTER) &&
    AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO)
 {Print("PLASA: Only demo and Strategy Tester allowed");return INIT_FAILED;}
 if(StringFind(_Symbol,"XAUUSD")!=0)
 {Print("PLASA: Select XAUUSD or broker suffix");return INIT_FAILED;}
 if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
 {Print("PLASA: Requires HEDGING account");return INIT_FAILED;}
 double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
 double minv=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
 double maxv=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
 if(step<=0||InpLots<minv||InpLots>maxv||
    MathAbs(InpLots/step-MathRound(InpLots/step))>0.00001)
 {Print("PLASA: Invalid lot size");return INIT_PARAMETERS_INCORRECT;}
 tr.SetExpertMagicNumber(InpMagic);
 tr.SetDeviationInPoints(InpDeviationPoints);
 tr.SetTypeFillingBySymbol(_Symbol);
 gPrefix="PLASA_ZW_"+IntegerToString((long)InpMagic)+"_";
 ResetLastError();
 gExternal=iCustom(_Symbol,PERIOD_M15,InpMarketIndicatorName);
 if(gExternal!=INVALID_HANDLE)
 {
  gIndicatorUnavailable=false;
  PrintFormat("PLASA v2.01: Market indicator handle ready: %s",InpMarketIndicatorName);
 }
 if(gExternal==INVALID_HANDLE)
 {
  gIndicatorLoadError=GetLastError();
  gIndicatorUnavailable=true;
  gStatus=StringFormat("INDICATOR ERROR %d: check MT5 Indicators/Market and exact product filename. NO TRADES.",gIndicatorLoadError);
  PrintFormat("PLASA v2.01 DIAGNOSTIC: iCustom could not load '%s' (error %d). No orders without genuine Supply/Demand zones. Check Strategy Tester Journal and Market indicator installation.",
              InpMarketIndicatorName,gIndicatorLoadError);
  // Diagnostic ONLY: continue so tester can show the exact error on chart.
  // All zone-dependent entries remain blocked, no replacement zones.

 }
 gM1Bar=iTime(_Symbol,PERIOD_M1,0);
 gM15Bar=iTime(_Symbol,PERIOD_M15,0);
 RefreshZones();
 Display();
 return INIT_SUCCEEDED;
}
void OnTick()
{
 datetime m15=iTime(_Symbol,PERIOD_M15,0);
 if(m15>0 && m15!=gM15Bar)
 {
  gM15Bar=m15;
  RefreshZones();
 }
 datetime m1=iTime(_Symbol,PERIOD_M1,0);
 if(m1==0 || m1==gM1Bar)return;
 gM1Bar=m1;
 gCount++;
 MqlRates closed[];
 ArraySetAsSeries(closed,true);
 if(CopyRates(_Symbol,PERIOD_M1,1,1,closed)==1)CandleNumber(closed[0],gCount);
 if(gCount>=InpM1Bars)
 {
   gCount=0;
   // Zones are read only from closed M15; no intrabar repainting.
   ProcessWickGroup();
   PruneCountLabels();
 }
 DrawZones(); // Refresh countdown and clear any expired rectangles
 Display();
}
void OnDeinit(const int reason)
{
 Comment("");
 if(gExternal!=INVALID_HANDLE)IndicatorRelease(gExternal);
 for(int i=ObjectsTotal(0,0,-1)-1;i>=0;i--)
 {
  string name=ObjectName(0,i,0,-1);
  if(StringFind(name,gPrefix)==0)ObjectDelete(0,name);
 }
}
