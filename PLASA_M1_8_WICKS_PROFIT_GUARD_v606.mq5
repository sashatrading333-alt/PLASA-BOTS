// PLASA M1 8 Wicks + Ticks v6.06 — demo/backtest experiment
#property strict
#property version "6.06"
#include <Trade/Trade.mqh>
input double Lots=0.01;
input double Pip=0.10;
input double MinWickDiffPips=12.0;
input int MinVotes=4;
input double TickDominancePct=52.0;
input double LatePressurePct=51.0;
input int MinTickMoves=20;
input int MaxPositions=10;
input int StopLossPips=100;        // Fixed SL from actual entry: SELL above, BUY below
input int H1FvgLookback=24;        // Look for three-CLOSED-H1-candle FVG within this range
input double H1MinFvgPips=5.0;   // Reject tiny H1 imbalances
input double FvgZoneBufferPips=60.0; // Allow entry near zone edges, rather than exact touch
input double ProfitProtectStartUSD=50.0;  // Start protecting once today's bot P/L reaches this
input double ProfitKeepPercent=80.0;    // Keep 80% of highest observed daily bot P/L
input bool PauseAfterProfitLock=true;   // Avoid losing secured daily profit on new entries
input ulong Magic=26111266;
input bool DemoOnly=true;
CTrade tr;
datetime lastBar=0;
int count=0,vBuy=0,vSell=0,upTicks=0,downTicks=0;
double upper=0,lower=0,upPct=0,downPct=0;
string reason="Waiting for eight M1 candles";
string h1Reason="H1 FVG not checked";
string tickReason="Tick pressure not checked";
string entryPath="WAIT";
int gDay=0;
double gDayPeak=0.0,gDayFloor=0.0,gDayProfit=0.0;
bool gProfitLocked=false;
string gPeakGV="",gLockGV="";

int wickSignals=0, tickPass=0, fvgPass=0, accepted=0, rejected=0;
double fvgLow=0.0,fvgHigh=0.0;
int fvgAge=0;
int signal=0,failedTicks=0,failedVotes=0,failedPressure=0;
string prefix="PLASA_8W_";
bool Owned(ulong ticket)
{
 if(!PositionSelectByTicket(ticket))return false;
 return PositionGetString(POSITION_SYMBOL)==_Symbol && (ulong)PositionGetInteger(POSITION_MAGIC)==Magic;
}
int Positions(int &buy,int &sell)
{
 buy=0;sell=0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong ticket=PositionGetTicket(i);
  if(!Owned(ticket))continue;
  if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)buy++;else sell++;
 }
 return buy+sell;
}
bool ClosePositions()
{
 for(int pass=0;pass<3;pass++)
 {
  for(int i=PositionsTotal()-1;i>=0;i--)
  {
   ulong t=PositionGetTicket(i);
   if(Owned(t) && !tr.PositionClose(t))
     Print("Close failed ticket=",t," reason=",tr.ResultRetcodeDescription());
  }
 }
 int b,s;return Positions(b,s)==0;
}
void Label(datetime t,double price,string txt,color clr)
{
 string id=prefix+IntegerToString((long)t);
 if(ObjectFind(0,id)<0)ObjectCreate(0,id,OBJ_TEXT,0,t,price);
 ObjectSetString(0,id,OBJPROP_TEXT,txt);
 ObjectSetInteger(0,id,OBJPROP_COLOR,clr);
 ObjectSetInteger(0,id,OBJPROP_FONTSIZE,9);
 ObjectSetInteger(0,id,OBJPROP_ANCHOR,ANCHOR_LOWER);
}
bool TickSignal(int direction)
{
 MqlRates bars[];ArraySetAsSeries(bars,true);
 if(CopyRates(_Symbol,PERIOD_M1,1,8,bars)!=8)
 {reason="No eight M1 candles";failedTicks++;return false;}
 int up=0,down=0,earlyUp=0,earlyDown=0,lateUp=0,lateDown=0;
 for(int c=7;c>=0;c--)
 {
  ulong from=(ulong)bars[c].time*1000;
  MqlTick ticks[];
  int got=CopyTicksRange(_Symbol,ticks,COPY_TICKS_INFO,from,from+59999);
  if(got<3){reason="Missing real quote ticks";failedTicks++;return false;}
  double previous=0;int moves=0;
  for(int i=0;i<got;i++)
  {
   if(ticks[i].bid<=0 || ticks[i].ask<=0)continue;
   double mid=(ticks[i].bid+ticks[i].ask)/2.0;
   if(previous>0)
   {
    double d=mid-previous;
    if(MathAbs(d)>=_Point*0.1)
    {
     bool late=ticks[i].time_msc>=from+30000;
     if(d>0){up++;if(late)lateUp++;else earlyUp++;}
     else{down++;if(late)lateDown++;else earlyDown++;}
     moves++;
    }
   }
   previous=mid;
  }
  if(moves<2){reason="Too few tick movements";failedTicks++;return false;}
 }
 int total=up+down,first=earlyUp+earlyDown,last=lateUp+lateDown;
 if(total<MinTickMoves || first==0 || last==0)
 {reason="Not enough directional ticks";failedTicks++;return false;}
 upTicks=up;downTicks=down;
 upPct=100.0*up/total;downPct=100.0*down/total;
 double preferred=direction>0?upPct:downPct;
 double latePct=direction>0?100.0*lateUp/last:100.0*lateDown/last;
 if(preferred<TickDominancePct || latePct<LatePressurePct)
 {reason=StringFormat("Tick pressure weak %.1f%% late %.1f%%",preferred,latePct);failedPressure++;return false;}
 return true;
}

// H1 confirmation uses *only completed H1 candles* to define a traditional FVG.
// SELL: current H1 is bullish (bid above its open), but an earlier bearish H1
// FVG is being retested. BUY mirrors this exactly. No future bars are read.
// The first and third candles (chronologically) must not have overlapping wicks.
bool H1FVGConfirmation(const int direction)
{
 fvgLow=0;fvgHigh=0;fvgAge=0;
 MqlTick tick;
 if(!SymbolInfoTick(_Symbol,tick)){h1Reason="No current quotes";return false;}
 double currentOpen=iOpen(_Symbol,PERIOD_H1,0);
 if(currentOpen<=0){h1Reason="H1 open unavailable";return false;}
 double market=(tick.bid+tick.ask)*0.5;
 // No current-H1 color requirement: an FVG can still matter after the
 // current H1 changes color. The direction of the historical gap is checked.
 MqlRates h[];
 ArraySetAsSeries(h,true);
 int need=H1FvgLookback+2;
 if(CopyRates(_Symbol,PERIOD_H1,1,need,h)!=need)
 {h1Reason="WAIT: H1 history unavailable";return false;}
 double tolerance=FvgZoneBufferPips*Pip;
 double minGap=H1MinFvgPips*Pip;
 bool found=false;double nearest=1.0e100;
 // h[i] = most recent (third) completed candle;
 // h[i+1] = middle; h[i+2] = oldest (first).
 for(int i=0;i<H1FvgLookback;i++)
 {
  double lo=0.0,hi=0.0;
  if(direction<0)
  {
   if(h[i+1].close>=h[i+1].open)continue; // bearish displacement middle
   lo=h[i].high; hi=h[i+2].low;
  }
  else
  {
   if(h[i+1].close<=h[i+1].open)continue; // bullish displacement middle
   lo=h[i+2].high; hi=h[i].low;
  }
  if(hi-lo<minGap)continue;
  // Require market to be inside / near this closed-H1 FVG at entry.
  if(market<lo-tolerance || market>hi+tolerance)continue;
  double center=(lo+hi)*0.5;
  double delta=MathAbs(market-center);
  if(delta<nearest)
  {nearest=delta;fvgLow=lo;fvgHigh=hi;fvgAge=i+1;found=true;}
 }
 if(!found)
 {h1Reason=direction<0?"WAIT: no nearby bearish H1 FVG":"WAIT: no nearby bullish H1 FVG";return false;}
 h1Reason=StringFormat("%s H1 FVG %.2f..%.2f age %d",
   direction<0?"BEAR":"BULL",fvgLow,fvgHigh,fvgAge);
 return true;
}
// Exact SL is 100 pips from the requested entry quote. Refuse, rather than
// silently widen, if broker stops-level makes the specified SL invalid.
bool CalculateFixedSL(const int direction,double &sl)
{
 MqlTick tick;
 if(!SymbolInfoTick(_Symbol,tick))return false;
 double entry=direction>0?tick.ask:tick.bid;
 double raw=entry+(direction<0?StopLossPips*Pip:-StopLossPips*Pip);
 double unit=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
 if(unit<=0.0)unit=_Point;
 sl=NormalizeDouble((direction>0?MathFloor(raw/unit):MathCeil(raw/unit))*unit,_Digits);
 double minDist=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point+unit;
 if(direction>0 && sl>=tick.bid-minDist)return false;
 if(direction<0 && sl<=tick.ask+minDist)return false;
 return true;
}


// Daily protection covers THIS EA only (symbol+magic) and combines closed
// trading results with current floating P/L. A terminal Global Variable
// preserves the daily peak and pause state across EA restarts.
int ServerDay()
{
 MqlDateTime d;
 TimeToStruct(TimeCurrent(),d);
 return d.year*10000+d.mon*100+d.day;
}
datetime ServerDayStart()
{
 MqlDateTime d;
 TimeToStruct(TimeCurrent(),d);
 d.hour=0;d.min=0;d.sec=0;
 return StructToTime(d);
}
string StateKey(string field)
{
 // MT5 terminal global-variable name should remain short (<64 chars).
 return StringFormat("P606_%I64d_%s_%I64u_%d_%s",
   AccountInfoInteger(ACCOUNT_LOGIN),_Symbol,Magic,gDay,field);
}
void InitializeProfitDay()
{
 int day=ServerDay();
 if(day==gDay)return;
 gDay=day;
 gPeakGV=StateKey("PEAK");
 gLockGV=StateKey("LOCK");
 gDayPeak=GlobalVariableCheck(gPeakGV)?GlobalVariableGet(gPeakGV):0.0;
 gProfitLocked=GlobalVariableCheck(gLockGV) && GlobalVariableGet(gLockGV)>0.5;
 gDayFloor=gDayPeak>=ProfitProtectStartUSD?
                    gDayPeak*ProfitKeepPercent/100.0:0.0;
}
double DailyClosedPL()
{
 double sum=0.0;
 if(!HistorySelect(ServerDayStart(),TimeCurrent()))return 0.0;
 for(int i=0;i<HistoryDealsTotal();i++)
 {
  ulong ticket=HistoryDealGetTicket(i);
  if(ticket==0)continue;
  if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol)continue;
  if((ulong)HistoryDealGetInteger(ticket,DEAL_MAGIC)!=Magic)continue;
  sum+=HistoryDealGetDouble(ticket,DEAL_PROFIT)
      +HistoryDealGetDouble(ticket,DEAL_SWAP)
      +HistoryDealGetDouble(ticket,DEAL_COMMISSION)
      +HistoryDealGetDouble(ticket,DEAL_FEE);
 }
 return sum;
}
double BotFloatingPL()
{
 double sum=0.0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong t=PositionGetTicket(i);
  if(!Owned(t))continue;
  sum+=PositionGetDouble(POSITION_PROFIT)
      +PositionGetDouble(POSITION_SWAP);
 }
 return sum;
}
bool ProfitProtection()
{
 InitializeProfitDay();
 gDayProfit=DailyClosedPL()+BotFloatingPL();
 if(gDayProfit>gDayPeak)
 {
  gDayPeak=gDayProfit;
  GlobalVariableSet(gPeakGV,gDayPeak);
 }
 gDayFloor=gDayPeak>=ProfitProtectStartUSD?
                    gDayPeak*ProfitKeepPercent/100.0:0.0;
 if(gProfitLocked)
 {
  int buys,sells;
  if(Positions(buys,sells)>0)ClosePositions();
  return true;
 }
 if(gDayFloor>0.0 && gDayProfit<=gDayFloor)
 {
  PrintFormat("PLASA v6.06 DAILY PROFIT PROTECT: peak %.2f floor %.2f actual %.2f. Closing EA positions.",
              gDayPeak,gDayFloor,gDayProfit);
  bool closed=ClosePositions();
  if(PauseAfterProfitLock)
  {
   gProfitLocked=true;
   GlobalVariableSet(gLockGV,1.0);
  }
  reason=closed?"PROFIT LOCK: positions closed":"PROFIT LOCK: retry closing";
  if(closed)gDayProfit=DailyClosedPL();
  return true;
 }
 return false;
}

void TradeDecision()
{
 signal=0;entryPath="WAIT";
 if(gProfitLocked){reason="WAIT: Daily profit protection locked";return;}
 double diff=upper-lower;
 if(diff>=MinWickDiffPips && vSell>=MinVotes)signal=-1;
 else if(diff<=-MinWickDiffPips && vBuy>=MinVotes)signal=1;
 if(signal==0)
 {
  failedVotes++;
  reason=StringFormat("WAIT WICKS: UP %.1f DN %.1f votes S%d B%d",upper,lower,vSell,vBuy);
  return;
 }
 wickSignals++;
 int direction=signal;
 // Confirmation choices: quotation tick pressure OR a retested H1 FVG.
 // An unavailable tick history must NOT erase a valid FVG confirmation.
 bool tickOK=TickSignal(direction);
 tickReason=tickOK?"TICK OK":reason;
 if(tickOK)tickPass++;
 bool fvgOK=H1FVGConfirmation(direction);
 if(fvgOK)fvgPass++;
 if(!tickOK && !fvgOK)
 {
  rejected++;
  reason=StringFormat("WAIT BOTH: %s | %s",tickReason,h1Reason);
  signal=0;
  return;
 }
 entryPath=tickOK && fvgOK?"TICKS+FVG":tickOK?"TICKS":"H1 FVG";
 double sl=0.0;
 if(!CalculateFixedSL(direction,sl))
 {
  reason="WAIT: Broker does not allow fixed 100-pip SL";
  signal=0;
  return;
 }
 int b,s;
 int num=Positions(b,s);
 bool opposite=direction>0?s>0:b>0;
 if(opposite && !ClosePositions())
 {
  reason="WAIT: Could not close previous basket";
  signal=0;
  return;
 }
 num=Positions(b,s);
 if(num>=MaxPositions)
 {
  reason="WAIT: Max positions reached";
  signal=0;
  return;
 }
 bool sent=direction>0?
     tr.Buy(Lots,_Symbol,0,sl,0,"8W BUY"):
     tr.Sell(Lots,_Symbol,0,sl,0,"8W SELL");
 if(sent && (tr.ResultRetcode()==TRADE_RETCODE_DONE ||
             tr.ResultRetcode()==TRADE_RETCODE_DONE_PARTIAL))
 {
  accepted++;
  reason=StringFormat("%s opened SL %.2f via %s",
                      direction>0?"BUY":"SELL",sl,entryPath);
  Print("PLASA v6.06 ",reason);
 }
 else
 {
  signal=0;
  reason="Order rejected: "+tr.ResultRetcodeDescription();
  Print("PLASA v6.06 ",reason);
 }
}
void Show()
{
 string line=StringFormat("PLASA 8 M1 v6.06 | %d/8\nUP %.1fp / DN %.1fp  VOTES S%d/B%d\n",
                         count,upper,lower,vSell,vBuy);
 line+=StringFormat("TICK UP %.0f%% / DOWN %.0f%%\n",upPct,downPct);
 line+="ENTRY: "+entryPath+"\n";
 line+="ACTION: "+reason+"\n";
 line+="FVG: "+h1Reason+"\n";
 line+=StringFormat("WICK SIGNALS %d | TICK OK %d | FVG OK %d | OPENED %d | BOTH FAIL %d\n",
                    wickSignals,tickPass,fvgPass,accepted,rejected);
 line+=StringFormat("DAY P/L $%.2f | PEAK $%.2f | FLOOR $%.2f\n",
                    gDayProfit,gDayPeak,gDayFloor);
 line+=gProfitLocked?"PROFIT LOCK ACTIVE: PAUSED":"SL 100 pips | DAY PROFIT TRAIL";
 Comment(line);
}
int OnInit()
{
 if(Pip<=0 || Lots<=0 || MinVotes<1 || MinVotes>8 || MaxPositions<1 || StopLossPips<=0 || H1FvgLookback<3 || H1MinFvgPips<=0 || FvgZoneBufferPips<0 || ProfitProtectStartUSD<=0 || ProfitKeepPercent<=0 || ProfitKeepPercent>=100)return INIT_PARAMETERS_INCORRECT;
 if(DemoOnly && !MQLInfoInteger(MQL_TESTER) && AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO)return INIT_FAILED;
 if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)return INIT_FAILED;
 if(StringFind(_Symbol,"XAUUSD")!=0)return INIT_FAILED;
 tr.SetExpertMagicNumber(Magic);tr.SetTypeFillingBySymbol(_Symbol);tr.SetDeviationInPoints(30);
 lastBar=iTime(_Symbol,PERIOD_M1,0);InitializeProfitDay();ProfitProtection();Show();return INIT_SUCCEEDED;
}
void OnTick()
{
 bool blocked=ProfitProtection();
 datetime now=iTime(_Symbol,PERIOD_M1,0);
 if(now==0||now==lastBar)return;
 lastBar=now;
 MqlRates b[];ArraySetAsSeries(b,true);
 if(CopyRates(_Symbol,PERIOD_M1,1,1,b)!=1)return;
 double up=MathMax(0,(b[0].high-MathMax(b[0].open,b[0].close))/Pip);
 double down=MathMax(0,(MathMin(b[0].open,b[0].close)-b[0].low)/Pip);
 upper+=up;lower+=down;count++;
 if(up>down)vSell++;else if(down>up)vBuy++;
 Label(b[0].time,b[0].high+20*Pip,IntegerToString(count),count==8?clrGold:clrSilver);
 if(count==8)
 {
  if(!blocked)TradeDecision();
  else {signal=0;reason="WAIT: profit floor protection";}
  Label(b[0].time,b[0].high+55*Pip,signal>0?"BUY":signal<0?"SELL":"WAIT",signal>0?clrLime:signal<0?clrRed:clrGray);
  count=0;upper=0;lower=0;vSell=0;vBuy=0;
 }
 Show();
}
void OnDeinit(const int reason){Comment("");}
