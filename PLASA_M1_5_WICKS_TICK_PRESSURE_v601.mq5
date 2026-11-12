//+------------------------------------------------------------------+
//| PLASA 5 Wicks TICK CONSENSUS v6.01                                          |
//| CLEAN RESEARCH EA: five closed M1 candles, upper vs lower wicks.  |
//| No SL/TP, no trailing, no extra confirmations or daily limits.    |
//| DEMO / Strategy Tester ONLY.                                      |
//+------------------------------------------------------------------+
#property strict
#property version "6.01"
#property description "Five M1 wick sums + candle votes + quote tick pressure. Demo/tester."
#include <Trade/Trade.mqh>

input double InpLots               = 0.01;       // Fixed volume per new signal
input double InpPipSize            = 0.10;       // One gold pip = 0.10 price units
input double InpMinDifferencePips  = 20.0;       // Minimum upper/lower wick-sum difference
input int    InpMinWickVotes        = 3;          // At least 3 candle-wick votes in direction
input double InpTickDominance      = 60.0;       // Required directional quote-tick percentage
input double InpFinalHalfMinPct     = 55.0;       // Minimum directional pressure in final half
input int    InpMinTicksPerCandle   = 8;          // Require reliable tick coverage per candle
input int    InpMinDirectionalTicks = 40;         // Across all five M1 candles
input int    InpMaxPositions       = 10;         // Max concurrent positions, same side
input ulong  InpMagic              = 26111261;   // Separate from all previous EAs
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
int g_voteSell=0,g_voteBuy=0,g_lastVoteSell=0,g_lastVoteBuy=0;
double g_tickUpPct=0.0,g_tickDownPct=0.0,g_tickFirstBuyPct=0.0,g_tickLastBuyPct=0.0;
int g_tickUp=0,g_tickDown=0;
string g_tickStatus="Tick data not checked";
int g_lastSignal=0;
string g_lastAction="Waiting for 5 CLOSED M1 candles";
string g_prefix="";

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
   if(number==5)c=clrGold;
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
     StringFormat("%s V%d/%d T%.0f%%",result,g_lastVoteSell,g_lastVoteBuy,side>0?g_tickUpPct:g_tickDownPct),c,9);
}
void TrimLabels()
{
   if(!InpDrawCounts)return;
   int maxCount=MathMax(1,InpKeepGroups)*6;
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
void ExecuteSignal(int side)
{
   if(side==0)
   {
      g_lastAction="WAIT: upper/lower difference below threshold";
      return;
   }
   int buys,sells;
   int total=OwnedCount(buys,sells);
   bool opposite=(side>0?sells>0:buys>0);
   if(!InpEnableTrading)
   {
      g_lastAction="SIGNAL ONLY: Auto trading disabled";
      return;
   }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      g_lastAction="BLOCKED: MT5 Algo Trading is OFF";
      return;
   }
   if(opposite)
   {
      if(!CloseAllOwned())
      {
         g_lastAction="REVERSAL BLOCKED: old positions not closed";
         return;
      }
      total=0;
   }
   if(total>=InpMaxPositions)
   {
      g_lastAction="WAIT: max positions reached";
      return;
   }
   // No hidden trade filters: only the 5-candle signal and safety checks.
   bool success=(side>0?trade.Buy(InpLots,_Symbol,0.0,0.0,0.0,"5 M1 upper/lower wicks"):
                         trade.Sell(InpLots,_Symbol,0.0,0.0,0.0,"5 M1 upper/lower wicks"));
   if(success && TradeOK())
   {
      g_lastAction=StringFormat("%s %.2f lot (UP %.1f / DN %.1f)",
                        side>0?"BUY":"SELL",InpLots,g_lastUp,g_lastDown);
      Print("PLASA PURE: ",g_lastAction);
   }
   else
   {
      g_lastAction="ORDER FAILED: "+trade.ResultRetcodeDescription();
      Print("PLASA PURE: ",g_lastAction);
   }
}
// This is quote-update direction, NOT actual buy/sell traded volume.
// Each of the five CLOSED M1 candles is read independently to avoid
// measuring artificial jumps across candle boundaries.
// COPY_TICKS_INFO includes Bid/Ask updates from the broker tick feed.
bool CalculateTickPressure()
{
   MqlRates five[];
   ArraySetAsSeries(five,true);
   if(CopyRates(_Symbol,PERIOD_M1,1,5,five)!=5)
   {g_tickStatus="MISSING 5 M1 candles";return false;}

   int firstUp=0,firstDown=0,lastUp=0,lastDown=0;
   int allUp=0,allDown=0;
   for(int c=4;c>=0;c--)
   {
      ulong from=(ulong)five[c].time*1000;
      MqlTick ticks[];
      ResetLastError();
      int got=CopyTicksRange(_Symbol,ticks,COPY_TICKS_INFO,from,from+59999);
      if(got<InpMinTicksPerCandle)
      {
         g_tickStatus=StringFormat("TICKS MISSING candle %d: %d (err %d)",5-c,got,GetLastError());
         return false;
      }
      double previous=0.0;
      int candleMoves=0;
      for(int j=0;j<got;j++)
      {
         // A zero Bid or Ask is not useful for a midpoint update.
         if(ticks[j].bid<=0.0 || ticks[j].ask<=0.0)continue;
         double mid=(ticks[j].bid+ticks[j].ask)*0.5;
         if(previous>0.0)
         {
            double d=mid-previous;
            int direction=d>_Point*0.1?1:d< -_Point*0.1?-1:0;
            if(direction!=0)
            {
               candleMoves++;
               if(direction>0)
               {
                  allUp++;
                  if(ticks[j].time_msc>=from+30000)lastUp++;
                  else firstUp++;
               }
               else
               {
                  allDown++;
                  if(ticks[j].time_msc>=from+30000)lastDown++;
                  else firstDown++;
               }
            }
         }
         previous=mid;
      }
      if(candleMoves<3)
      {
         g_tickStatus=StringFormat("TOO FEW MOVES candle %d",5-c);
         return false;
      }
   }
   int total=allUp+allDown,early=firstUp+firstDown,late=lastUp+lastDown;
   if(total<InpMinDirectionalTicks || early==0 || late==0)
   {g_tickStatus="INSUFFICIENT DIRECTIONAL TICKS";return false;}
   g_tickUp=allUp;g_tickDown=allDown;
   g_tickUpPct=100.0*allUp/total;
   g_tickDownPct=100.0*allDown/total;
   g_tickFirstBuyPct=100.0*firstUp/early;
   g_tickLastBuyPct=100.0*lastUp/late;
   g_tickStatus=StringFormat("UP %.0f%% DOWN %.0f%% LAST-UP %.0f%%",g_tickUpPct,g_tickDownPct,g_tickLastBuyPct);
   return true;
}

void Decide(const MqlRates &last)
{
   g_group++;
   g_lastUp=g_up;g_lastDown=g_down;
   g_lastDiff=g_up-g_down;
   g_lastVoteSell=g_voteSell;g_lastVoteBuy=g_voteBuy;
   int preliminary=0;
   if(g_lastDiff>=InpMinDifferencePips)preliminary=-1;
   else if(g_lastDiff<=-InpMinDifferencePips)preliminary=1;
   int side=0;
   if(preliminary!=0)
   {
      if((preliminary<0?g_voteSell:g_voteBuy)<InpMinWickVotes)
         g_lastAction=StringFormat("WAIT: WICK VOTES S%d B%d",g_voteSell,g_voteBuy);
      else if(!CalculateTickPressure())
         g_lastAction="WAIT: "+g_tickStatus;
      else
      {
         // Final-half tick pressure must confirm and strengthen vs earlier half.
         double preferred=preliminary>0?g_tickUpPct:g_tickDownPct;
         double early=preliminary>0?g_tickFirstBuyPct:100.0-g_tickFirstBuyPct;
         double late=preliminary>0?g_tickLastBuyPct:100.0-g_tickLastBuyPct;
         if(preferred>=InpTickDominance && late>=InpFinalHalfMinPct && late>=early)
            side=preliminary;
         else g_lastAction=StringFormat("WAIT: PRESSURE %.0f%% early %.0f%% late %.0f%%",preferred,early,late);
      }
   }
   else g_lastAction="WAIT: wick-sum difference too small";
   g_lastSignal=side;
   LabelDecision(last,side);
   // Do not overwrite informative WAIT reasons in ExecuteSignal.
   if(side!=0)ExecuteSignal(side);
   else Print("PLASA TICK CONSENSUS: ",g_lastAction);
}
void ClosedM1()
{
   MqlRates bars[];
   ArraySetAsSeries(bars,true);
   if(CopyRates(_Symbol,PERIOD_M1,1,1,bars)!=1)return;
   MqlRates bar=bars[0];
   if(g_count==0)g_groupStart=bar.time;
   double upper=MathMax(0.0,bar.high-MathMax(bar.open,bar.close))/InpPipSize;
   double lower=MathMax(0.0,MathMin(bar.open,bar.close)-bar.low)/InpPipSize;
   g_up+=upper;
   g_down+=lower;
   if(upper>lower+0.000001)g_voteSell++;
   else if(lower>upper+0.000001)g_voteBuy++;
   g_count++;
   LabelCandle(bar,g_count);
   if(g_count==5)
   {
      Decide(bar);
      g_count=0;
      g_up=0.0;
      g_down=0.0;
      g_voteSell=0;g_voteBuy=0;
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
      ObjectSetInteger(0,bg,OBJPROP_YSIZE,210);
      ObjectSetInteger(0,bg,OBJPROP_BGCOLOR,C'18,28,42');
      ObjectSetInteger(0,bg,OBJPROP_COLOR,C'70,90,114');
      ObjectSetInteger(0,bg,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,bg,OBJPROP_SELECTABLE,false);
   }
   int buys,sells;
   int total=OwnedCount(buys,sells);
   PanelLine(0,"PLASA | 5 WICKS + TICKS | M1",clrAqua);
   PanelLine(1,StringFormat("COUNT %d/5   UP %.1fp   DOWN %.1fp",g_count,g_up,g_down),clrWhite);
   string signal=g_lastSignal>0?"BUY":g_lastSignal<0?"SELL":"WAIT";
   PanelLine(2,StringFormat("LAST %s | DIFF %+.1fp | MIN %.1fp",
                           signal,g_lastDiff,InpMinDifferencePips),clrYellow);
   PanelLine(3,StringFormat("VOTES CURRENT S%d/B%d  | LAST S%d/B%d",
                   g_voteSell,g_voteBuy,g_lastVoteSell,g_lastVoteBuy),clrYellow);
   PanelLine(4,StringFormat("TICKS UP %.0f%% DOWN %.0f%%",g_tickUpPct,g_tickDownPct),clrWhite);
   PanelLine(5,StringFormat("OPEN %d (B%d/S%d) | FLOAT $%.2f",
                  total,buys,sells,FloatingPL()),clrWhite);
   PanelLine(6,"LAST: "+StringSubstr(g_lastAction,0,58),clrSilver);
   PanelLine(7,"TEST ONLY | NO SL / TP / LIMIT",clrTomato);
}
int OnInit()
{
   if(InpMinWickVotes<1 || InpMinWickVotes>5 || InpTickDominance<=50.0 ||
      InpTickDominance>100.0 || InpFinalHalfMinPct<50.0 || InpFinalHalfMinPct>100.0 ||
      InpMinTicksPerCandle<2 || InpMinDirectionalTicks<10 ||
      InpPipSize<=0.0 || InpMinDifferencePips<0.0 ||
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
   DrawPanel();
   Print("PLASA 6.01 START: five M1 wicks + wick voting + broker quote-tick pressure");
   return INIT_SUCCEEDED;
}
void OnTick()
{
   datetime now=iTime(_Symbol,PERIOD_M1,0);
   if(now!=0 && now!=g_lastM1)
   {
      g_lastM1=now;
      ClosedM1();
      DrawPanel();
   }
}
void OnDeinit(const int reason)
{
   for(int i=0;i<8;i++)ObjectDelete(0,g_prefix+"P"+IntegerToString(i));
   ObjectDelete(0,g_prefix+"BG");
   // Historical candle count labels intentionally remain on chart.
}
