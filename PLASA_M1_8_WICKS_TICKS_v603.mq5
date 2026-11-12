// PLASA M1 8 Wicks + Ticks v6.03 — demo/backtest experiment
#property strict
#property version "6.03"
#include <Trade/Trade.mqh>
input double Lots=0.01;
input double Pip=0.10;
input double MinWickDiffPips=20.0;
input int MinVotes=5;
input double TickDominancePct=53.0;
input double LatePressurePct=52.0;
input int MinTickMoves=20;
input int MaxPositions=10;
input ulong Magic=26111263;
input bool DemoOnly=true;
CTrade tr;
datetime lastBar=0;
int count=0,vBuy=0,vSell=0,upTicks=0,downTicks=0;
double upper=0,lower=0,upPct=0,downPct=0;
string reason="Waiting for eight M1 candles";
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
 int b,s;int num=Positions(b,s);
 bool opposite=signal>0?s>0:b>0;
 if(opposite && !ClosePositions()){reason="Cannot close previous basket";return;}
 num=Positions(b,s);
 if(num>=MaxPositions){reason="Max positions";return;}
 bool sent=signal>0?tr.Buy(Lots,_Symbol,0,0,0,"8 Wicks Tick BUY"):
                   tr.Sell(Lots,_Symbol,0,0,0,"8 Wicks Tick SELL");
 if(sent && tr.ResultRetcode()==TRADE_RETCODE_DONE)
  reason=signal>0?"BUY opened":"SELL opened";
 else reason="Trade rejected: "+tr.ResultRetcodeDescription();
}
void Show()
{
 string s=StringFormat("PLASA 8 M1 | %d/8\nUP %.1fp DOWN %.1fp | V S%d/B%d\nTICKS UP %.0f%% DN %.0f%%\n%s\nREJECT V%d T%d P%d\nTEST ONLY: NO SL/TP",
 count,upper,lower,vSell,vBuy,upPct,downPct,reason,failedVotes,failedTicks,failedPressure);
 Comment(s);
}
int OnInit()
{
 if(Pip<=0 || Lots<=0 || MinVotes<1 || MinVotes>8 || MaxPositions<1)return INIT_PARAMETERS_INCORRECT;
 if(DemoOnly && !MQLInfoInteger(MQL_TESTER) && AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO)return INIT_FAILED;
 if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)return INIT_FAILED;
 if(StringFind(_Symbol,"XAUUSD")!=0)return INIT_FAILED;
 tr.SetExpertMagicNumber(Magic);tr.SetTypeFillingBySymbol(_Symbol);
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
