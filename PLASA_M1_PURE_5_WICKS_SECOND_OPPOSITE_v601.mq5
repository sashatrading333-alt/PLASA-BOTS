//+------------------------------------------------------------------+
//| PLASA 5 Wicks PURE v6.01                                          |
//| CLEAN RESEARCH EA: five closed M1 candles, upper vs lower wicks.  |
//| No SL/TP, no trailing, no extra confirmations or daily limits.    |
//| DEMO / Strategy Tester ONLY.                                      |
//+------------------------------------------------------------------+
#property strict
#property version "6.01"
#property description "Pure five M1 candle wick-sum comparison. DEMO/tester only."
#include <Trade/Trade.mqh>

input double InpLots               = 0.01;       // Fixed volume per new signal
input double InpPipSize            = 0.10;       // One gold pip = 0.10 price units
input double InpMinDifferencePips  = 20.0;       // Minimum upper/lower wick-sum difference
input int    InpMaxPositions       = 10;         // Max concurrent positions, same side
input ulong  InpMagic              = 26111267;   // Separate from all previous EAs
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
     StringFormat("%s UP%.0f DN%.0f",result,g_lastUp,g_lastDown),c,9);
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
      g_pendingOpposite=0;
      g_oppositeCount=0;
      g_lastAction="WAIT: no wick signal; opposite counter reset";
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
      if(g_pendingOpposite==side)g_oppositeCount++;
      else {g_pendingOpposite=side;g_oppositeCount=1;}
      if(g_oppositeCount<2)
      {
         g_lastAction=StringFormat("OPPOSITE %s 1/2: hold positions",side>0?"BUY":"SELL");
         return;
      }
      if(!CloseAllOwned())
      {
         g_lastAction="REVERSAL BLOCKED: old positions not closed";
         return;
      }
      total=0;
      g_pendingOpposite=0;
      g_oppositeCount=0;
   }
   else
   {
      g_pendingOpposite=0;
      g_oppositeCount=0;
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
   ExecuteSignal(side);
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
   g_count++;
   LabelCandle(bar,g_count);
   if(g_count==5)
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
      ObjectSetInteger(0,bg,OBJPROP_YSIZE,169);
      ObjectSetInteger(0,bg,OBJPROP_BGCOLOR,C'18,28,42');
      ObjectSetInteger(0,bg,OBJPROP_COLOR,C'70,90,114');
      ObjectSetInteger(0,bg,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,bg,OBJPROP_SELECTABLE,false);
   }
   int buys,sells;
   int total=OwnedCount(buys,sells);
   PanelLine(0,"PLASA | PURE 5 WICKS v6.01 | M1",clrAqua);
   PanelLine(1,StringFormat("COUNT %d/5   UP %.1fp   DOWN %.1fp",g_count,g_up,g_down),clrWhite);
   string signal=g_lastSignal>0?"BUY":g_lastSignal<0?"SELL":"WAIT";
   PanelLine(2,StringFormat("LAST %s | DIFF %+.1fp | MIN %.1fp",
                           signal,g_lastDiff,InpMinDifferencePips),clrYellow);
   PanelLine(3,StringFormat("OPEN %d (B%d/S%d) | FLOAT $%.2f",
                  total,buys,sells,FloatingPL()),clrWhite);
   PanelLine(4,"LAST: "+StringSubstr(g_lastAction,0,58),clrSilver);
   PanelLine(5,StringFormat("REVERSAL: %d/2 | TEST ONLY NO SL/TP",g_oppositeCount),clrTomato);
}
int OnInit()
{
   if(InpPipSize<=0.0 || InpMinDifferencePips<0.0 ||
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
   Print("PLASA PURE 6.01 START: five M1 wick strategy, reverse on second consecutive opposite signal");
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
   for(int i=0;i<6;i++)ObjectDelete(0,g_prefix+"P"+IntegerToString(i));
   ObjectDelete(0,g_prefix+"BG");
   // Historical candle count labels intentionally remain on chart.
}
