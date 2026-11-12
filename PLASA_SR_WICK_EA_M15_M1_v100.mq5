// PLASA SUPPORT RESISTANCE + 5 M1 WICKS v1.00
// Standalone EA: EXACT SAME S/R engine as visual companion indicator.
// No iCustom() / Market dependency. Use XAUUSD M1 Strategy Tester.
// DEMO/TESTER ONLY.
#property strict
#property version "1.00"
#include <Trade/Trade.mqh>

input int InpZoneLifeBars=48;        // 12 hours at M15
input double InpPip=0.10;           // Gold pip price units
input double InpClusterPips=30.0;   // Maximum distance between reactions
input double InpZoneHalfWidthPips=15.0;
input bool InpDrawZones=true;

input double InpLots=0.01;
input int InpSLPips=100;
input int InpTPPips=100;
input double InpZoneMarginPips=20.0;
input double InpMinWickDiffPips=10.0;
input int InpMaxPositions=3;
input double InpMaxPotentialLossUSD=100.0;
input bool InpDemoOnly=true;
input bool InpAllowOrders=true;
input ulong InpMagic=26111321;

// PLASA S/R ENGINE. Same source logic embedded in both outputs.
// All levels depend ONLY on CLOSED M15 candles. No future-bar data.
struct SRZone {bool valid;double lo,hi;datetime born,expiry;int touches;};
void ClearZone(SRZone &z){z.valid=false;z.lo=0;z.hi=0;z.born=0;z.expiry=0;z.touches=0;}
bool IsPivot(MqlRates &b[],int k,int direction)
{
 for(int n=1;n<=2;n++)
 {
  if(direction>0 && (b[k].low>=b[k-n].low||b[k].low>=b[k+n].low))return false;
  if(direction<0 && (b[k].high<=b[k-n].high||b[k].high<=b[k+n].high))return false;
 }
 return true;
}
bool ScanZones(SRZone &sup,SRZone &res,int validBars,double clusterPips,double widthPips,double pip)
{
 ClearZone(sup);ClearZone(res);
 int needed=validBars+8;
 MqlRates b[];ArraySetAsSeries(b,true);
 if(CopyRates(_Symbol,PERIOD_M15,1,needed,b)!=needed)return false;
 datetime now=TimeCurrent();
 for(int k=2;k<validBars+2;k++)
 {
  for(int side=1;side>=-1;side-=2)
  {
   if(side>0&&sup.valid)continue;
   if(side<0&&res.valid)continue;
   if(!IsPivot(b,k,side))continue;
   double center=side>0?b[k].low:b[k].high;
   double lo=center-widthPips*pip,hi=center+widthPips*pip;
   datetime confirmed=b[k-2].time+PeriodSeconds(PERIOD_M15);
   datetime until=confirmed+validBars*PeriodSeconds(PERIOD_M15);
   if(now>=until)continue;
   int hits=0,lastHit=-9999;
   for(int j=needed-3;j>=0;j--)
   {
     double v=side>0?b[j].low:b[j].high;
     if(MathAbs(v-center)>clusterPips*pip)continue;
     if(MathAbs(j-lastHit)<2)continue;
     lastHit=j;hits++;
   }
   if(hits<2)continue;
   bool broken=false;
   for(int j=k-1;j>=0;j--)
   {
    if(side>0&&b[j].close<lo){broken=true;break;}
    if(side<0&&b[j].close>hi){broken=true;break;}
   }
   if(broken)continue;
   SRZone zone;
   zone.valid=true;zone.lo=lo;zone.hi=hi;
   zone.born=confirmed;zone.expiry=until;zone.touches=hits;
   if(side>0)sup=zone;else res=zone;
  }
  if(sup.valid&&res.valid)break;
 }
 return true;
}
void DrawSRBox(string objectName,SRZone &z,color col)
{
 if(!z.valid)
 {ObjectDelete(0,objectName);ObjectDelete(0,objectName+"_T");return;}
 if(ObjectFind(0,objectName)<0)
   ObjectCreate(0,objectName,OBJ_RECTANGLE,0,z.born,z.hi,z.expiry,z.lo);
 else
 {ObjectMove(0,objectName,0,z.born,z.hi);ObjectMove(0,objectName,1,z.expiry,z.lo);}
 ObjectSetInteger(0,objectName,OBJPROP_COLOR,col);
 ObjectSetInteger(0,objectName,OBJPROP_FILL,true);
 ObjectSetInteger(0,objectName,OBJPROP_BACK,true);
 ObjectSetInteger(0,objectName,OBJPROP_WIDTH,2);
 ObjectSetInteger(0,objectName,OBJPROP_SELECTABLE,false);
 string label=objectName+"_T";
 datetime at=TimeCurrent();
 if(at<z.born)at=z.born;
 if(ObjectFind(0,label)<0)ObjectCreate(0,label,OBJ_TEXT,0,at,z.hi);
 else ObjectMove(0,label,0,at,z.hi);
 ObjectSetInteger(0,label,OBJPROP_COLOR,col);
 ObjectSetInteger(0,label,OBJPROP_FONTSIZE,9);
 ObjectSetString(0,label,OBJPROP_TEXT,StringFormat("%d touches  %.2f-%.2f",
   z.touches,z.lo,z.hi));
}

CTrade tr;
SRZone gSup,gRes;
datetime gM15=0,gM1=0;
int gCount=0,gSignals=0,gOpened=0,gZoneWait=0;
double gUpper=0,gLower=0;
string gAction="WAIT: first five CLOSED M1 candles";
string gRoot="PLASA_SR_EA_";
bool Own(ulong ticket)
{
 return ticket!=0&&PositionSelectByTicket(ticket)&&
  PositionGetString(POSITION_SYMBOL)==_Symbol&&
  (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic;
}
int CountOwned(int &buy,int &sell)
{
 buy=0;sell=0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong t=PositionGetTicket(i);
  if(!Own(t))continue;
  if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)buy++;else sell++;
 }
 return buy+sell;
}
bool TradeDone()
{
 uint x=tr.ResultRetcode();
 return x==TRADE_RETCODE_DONE||x==TRADE_RETCODE_DONE_PARTIAL;
}
double TotalRisk()
{
 double risk=0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong t=PositionGetTicket(i);
  if(!Own(t))continue;
  double sl=PositionGetDouble(POSITION_SL),profit=0;
  if(sl==0){risk+=InpMaxPotentialLossUSD;continue;}
  ENUM_ORDER_TYPE side=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?
   ORDER_TYPE_BUY:ORDER_TYPE_SELL;
  if(!OrderCalcProfit(side,_Symbol,PositionGetDouble(POSITION_VOLUME),
        PositionGetDouble(POSITION_PRICE_OPEN),sl,profit))
  {risk+=InpMaxPotentialLossUSD;continue;}
  if(profit<0)risk-=profit;
 }
 return risk;
}
double Rounded(double p,int side)
{
 double tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
 if(tick<=0)tick=_Point;
 return NormalizeDouble((side>0?MathFloor(p/tick):MathCeil(p/tick))*tick,_Digits);
}
bool TouchesZone(const int side,const MqlRates &b[],const MqlTick &q)
{
 SRZone z;
 if(side>0)z=gSup;else z=gRes;
 if(!z.valid)return false;
 double margin=InpZoneMarginPips*InpPip;
 double price=side>0?q.ask:q.bid;
 if(price<z.lo-margin||price>z.hi+margin)return false;
 for(int i=0;i<5;i++)
  if(b[i].high>=z.lo-margin&&b[i].low<=z.hi+margin)return true;
 return false;
}
void LabelM1(MqlRates &b,int n)
{
 string name=gRoot+"N_"+IntegerToString((long)b.time);
 if(ObjectFind(0,name)<0)ObjectCreate(0,name,OBJ_TEXT,0,b.time,b.high+10*InpPip);
 ObjectSetInteger(0,name,OBJPROP_COLOR,n==5?clrGold:clrSilver);
 ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
 ObjectSetString(0,name,OBJPROP_TEXT,IntegerToString(n));
}
void LabelDecision(MqlRates &b,int side,double u,double d)
{
 string name=gRoot+"S_"+IntegerToString((long)b.time);
 if(ObjectFind(0,name)<0)
    ObjectCreate(0,name,OBJ_TEXT,0,b.time,b.high+30*InpPip);
 ObjectSetInteger(0,name,OBJPROP_COLOR,side>0?clrLime:side<0?clrTomato:clrSilver);
 ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
 ObjectSetString(0,name,OBJPROP_TEXT,StringFormat("%s U%.0f D%.0f",
       side>0?"BUY":side<0?"SELL":"WAIT",u,d));
}
void ProcessFive()
{
 MqlRates b[];ArraySetAsSeries(b,true);
 if(CopyRates(_Symbol,PERIOD_M1,1,5,b)!=5){gAction="WAIT: M1 history";return;}
 double upper=0,lower=0;
 for(int i=0;i<5;i++)
 {
  upper+=MathMax(0.0,b[i].high-MathMax(b[i].open,b[i].close))/InpPip;
  lower+=MathMax(0.0,MathMin(b[i].open,b[i].close)-b[i].low)/InpPip;
 }
 int side=upper-lower>=InpMinWickDiffPips?-1:
          lower-upper>=InpMinWickDiffPips?1:0;
 LabelDecision(b[0],side,upper,lower);
 if(side==0){gAction="WAIT: insufficient wick imbalance";return;}
 gSignals++;
 MqlTick q;
 if(!SymbolInfoTick(_Symbol,q)||!TouchesZone(side,b,q))
 {gZoneWait++;gAction=side>0?"WAIT: no valid SUPPORT":"WAIT: no valid RESISTANCE";return;}
 if(!InpAllowOrders||!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)||
    !MQLInfoInteger(MQL_TRADE_ALLOWED))
 {gAction="SIGNAL only: Algo Trading disabled";return;}
 int buys,sells;
 int n=CountOwned(buys,sells);
 if(n>=InpMaxPositions){gAction="WAIT: max positions";return;}
 if((side>0&&sells>0)||(side<0&&buys>0))
 {gAction="WAIT: opposing positions active";return;}
 double price=side>0?q.ask:q.bid;
 double sl=Rounded(price+(side>0?-1:1)*InpSLPips*InpPip,side);
 double tp=Rounded(price+(side>0?1:-1)*InpTPPips*InpPip,-side);
 double tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
 double distance=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point+tick;
 if(side>0?(sl>=q.bid-distance||tp<=q.bid+distance):
            (sl<=q.ask+distance||tp>=q.ask-distance))
 {gAction="WAIT: broker minimum SL/TP distance";return;}
 double loss=0;
 if(!OrderCalcProfit(side>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL,
             _Symbol,InpLots,price,sl,loss))
 {gAction="WAIT: risk calculation error";return;}
 if(TotalRisk()+MathMax(0,-loss)>InpMaxPotentialLossUSD)
 {gAction="WAIT: risk budget";return;}
 bool ok=side>0?tr.Buy(InpLots,_Symbol,0,sl,tp,"PLASA S/R WICK BUY"):
                 tr.Sell(InpLots,_Symbol,0,sl,tp,"PLASA S/R WICK SELL");
 if(ok&&TradeDone())
 {gOpened++;gAction=StringFormat("%s OPEN at S/R zone SL %.2f TP %.2f",
                    side>0?"BUY":"SELL",sl,tp);}
 else gAction="ORDER FAILED: "+tr.ResultRetcodeDescription();
 Print("PLASA S/R WICK: ",gAction);
}
void UpdatePanel()
{
 int buy,sell,total=CountOwned(buy,sell);
 string msg="PLASA S/R + 5 M1 WICKS 1.00\n";
 msg+=StringFormat("SUPPORT: %s %.2f .. %.2f (%d touches)\n",
                    gSup.valid?"ACTIVE":"NONE",gSup.lo,gSup.hi,gSup.touches);
 msg+=StringFormat("RESISTANCE: %s %.2f .. %.2f (%d touches)\n",
                    gRes.valid?"ACTIVE":"NONE",gRes.lo,gRes.hi,gRes.touches);
 msg+=StringFormat("M1 GROUP %d/5 | WICKS %.1f vs %.1f | MIN %.0f pips\n",
                    gCount,gUpper,gLower,InpMinWickDiffPips);
 msg+=StringFormat("SIGNALS %d | ZONE BLOCKS %d | TRADES %d | OPEN %d (B%d/S%d)\n",
                    gSignals,gZoneWait,gOpened,total,buy,sell);
 msg+="ACTION: "+gAction+"\n";
 msg+="M15 S/R 12h | 20p proximity | 0.01 default | SL100 TP100\n";
 msg+="DEMO/TESTER ONLY";
 Comment(msg);
}
int OnInit()
{
 if(InpPip<=0||InpZoneLifeBars<6||InpClusterPips<=0||
    InpZoneHalfWidthPips<=0||InpLots<=0||InpSLPips<=0||InpTPPips<=0||
    InpMaxPositions<1||InpMaxPotentialLossUSD<=0)return INIT_PARAMETERS_INCORRECT;
 if(InpDemoOnly&&!MQLInfoInteger(MQL_TESTER)&&
    AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO)return INIT_FAILED;
 if(StringFind(_Symbol,"XAUUSD")!=0)return INIT_FAILED;
 if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
 {Print("PLASA: HEDGING account required");return INIT_FAILED;}
 double volumeStep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
 double minVolume=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
 double maxVolume=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
 if(volumeStep<=0||InpLots<minVolume||InpLots>maxVolume||
    MathAbs(InpLots/volumeStep-MathRound(InpLots/volumeStep))>0.00001)
 {Print("PLASA: invalid volume");return INIT_PARAMETERS_INCORRECT;}
 tr.SetExpertMagicNumber(InpMagic);
 tr.SetDeviationInPoints(30);
 tr.SetTypeFillingBySymbol(_Symbol);
 gRoot="PLASA_SR_EA_"+IntegerToString((long)InpMagic)+"_";
 ClearZone(gSup);ClearZone(gRes);
 gM15=iTime(_Symbol,PERIOD_M15,0);
 gM1=iTime(_Symbol,PERIOD_M1,0);
 ScanZones(gSup,gRes,InpZoneLifeBars,InpClusterPips,InpZoneHalfWidthPips,InpPip);
 if(InpDrawZones)
 {
  DrawSRBox(gRoot+"SUPPORT",gSup,clrForestGreen);
  DrawSRBox(gRoot+"RESISTANCE",gRes,clrFireBrick);
 }
 UpdatePanel();return INIT_SUCCEEDED;
}
void OnTick()
{
 datetime m15=iTime(_Symbol,PERIOD_M15,0);
 if(m15>0&&m15!=gM15)
 {
  gM15=m15;
  ScanZones(gSup,gRes,InpZoneLifeBars,InpClusterPips,InpZoneHalfWidthPips,InpPip);
  if(InpDrawZones)
  {
   DrawSRBox(gRoot+"SUPPORT",gSup,clrForestGreen);
   DrawSRBox(gRoot+"RESISTANCE",gRes,clrFireBrick);
  }
 }
 datetime m1=iTime(_Symbol,PERIOD_M1,0);
 if(m1==0||m1==gM1)return;
 gM1=m1;
 MqlRates b[];ArraySetAsSeries(b,true);
 if(CopyRates(_Symbol,PERIOD_M1,1,1,b)!=1)return;
 gUpper+=MathMax(0.0,b[0].high-MathMax(b[0].open,b[0].close))/InpPip;
 gLower+=MathMax(0.0,MathMin(b[0].open,b[0].close)-b[0].low)/InpPip;
 gCount++;
 LabelM1(b[0],gCount);
 if(gCount>=5)
 {
  ProcessFive();
  gCount=0;gUpper=0;gLower=0;
 }
 UpdatePanel();
}
void OnDeinit(const int reason)
{
 Comment("");
 for(int i=ObjectsTotal(0,0,-1)-1;i>=0;i--)
 {
  string name=ObjectName(0,i,0,-1);
  if(StringFind(name,gRoot)==0)ObjectDelete(0,name);
 }
}
