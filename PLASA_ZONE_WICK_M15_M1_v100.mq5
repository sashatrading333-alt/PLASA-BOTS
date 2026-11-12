//+------------------------------------------------------------------+
//| PLASA ZONE + WICK BALANCE v1.00                                   |
//| 5 closed M1 wick sums + M15 Supply/Demand reaction areas          |
//| Independent research EA. TESTER / DEMO only.                     |
//| NOT an integration with the WOW Market indicator.                |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"
#property description "M15 supply/demand swing-ATR zones and five closed M1 wick signals. Optional Code Base indicator buffer integration."
#include <Trade/Trade.mqh>

enum ENUM_ZONE_FEED { ZONES_INTERNAL=0, ZONES_CODEBASE_BUFFERS=1 };
input ENUM_ZONE_FEED InpZoneFeed      = ZONES_INTERNAL;
input string InpCodebaseIndicatorName = "Supply_Demand_Zones";
input double InpLots                 = 0.01;
input double InpPipSize              = 0.10; // XAUUSD: 1 pip = 0.10 price units
input double InpWickMinDiffPips      = 10.0;
input int    InpM1Bars              = 5;
input int    InpZoneSwingBars       = 3;  // number of CLOSED M15 candles to either side
input int    InpZoneATRPeriod       = 14;
input double InpZoneATRFactor       = 0.5;
input int    InpZoneLookbackBars    = 150;
input double InpZoneTolerancePips   = 10.0;
input int    InpStopLossPips        = 100;
input double InpRiskReward          = 1.0; // TP 100 pips for SL 100
input int    InpMaxPositions        = 3;
input double InpMaxStopRiskUSD      = 100.0;
input bool   InpDemoOnly           = true;
input bool   InpEnableTrading      = true;
input bool   InpShowLines          = true;
input ulong  InpMagic              = 26111293;
input int    InpDeviationPoints    = 30;

CTrade tr;
int gATR=INVALID_HANDLE, gExternal=INVALID_HANDLE;
datetime gM1Bar=0, gM15Bar=0;
int gCount=0;
double gUp=0.0,gDown=0.0;
double gSupplyHigh=0,gSupplyLow=0,gDemandHigh=0,gDemandLow=0;
datetime gSupplyTime=0,gDemandTime=0;
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
bool ExternalValue(const int buffer,double &out)
{
 double d[];
 if(gExternal==INVALID_HANDLE || BarsCalculated(gExternal)<=0 ||
    CopyBuffer(gExternal,buffer,0,1,d)!=1)return false;
 out=d[0];
 return MathIsValidNumber(out) && out!=EMPTY_VALUE;
}
bool FromExternalZones()
{
 // Buffer order officially documented by the separate Code Base indicator:
 // 0 supply high / 1 supply low / 2 demand high / 3 demand low
 // 4 type: 1 supply, -1 demand, 0 none.
 double a,b,c,d;
 if(!ExternalValue(0,a)||!ExternalValue(1,b)||
    !ExternalValue(2,c)||!ExternalValue(3,d))
 {
   gStatus="WAIT: missing indicator buffers. Check Code Base indicator installation";
   return false;
 }
 gSupplyHigh=a;gSupplyLow=b;gDemandHigh=c;gDemandLow=d;
 // Buffer values may be EMPTY or zero for absent zones.
 bool supply=gSupplyHigh>0 && gSupplyLow>0 && gSupplyHigh>gSupplyLow;
 bool demand=gDemandHigh>0 && gDemandLow>0 && gDemandHigh>gDemandLow;
 if(!supply){gSupplyHigh=0;gSupplyLow=0;}
 if(!demand){gDemandHigh=0;gDemandLow=0;}
 return supply||demand;
}
// Build zones from M15 CONFIRMED fractal swings and M15 ATR.
// This is an independent approximation, NOT WOW's proprietary model.
// Need newer closed candles on the RIGHT of each swing, preventing lookahead.
bool FromInternalZones()
{
 int barsNeeded=InpZoneLookbackBars+InpZoneSwingBars+1;
 MqlRates m[];
 ArraySetAsSeries(m,true);
 if(CopyRates(_Symbol,PERIOD_M15,1,barsNeeded,m)!=barsNeeded)
 {
  gStatus="WAIT: loading M15 candles for zones";
  return false;
 }
 double atr[];
 ArraySetAsSeries(atr,true);
 if(CopyBuffer(gATR,0,1,barsNeeded,atr)!=barsNeeded)
 {
  gStatus="WAIT: loading M15 ATR for zones";
  return false;
 }
 gSupplyHigh=0;gSupplyLow=0;gDemandHigh=0;gDemandLow=0;
 gSupplyTime=0;gDemandTime=0;
 for(int k=InpZoneSwingBars;k<InpZoneLookbackBars;k++)
 {
  bool top=true,bottom=true;
  for(int j=1;j<=InpZoneSwingBars;j++)
  {
   if(m[k].high<=m[k-j].high || m[k].high<=m[k+j].high)top=false;
   if(m[k].low>=m[k-j].low || m[k].low>=m[k+j].low)bottom=false;
  }
  double height=atr[k]*InpZoneATRFactor;
  if(height<=0.0)continue;
  if(top && gSupplyHigh<=0)
  {
    double hi=m[k].high, lo=hi-height;
    // Broken if any newer closed M15 candle closed above distal edge.
    bool broken=false;
    for(int n=k-1;n>=0;n--)if(m[n].close>hi){broken=true;break;}
    if(!broken){gSupplyHigh=hi;gSupplyLow=lo;gSupplyTime=m[k].time;}
  }
  if(bottom && gDemandHigh<=0)
  {
    double lo=m[k].low,hi=lo+height;
    bool broken=false;
    for(int n=k-1;n>=0;n--)if(m[n].close<lo){broken=true;break;}
    if(!broken){gDemandHigh=hi;gDemandLow=lo;gDemandTime=m[k].time;}
  }
  if(gSupplyHigh>0&&gDemandHigh>0)break;
 }
 if(gSupplyHigh<=0&&gDemandHigh<=0)
   gStatus="WAIT: no active confirmed M15 zones";
 return gSupplyHigh>0||gDemandHigh>0;
}
void LevelLine(const string name,double price,color c)
{
 if(!InpShowLines)return;
 string id=gPrefix+name;
 if(price<=0){ObjectDelete(0,id);return;}
 if(ObjectFind(0,id)<0)ObjectCreate(0,id,OBJ_HLINE,0,0,price);
 else ObjectMove(0,id,0,0,price);
 ObjectSetInteger(0,id,OBJPROP_COLOR,c);
 ObjectSetInteger(0,id,OBJPROP_STYLE,STYLE_DOT);
 ObjectSetInteger(0,id,OBJPROP_WIDTH,2);
}
void DrawZones()
{
 LevelLine("SUPPLY_HIGH",gSupplyHigh,clrTomato);
 LevelLine("SUPPLY_LOW",gSupplyLow,clrTomato);
 LevelLine("DEMAND_HIGH",gDemandHigh,clrLime);
 LevelLine("DEMAND_LOW",gDemandLow,clrLime);
}
bool RefreshZones()
{
 gZoneReady=InpZoneFeed==ZONES_INTERNAL?FromInternalZones():FromExternalZones();
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
 int side=0;
 if(upper-lower>=InpWickMinDiffPips)side=-1;
 else if(lower-upper>=InpWickMinDiffPips)side=1;
 if(side==0)
 {
  gWaitWicks++;
  gStatus=StringFormat("WAIT: wick UP %.1f / DOWN %.1f < %.1f diff",
                       upper,lower,InpWickMinDiffPips);
  return;
 }
 if(!gZoneReady && !RefreshZones())return;
 MqlTick q;
 if(!SymbolInfoTick(_Symbol,q) || q.bid<=0.0 || q.ask<=0.0)return;
 if(!MatchesZone(side,b,q))
 {
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
  gStatus=StringFormat("%s OPEN: 5 M1 wicks %.0f/%.0f | M15 zone | SL %.2f TP %.2f",
                        side>0?"BUY":"SELL",upper,lower,sl,tp);
 }
 else gStatus="ORDER FAILED: "+tr.ResultRetcodeDescription();
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
 string mode=InpZoneFeed==ZONES_INTERNAL?"INTERNAL SWING/ATR":"MQL5 CODEBASE INDICATOR";
 string msg="PLASA | ZONE + WICK v1.00\n";
 msg+=StringFormat("ZONE SOURCE: %s | READY %s\n",mode,gZoneReady?"YES":"NO");
 msg+=StringFormat("M15 SUPPLY: %.2f - %.2f\n",gSupplyLow,gSupplyHigh);
 msg+=StringFormat("M15 DEMAND: %.2f - %.2f\n",gDemandLow,gDemandHigh);
 msg+=StringFormat("M1 GROUP %d/%d | MIN WICK DIFF %.1f pips\n",gCount,InpM1Bars,InpWickMinDiffPips);
 msg+=StringFormat("POSITIONS %d/%d B%d S%d | FLOAT $%.2f\n",total,InpMaxPositions,buys,sells,floating);
 msg+=StringFormat("WAIT WICKS %d | WAIT ZONES %d | ENTRIES %d\n",gWaitWicks,gWaitZones,gEntries);
 msg+="ACTION: "+gStatus+"\n";
 msg+="GREEN = DEMAND | RED = SUPPLY | SL/TP INDIVIDUAL\n";
 msg+="DEMO / TESTER ONLY";
 Comment(msg);
}
int OnInit()
{
 if(InpLots<=0 || InpPipSize<=0 || InpWickMinDiffPips<0 ||
    InpM1Bars!=5 || InpZoneSwingBars<1 || InpZoneATRPeriod<2 ||
    InpZoneATRFactor<=0 || InpZoneLookbackBars<20 ||
    InpZoneLookbackBars<=2*InpZoneSwingBars ||
    InpZoneTolerancePips<0 || InpStopLossPips<=0 ||
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
 if(InpZoneFeed==ZONES_INTERNAL)
 {
  gATR=iATR(_Symbol,PERIOD_M15,InpZoneATRPeriod);
  if(gATR==INVALID_HANDLE){Print("PLASA: cannot create M15 ATR");return INIT_FAILED;}
 }
 else
 {
  gExternal=iCustom(_Symbol,PERIOD_M15,InpCodebaseIndicatorName);
  if(gExternal==INVALID_HANDLE)
  {
    Print("PLASA: missing Code Base indicator '",InpCodebaseIndicatorName,
          "'. Install and compile .mq5 under MQL5/Indicators.");
    return INIT_FAILED;
  }
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
 if(gCount>=InpM1Bars)
 {
   gCount=0;
   // In external mode the current shift-zero buffers can move within M15.
   if(InpZoneFeed==ZONES_CODEBASE_BUFFERS)RefreshZones();
   ProcessWickGroup();
 }
 Display();
}
void OnDeinit(const int reason)
{
 Comment("");
 if(gATR!=INVALID_HANDLE)IndicatorRelease(gATR);
 if(gExternal!=INVALID_HANDLE)IndicatorRelease(gExternal);
 for(int i=ObjectsTotal(0,0,-1)-1;i>=0;i--)
 {
  string name=ObjectName(0,i,0,-1);
  if(StringFind(name,gPrefix)==0)ObjectDelete(0,name);
 }
}
