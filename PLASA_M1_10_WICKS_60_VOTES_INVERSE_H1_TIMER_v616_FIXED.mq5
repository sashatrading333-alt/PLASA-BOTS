//+------------------------------------------------------------------+
//| PLASA 15 Wicks PURE v6.16                                          |
//| CLEAN RESEARCH EA: fifteen closed M1 candles, upper vs lower wicks.  |
//| Fixed SL 100 pips and TP 100 pips on each separate position.    |
//| DEMO / Strategy Tester ONLY.                                      |
//+------------------------------------------------------------------+
#property strict
#property version "6.16"
#property description "10 M1 and rolling 60 M1 wick votes; invert confirmed trade direction; H1 boundary clock, SL100 TP100."
#include <Trade/Trade.mqh>

input double InpLots               = 0.01;       // Fixed volume per new signal
input double InpPipSize            = 0.10;       // One gold pip = 0.10 price units
input double InpMinDifferencePips  = 15.0;       // Minimum upper/lower wick-sum difference
input int    InpStopLossPips        = 100;        // Each position's stop
input double InpRiskReward          = 1.0;        // Each position's target = 100 pips
input int    InpConfirmationBars    = 5;         // Number of following closed M1 candles
input int    InpLevelLookback       = 3;         // Last 3 candles of the 10-bar group
input int    InpDirectionWindow     = 60;        // Count individual M1 wick votes
input int    InpMaxPositions       = 10;         // Max concurrent positions, same side
input ulong  InpMagic              = 26111279;   // Separate from all previous EAs
input bool   InpDemoOnly           = true;       // Safety: refuse live accounts
input bool   InpEnableTrading      = true;       // Turn on/off orders for demonstration
input bool   InpShowPanel          = true;
input bool   InpDrawCounts         = true;
input int    InpDeviationPoints    = 30;
input int    InpKeepGroups         = 12;         // Historical label groups

CTrade trade;
datetime g_lastM1=0;
datetime g_groupStart=0;
int g_count=0, g_group=0;
double g_up=0.0, g_down=0.0;
double g_lastUp=0.0, g_lastDown=0.0, g_lastDiff=0.0;
int g_lastSignal=0;
int g_pendingOpposite=0;
int g_oppositeCount=0;
string g_lastAction="Waiting for 10 CLOSED M1 candles";
string g_prefix="";
int g_pendingSide=0;
double g_confirmLevel=0.0;
datetime g_signalBar=0;
int g_pendingBars=0;
string g_lineName="",g_lineText="";
int g_tradeSuccessCount=0;
int g_voteBuy60=0,g_voteSell60=0,g_voteNeutral60=0;
string g_voteDirection="WAIT";
string g_confirmStatus="WAIT: first 10-M1 signal";

bool TradeOK()
{
   uint code=trade.ResultRetcode();
   return code==TRADE_RETCODE_DONE || code==TRADE_RETCODE_DONE_PARTIAL;
}
bool IsOwned(ulong ticket)
{
   if(ticket==0 || !PositionSelectByTicket(ticket)) return false;
   return PositionGetString(POSITION_SYMBOL)==_Symbol &&
          (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic;
}
int OwnedCount(int &buys,int &sells)
{
   buys=0;sells=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(!IsOwned(t))continue;
      if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)buys++;
      else sells++;
   }
   return buys+sells;
}
double FloatingPL()
{
   double total=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(IsOwned(t)) total+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   }
   return total;
}
bool CloseAllOwned()
{
   bool ok=true;
   for(int pass=0;pass<3;pass++)
   {
      int buys,sells;
      if(OwnedCount(buys,sells)==0)break;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong ticket=PositionGetTicket(i);
         if(!IsOwned(ticket))continue;
         if(!trade.PositionClose(ticket) || !TradeOK())
         {
            PrintFormat("PLASA CLOSE FAILED #%I64u: %u %s",ticket,
                trade.ResultRetcode(),trade.ResultRetcodeDescription());
            ok=false;
         }
      }
   }
   int buys,sells;
   return ok && OwnedCount(buys,sells)==0;
}
void DrawText(string name,datetime when,double price,string value,color c,int fontsize)
{
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_TEXT,0,when,price);
   else ObjectMove(0,name,0,when,price);
   ObjectSetString(0,name,OBJPROP_TEXT,value);
   ObjectSetInteger(0,name,OBJPROP_COLOR,c);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fontsize);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LOWER);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
}
void LabelCandle(const MqlRates &bar,int number)
{
   if(!InpDrawCounts)return;
   color c=bar.close>bar.open?clrLime:bar.close<bar.open?clrTomato:clrSilver;
   if(number==10)c=clrGold;
   DrawText(g_prefix+"C_"+IntegerToString((long)bar.time),bar.time,
       bar.high+20*InpPipSize,IntegerToString(number),c,10);
}
void LabelDecision(const MqlRates &bar,int side)
{
   if(!InpDrawCounts)return;
   string name=g_prefix+"D_"+IntegerToString((long)bar.time);
   string result=side>0?"BUY":side<0?"SELL":"WAIT";
   color c=side>0?clrLime:side<0?clrTomato:clrSilver;
   DrawText(name,bar.time,bar.high+48*InpPipSize,
     StringFormat("%s UP%.0f DN%.0f",result,g_lastUp,g_lastDown),c,9);
}
void TrimLabels()
{
   if(!InpDrawCounts)return;
   int maxCount=MathMax(1,InpKeepGroups)*11;
   int count=0;
   for(int i=ObjectsTotal(0,0,-1)-1;i>=0;i--)
   {
      string name=ObjectName(0,i,0,-1);
      if(StringFind(name,g_prefix+"C_")==0 || StringFind(name,g_prefix+"D_")==0)count++;
   }
   while(count>maxCount)
   {
      string oldestName="";
      long oldest=LONG_MAX;
      for(int i=ObjectsTotal(0,0,-1)-1;i>=0;i--)
      {
         string name=ObjectName(0,i,0,-1);
         int offset=-1;
         if(StringFind(name,g_prefix+"C_")==0)offset=StringLen(g_prefix)+2;
         else if(StringFind(name,g_prefix+"D_")==0)offset=StringLen(g_prefix)+2;
         if(offset<0)continue;
         long stamp=(long)StringToInteger(StringSubstr(name,offset));
         if(stamp<oldest){oldest=stamp;oldestName=name;}
      }
      if(oldestName=="")break;
      ObjectDelete(0,oldestName);
      count--;
   }
}
// Broker-side stop and target for EACH individual trade.
// Price distances use the EA's explicit gold pip size.
bool PrepareStops(const int side,double &sl,double &tp)
{
   MqlTick q;
   if(!SymbolInfoTick(_Symbol,q) || q.ask<=0.0 || q.bid<=0.0)
   {g_lastAction="BLOCKED: invalid quote";return false;}
   double entry=(side>0?q.ask:q.bid);
   double tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tick<=0.0)tick=_Point;
   double risk=InpStopLossPips*InpPipSize;
   double reward=risk*InpRiskReward;
   if(side>0)
   {
      sl=MathFloor((entry-risk)/tick)*tick;
      tp=MathCeil((entry+reward)/tick)*tick;
   }
   else
   {
      sl=MathCeil((entry+risk)/tick)*tick;
      tp=MathFloor((entry-reward)/tick)*tick;
   }
   sl=NormalizeDouble(sl,_Digits);
   tp=NormalizeDouble(tp,_Digits);
   double minimum=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point+tick;
   if((side>0 && (sl>=q.bid-minimum || tp<=q.bid+minimum)) ||
      (side<0 && (sl<=q.ask+minimum || tp>=q.ask-minimum)))
   {g_lastAction="BLOCKED: broker stop level incompatible with SL/TP";return false;}
   return true;
}

// Require THREE successive non-overlapping 10-M1 group signals
// in the SAME direction before ANY order (including reversal or add-on).
// Every first valid signal from a non-overlapping group of ten CLOSED M1 bars
// may place one order. Reversals act immediately on the opposing group signal.
void ExecuteSignal(int side)
{
   if(side==0)
   {
      g_lastAction="WAIT: wick difference under threshold";
      return;
   }
   if(!InpEnableTrading)
   {
      g_lastAction="SIGNAL ONLY: auto trading disabled";
      return;
   }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      g_lastAction="BLOCKED: MT5 Algo Trading OFF";
      return;
   }
   int buys,sells;
   int total=OwnedCount(buys,sells);
   bool opposite=(side>0?sells>0:buys>0);
   double sl=0.0,tp=0.0;
   if(!PrepareStops(side,sl,tp))return;
   if(!opposite && total>=InpMaxPositions)
   {
      g_lastAction="WAIT: max positions reached";
      return;
   }
   if(opposite && !CloseAllOwned())
   {
      g_lastAction="REVERSAL BLOCKED: existing positions not all closed";
      return;
   }
   bool success=(side>0?trade.Buy(InpLots,_Symbol,0.0,sl,tp,"10 M1 RR1 BUY"):
                         trade.Sell(InpLots,_Symbol,0.0,sl,tp,"10 M1 RR1 SELL"));
   if(success && TradeOK())
   {
      g_lastAction=StringFormat("%s OPEN %.2f lot SL %.2f TP %.2f",
                               side>0?"BUY":"SELL",InpLots,sl,tp);
      g_tradeSuccessCount++;
      Print("PLASA PURE: ",g_lastAction);
   }
   else
   {
      g_lastAction="ORDER FAILED: "+trade.ResultRetcodeDescription();
      Print("PLASA PURE: ",g_lastAction);
   }
}
// Draw a finite, visible confirmation level on the M1 chart.
// OBJ_TREND provides a horizontal segment; OBJ_TEXT labels its price.
void ShowConfirmationLine(const datetime signalTime,const int side,const double price)
{
 g_lineName=g_prefix+"LVL_"+IntegerToString((long)signalTime);
 g_lineText=g_prefix+"TXT_"+IntegerToString((long)signalTime);
 datetime endTime=signalTime+(InpConfirmationBars+1)*60;
 if(ObjectFind(0,g_lineName)<0)
   ObjectCreate(0,g_lineName,OBJ_TREND,0,signalTime,price,endTime,price);
 ObjectMove(0,g_lineName,0,signalTime,price);
 ObjectMove(0,g_lineName,1,endTime,price);
 ObjectSetInteger(0,g_lineName,OBJPROP_RAY_RIGHT,false);
 ObjectSetInteger(0,g_lineName,OBJPROP_COLOR,side>0?clrLime:clrTomato);
 ObjectSetInteger(0,g_lineName,OBJPROP_STYLE,STYLE_SOLID);
 ObjectSetInteger(0,g_lineName,OBJPROP_WIDTH,2);
 ObjectSetInteger(0,g_lineName,OBJPROP_SELECTABLE,false);
 DrawText(g_lineText,endTime,price,
    StringFormat("%s CONFIRM %.*f",side>0?"BUY":"SELL",_Digits,price),
    side>0?clrLime:clrTomato,9);
 ChartRedraw(0);
}
void MarkConfirmationLine(const bool confirmed)
{
 if(g_lineName=="")return;
 color c=confirmed?clrAqua:clrSilver;
 if(ObjectFind(0,g_lineName)>=0)
 {
  ObjectSetInteger(0,g_lineName,OBJPROP_STYLE,STYLE_DOT);
  ObjectSetInteger(0,g_lineName,OBJPROP_WIDTH,1);
  ObjectSetInteger(0,g_lineName,OBJPROP_COLOR,c);
 }
 if(ObjectFind(0,g_lineText)>=0)
 {
  ObjectSetInteger(0,g_lineText,OBJPROP_COLOR,c);
  ObjectSetString(0,g_lineText,OBJPROP_TEXT,
     StringFormat("%s %s %.*f",confirmed?"CONFIRMED":"EXPIRED",
                  g_pendingSide>0?"BUY":"SELL",_Digits,g_confirmLevel));
 }
 ChartRedraw(0);
}
void ClearPending()
{
 g_pendingSide=0;
 g_pendingBars=0;
 g_confirmLevel=0.0;
 g_signalBar=0;
 g_lineName="";
 g_lineText="";
}
// Called ONLY on the following CLOSED M1 candles, before checking a new
// batch of 15 candles. Wick signal candle cannot confirm itself.
// Votes come from each of the last 60 CLOSED M1 bars. Neutral on equal wicks.
bool RefreshWickVoteDirection()
{
 MqlRates bars[];
 ArraySetAsSeries(bars,true);
 g_voteBuy60=0;g_voteSell60=0;g_voteNeutral60=0;
 int n=CopyRates(_Symbol,PERIOD_M1,1,InpDirectionWindow,bars);
 if(n!=InpDirectionWindow){g_voteDirection="DATA WAIT";return false;}
 double tolerance=_Point*0.01;
 for(int i=0;i<n;i++)
 {
  double upper=MathMax(0.0,bars[i].high-MathMax(bars[i].open,bars[i].close));
  double lower=MathMax(0.0,MathMin(bars[i].open,bars[i].close)-bars[i].low);
  if(lower>upper+tolerance)g_voteBuy60++;
  else if(upper>lower+tolerance)g_voteSell60++;
  else g_voteNeutral60++;
 }
 if(g_voteBuy60>g_voteSell60)g_voteDirection="BUY";
 else if(g_voteSell60>g_voteBuy60)g_voteDirection="SELL";
 else g_voteDirection="TIE";
 return true;
}
bool VotesAllow(const int direction)
{
 if(!RefreshWickVoteDirection())return false;
 return direction>0?g_voteBuy60>g_voteSell60:g_voteSell60>g_voteBuy60;
}

void ProcessPending(const MqlRates &closed)
{
 if(g_pendingSide==0 || closed.time<=g_signalBar)return;
 g_pendingBars++;
 bool crossed=(g_pendingSide>0?closed.close>g_confirmLevel:closed.close<g_confirmLevel);
 if(crossed)
 {
  int oldCount=g_tradeSuccessCount;
  if(VotesAllow(g_pendingSide))
     ExecuteSignal(-g_pendingSide); // Reverse only final order; signal and line unchanged
  else
     g_lastAction=StringFormat("WAIT: 60 M1 BUY %d SELL %d (%s)",g_voteBuy60,g_voteSell60,g_voteDirection);
  bool opened=g_tradeSuccessCount>oldCount;
  if(opened)
  {
   g_confirmStatus=StringFormat("%s SIGNAL -> %s ORDER (%d M1)",
             g_pendingSide>0?"BUY":"SELL",g_pendingSide>0?"SELL":"BUY",g_pendingBars);
   MarkConfirmationLine(true);
   ClearPending();
  }
  else
  {
   g_confirmStatus="BREAKOUT: order not opened - "+g_lastAction;
   // Try again only on a new confirming candle before expiry.
   if(g_pendingBars>=InpConfirmationBars)
   {
      MarkConfirmationLine(false);
      ClearPending();
   }
  }
  return;
 }
 if(g_pendingBars>=InpConfirmationBars)
 {
    g_confirmStatus="EXPIRED: 5 M1 without close beyond confirmation";
    MarkConfirmationLine(false);
    ClearPending();
 }
 else g_confirmStatus=StringFormat("WAIT %d/%d M1 to break %.2f",
                   g_pendingBars,InpConfirmationBars,g_confirmLevel);
}
void ArmConfirmation(const MqlRates &last,const int side)
{
 MqlRates recent[];
 ArraySetAsSeries(recent,true);
 if(CopyRates(_Symbol,PERIOD_M1,1,InpLevelLookback,recent)!=InpLevelLookback)
 {
   g_lastAction="WAIT: cannot read the last M1 candles for level";
   return;
 }
 double level=side>0?recent[0].high:recent[0].low;
 for(int i=1;i<InpLevelLookback;i++)
 {
   if(side>0 && recent[i].high>level)level=recent[i].high;
   if(side<0 && recent[i].low<level)level=recent[i].low;
 }
 if(!VotesAllow(side))
 {
   g_confirmStatus=StringFormat("WAIT: 60 M1 BUY %d SELL %d (%s)",g_voteBuy60,g_voteSell60,g_voteDirection);
   g_lastAction=g_confirmStatus;
   return;
 }
 g_pendingSide=side;
 g_pendingBars=0;
 g_signalBar=last.time;
 g_confirmLevel=level;
 ShowConfirmationLine(last.time,side,level);
 g_confirmStatus=StringFormat("%s armed: M1 close %s %.2f within %d candles",
     side>0?"BUY":"SELL",side>0?"above":"below",level,InpConfirmationBars);
 g_lastAction=g_confirmStatus;
}

void Decide(const MqlRates &last)
{
   g_group++;
   g_lastUp=g_up;
   g_lastDown=g_down;
   g_lastDiff=g_up-g_down;
   int side=0;
   if(g_lastDiff>=InpMinDifferencePips) side=-1; // upper wick rejection: SELL
   else if(g_lastDiff<=-InpMinDifferencePips)side=1; // lower wick rejection: BUY
   g_lastSignal=side;
   LabelDecision(last,side);
   if(side!=0)ArmConfirmation(last,side);
   else {g_confirmStatus="WAIT: wick sums below 15-pip threshold";
         g_lastAction=g_confirmStatus;}
}
void ClosedM1()
{
   MqlRates bars[];
   ArraySetAsSeries(bars,true);
   if(CopyRates(_Symbol,PERIOD_M1,1,1,bars)!=1)return;
   MqlRates bar=bars[0];
   RefreshWickVoteDirection();
   ProcessPending(bar);
   if(g_count==0)g_groupStart=bar.time;
   double upper=MathMax(0.0,bar.high-MathMax(bar.open,bar.close))/InpPipSize;
   double lower=MathMax(0.0,MathMin(bar.open,bar.close)-bar.low)/InpPipSize;
   g_up+=upper;
   g_down+=lower;
   g_count++;
   LabelCandle(bar,g_count);
   if(g_count==10)
   {
      Decide(bar);
      g_count=0;
      g_up=0.0;
      g_down=0.0;
      TrimLabels();
   }
}
void PanelLine(int row,string content,color colorValue)
{
   string name=g_prefix+"P"+IntegerToString(row);
   if(ObjectFind(0,name)<0)
   {
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,24);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,28+row*22);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,10);
      ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   }
   ObjectSetInteger(0,name,OBJPROP_COLOR,colorValue);
   ObjectSetString(0,name,OBJPROP_TEXT,content);
}
void DrawPanel()
{
   if(!InpShowPanel)return;
   string bg=g_prefix+"BG";
   if(ObjectFind(0,bg)<0)
   {
      ObjectCreate(0,bg,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,bg,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,bg,OBJPROP_XDISTANCE,12);
      ObjectSetInteger(0,bg,OBJPROP_YDISTANCE,12);
      ObjectSetInteger(0,bg,OBJPROP_XSIZE,440);
      ObjectSetInteger(0,bg,OBJPROP_YSIZE,288);
      ObjectSetInteger(0,bg,OBJPROP_BGCOLOR,C'18,28,42');
      ObjectSetInteger(0,bg,OBJPROP_COLOR,C'70,90,114');
      ObjectSetInteger(0,bg,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,bg,OBJPROP_SELECTABLE,false);
   }
   int buys,sells;
   int total=OwnedCount(buys,sells);
   PanelLine(0,"PLASA | 10 M1 + 60 M1 VOTES v6.16",clrAqua);
   PanelLine(1,StringFormat("COUNT %d/10   UP %.1fp   DOWN %.1fp",g_count,g_up,g_down),clrWhite);
   string signal=g_lastSignal>0?"BUY":g_lastSignal<0?"SELL":"WAIT";
   PanelLine(2,StringFormat("LAST %s | DIFF %+.1fp | MIN %.1fp",
                           signal,g_lastDiff,InpMinDifferencePips),clrYellow);
   PanelLine(3,StringFormat("OPEN %d (B%d/S%d) | FLOAT $%.2f",
                  total,buys,sells,FloatingPL()),clrWhite);
   PanelLine(4,"LAST: "+StringSubstr(g_lastAction,0,58),clrSilver);
   PanelLine(5,"LEVEL: "+StringSubstr(g_confirmStatus,0,58),clrYellow);
   PanelLine(6,StringFormat("CONFIRM %d/%d | %s %.2f",
         g_pendingBars,InpConfirmationBars,g_pendingSide>0?"BUY":g_pendingSide<0?"SELL":"NONE",g_confirmLevel),clrWhite);
   PanelLine(7,StringFormat("60 M1 BUY %d / SELL %d / NEUTRAL %d -> %s",
      g_voteBuy60,g_voteSell60,g_voteNeutral60,g_voteDirection),clrAqua);
   PanelLine(8,"INVERSE: BUY SIGNAL -> SELL / SELL SIGNAL -> BUY",clrYellow);
   PanelLine(9,StringFormat("SL %dp TP %.0fp (1:%.1f)",
        InpStopLossPips,InpStopLossPips*InpRiskReward,InpRiskReward),clrTomato);
}
// Rolling 60-M1 filter updates every minute. This timer displays
// the next H1 hour boundary (BROKER SERVER TIME), not a filter reset.
void DrawHourCountdown()
{
 if(!InpShowPanel)return;
 datetime start=iTime(_Symbol,PERIOD_H1,0);
 if(start<=0){PanelLine(10,"H1 BOUNDARY: waiting for data",clrSilver);return;}
 datetime finish=start+PeriodSeconds(PERIOD_H1);
 int seconds=(int)(finish-TimeCurrent());
 if(seconds<0)seconds=0;
 PanelLine(10,StringFormat("H1 END %s | IN %02d:%02d (SERVER)",
   TimeToString(finish,TIME_MINUTES),seconds/60,seconds%60),clrAqua);
}

int OnInit()
{
   if(InpConfirmationBars<1 || InpDirectionWindow<2 || InpLevelLookback<1 || InpLevelLookback>10 || InpPipSize<=0.0 || InpMinDifferencePips<0.0 || InpStopLossPips<=0 || InpRiskReward<=0.0 ||
      InpLots<=0.0 || InpMaxPositions<1 || InpKeepGroups<1)
      return INIT_PARAMETERS_INCORRECT;
   if(InpDemoOnly && !MQLInfoInteger(MQL_TESTER) &&
      AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO)
   {
      Print("PLASA PURE runs only in tester or demo.");
      return INIT_FAILED;
   }
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("PLASA PURE needs a HEDGING account for independent entries.");
      return INIT_FAILED;
   }
   if(StringFind(_Symbol,"XAUUSD")!=0)
   {
      Print("PLASA PURE supports XAUUSD and broker suffixes.");
      return INIT_FAILED;
   }
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double minVol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxVol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(step<=0.0 || InpLots<minVol || InpLots>maxVol ||
      MathAbs(InpLots/step-MathRound(InpLots/step))>0.00001)
   {
      Print("Invalid volume for this broker.");
      return INIT_PARAMETERS_INCORRECT;
   }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   g_prefix="PLASA_PURE_"+IntegerToString((long)InpMagic)+"_";
   g_lastM1=iTime(_Symbol,PERIOD_M1,0);
   RefreshWickVoteDirection();
   DrawPanel();
   Print("PLASA v6.16: 15 M1 wick candidate, draw 3-M1 level, enter only on confirmed next M1 close within five bars. SL100 TP100");
   return INIT_SUCCEEDED;
}
void OnTick()
{
   DrawHourCountdown();
   datetime now=iTime(_Symbol,PERIOD_M1,0);
   if(now!=0 && now!=g_lastM1)
   {
      g_lastM1=now;
      ClosedM1();
      DrawPanel();
      DrawHourCountdown();
   }
}
void OnDeinit(const int reason)
{
   for(int i=0;i<11;i++)ObjectDelete(0,g_prefix+"P"+IntegerToString(i));
   ObjectDelete(0,g_prefix+"BG");
   // Historical candle count labels intentionally remain on chart.
}
