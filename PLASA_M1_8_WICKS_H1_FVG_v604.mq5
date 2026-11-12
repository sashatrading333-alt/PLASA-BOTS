// PLASA M1 8 Wicks + Ticks v6.04 — demo/backtest experiment
#property strict
#property version "6.04"
#include <Trade/Trade.mqh>
input double Lots=0.01;
input double Pip=0.10;
input double MinWickDiffPips=20.0;
input int MinVotes=5;
input double TickDominancePct=53.0;
input double LatePressurePct=52.0;
input int MinTickMoves=20;
input int MaxPositions=10;
input int StopLossPips=100;        // Fixed SL from actual entry: SELL above, BUY below
input int H1FvgLookback=24;        // Look for three-CLOSED-H1-candle FVG within this range
input double H1MinFvgPips=10.0;   // Reject tiny H1 imbalances
input double FvgZoneBufferPips=15.0; // Allow entry near zone edges, rather than exact touch
input ulong Magic=26111264;
input bool DemoOnly=true;
CTrade tr;
datetime lastBar=0;
int count=0,vBuy=0,vSell=0,upTicks=0,downTicks=0;
double upper=0,lower=0,upPct=0,downPct=0;
string reason="Waiting for eight M1 candles";
string h1Reason="H1 FVG not checked";
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
 if(direction<0 && tick.bid<=currentOpen)
 {h1Reason="WAIT: current H1 not bullish";return false;}
 if(direction>0 && tick.bid>=currentOpen)
 {h1Reason="WAIT: current H1 not bearish";return false;}
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

void TradeDecision()
{
 signal=0;
 double diff=upper-lower;
 if(diff>=MinWickDiffPips && vSell>=MinVotes)signal=-1;
 else if(diff<=-MinWickDiffPips && vBuy>=MinVotes)signal=1;
 if(signal==0)
 {
  failedVotes++;
  reason=StringFormat("WAIT upper %.1f lower %.1f votes S%d B%d",upper,lower,vSell,vBuy);
  return;
 }
 if(!TickSignal(signal)){signal=0;return;}
 if(!H1FVGConfirmation(signal)){reason=h1Reason;signal=0;return;}
 double sl=0;
 if(!CalculateFixedSL(signal,sl))
 {reason="WAIT: 100-pip SL not valid for broker/spread";signal=0;return;}
 int b,s;int num=Positions(b,s);
 bool opposite=signal>0?s>0:b>0;
 if(opposite && !ClosePositions()){reason="Cannot close previous basket";return;}
 num=Positions(b,s);
 if(num>=MaxPositions){reason="Max positions";return;}
 bool sent=signal>0?tr.Buy(Lots,_Symbol,0,sl,0,"8 Wicks + H1 FVG BUY"):
                   tr.Sell(Lots,_Symbol,0,sl,0,"8 Wicks + H1 FVG SELL");
 if(sent && tr.ResultRetcode()==TRADE_RETCODE_DONE)
  reason=StringFormat("%s opened SL %.2f | %s",signal>0?"BUY":"SELL",sl,h1Reason);
 else reason="Trade rejected: "+tr.ResultRetcodeDescription();
}
void Show()
{
 string s=StringFormat("PLASA 8 M1 + H1 FVG | %d/8\nUP %.1fp DOWN %.1fp | V S%d/B%d\nTICKS UP %.0f%% DN %.0f%%\n%s\nH1: %s\nREJECT V%d T%d P%d\nSL 100 pips | NO TP",
 count,upper,lower,vSell,vBuy,upPct,downPct,reason,h1Reason,failedVotes,failedTicks,failedPressure);
 Comment(s);
}
int OnInit()
{
 if(Pip<=0 || Lots<=0 || MinVotes<1 || MinVotes>8 || MaxPositions<1 || StopLossPips<=0 || H1FvgLookback<3 || H1MinFvgPips<=0 || FvgZoneBufferPips<0)return INIT_PARAMETERS_INCORRECT;
 if(DemoOnly && !MQLInfoInteger(MQL_TESTER) && AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO)return INIT_FAILED;
 if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)return INIT_FAILED;
 if(StringFind(_Symbol,"XAUUSD")!=0)return INIT_FAILED;
 tr.SetExpertMagicNumber(Magic);tr.SetTypeFillingBySymbol(_Symbol);tr.SetDeviationInPoints(30);
 lastBar=iTime(_Symbol,PERIOD_M1,0);Show();return INIT_SUCCEEDED;
}
void OnTick()
{
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
  TradeDecision();
  Label(b[0].time,b[0].high+55*Pip,signal>0?"BUY":signal<0?"SELL":"WAIT",signal>0?clrLime:signal<0?clrRed:clrGray);
  count=0;upper=0;lower=0;vSell=0;vBuy=0;
 }
 Show();
}
void OnDeinit(const int reason){Comment("");}
