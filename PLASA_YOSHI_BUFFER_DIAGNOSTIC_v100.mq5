//+------------------------------------------------------------------+
//| PLASA Yoshi Buffer Diagnostic v1.00                               |
//| READ-ONLY: never sends orders. For MT5 Strategy Tester.           |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"
#property description "Tests iCustom and CopyBuffer accessibility of Rejection Zones Yoshi Pro. No trades."
#property tester_indicator "Market\\Rejection Zones Yoshi Pro.ex5"

input string InpIndicatorName = "Market\\Rejection Zones Yoshi Pro";
input int    InpBufferCount = 32;
input int    InpPrintFirstValues = 10;
input bool   InpReadCurrentBar = true;
input bool   InpReadLastClosedBar = true;
input int    InpRetrySeconds = 5;
input int    InpMaxAttempts = 6;

int g_handle=INVALID_HANDLE;
int g_attempts=0;
int g_lastError=0;
bool g_done=false;
string g_status="INIT";

string NumberString(const double v)
{
 if(!MathIsValidNumber(v))return "NaN";
 if(v==EMPTY_VALUE)return "EMPTY_VALUE";
 return DoubleToString(v,8);
}
void Probe()
{
 if(g_done||g_handle==INVALID_HANDLE)return;
 g_attempts++;
 int calculated=BarsCalculated(g_handle);
 PrintFormat("PLASA_YOSHI_DIAG attempt=%d BarsCalculated=%d symbol=%s chartTF=%s",
             g_attempts,calculated,_Symbol,EnumToString(_Period));
 if(calculated<=2)
 {
  g_status=StringFormat("Indicator loading (%d bars); attempt %d/%d",calculated,g_attempts,InpMaxAttempts);
  if(g_attempts>=InpMaxAttempts)
  {Print("PLASA_YOSHI_DIAG: indicator never became ready; check installation and Tester Journal.");g_done=true;}
  return;
 }
 int readable=0,nonempty=0,failed=0,shown=0;
 for(int idx=0;idx<InpBufferCount;idx++)
 {
  double current[],closed[];
  double v0=EMPTY_VALUE,v1=EMPTY_VALUE;
  bool ok0=false,ok1=false;
  int e0=0,e1=0;
  if(InpReadCurrentBar)
  {
   ResetLastError();
   ok0=(CopyBuffer(g_handle,idx,0,1,current)==1);
   e0=GetLastError();
   if(ok0)v0=current[0];
  }
  if(InpReadLastClosedBar)
  {
   ResetLastError();
   ok1=(CopyBuffer(g_handle,idx,1,1,closed)==1);
   e1=GetLastError();
   if(ok1)v1=closed[0];
  }
  if(ok0||ok1)
  {
   readable++;
   bool hasValue=(ok0&&v0!=EMPTY_VALUE&&MathIsValidNumber(v0))||
                 (ok1&&v1!=EMPTY_VALUE&&MathIsValidNumber(v1));
   if(hasValue)nonempty++;
   if(shown<InpPrintFirstValues)
   {
    PrintFormat("PLASA_YOSHI_BUFFER %02d: shift0=%s (%s), shift1=%s (%s)",
         idx,ok0?NumberString(v0):"unavailable",ok0?"OK":IntegerToString(e0),
         ok1?NumberString(v1):"unavailable",ok1?"OK":IntegerToString(e1));
    shown++;
   }
  }
  else
  {
   failed++;
   if(idx<3)PrintFormat("PLASA_YOSHI_BUFFER %02d: unavailable errors shift0=%d shift1=%d",idx,e0,e1);
  }
 }
 PrintFormat("PLASA_YOSHI_RESULT tested=%d readable=%d nonEmpty=%d failed=%d",
              InpBufferCount,readable,nonempty,failed);
 g_status=StringFormat("READABLE %d / %d | VALUES %d | attempt %d",
                       readable,InpBufferCount,nonempty,g_attempts);
 // Buffers may represent indicators' internals rather than zone prices.
 if(nonempty>0||g_attempts>=InpMaxAttempts)
 {g_done=true;Print("PLASA_YOSHI_DIAG: finished. Send PLASA_YOSHI_BUFFER and PLASA_YOSHI_RESULT Journal rows.");}
}
int OnInit()
{
 if(InpBufferCount<1||InpBufferCount>128||InpPrintFirstValues<1||
    InpPrintFirstValues>128||InpRetrySeconds<1||InpMaxAttempts<1||
    (!InpReadCurrentBar&&!InpReadLastClosedBar))return INIT_PARAMETERS_INCORRECT;
 ResetLastError();
 g_handle=iCustom(_Symbol,_Period,InpIndicatorName);
 g_lastError=GetLastError();
 if(g_handle==INVALID_HANDLE)
 {
  g_status=StringFormat("iCustom FAILED, error %d",g_lastError);
  PrintFormat("PLASA_YOSHI_DIAG: iCustom FAILED name='%s' error=%d",InpIndicatorName,g_lastError);
  Print("PLASA_YOSHI_DIAG: Check exact file name under MQL5/Indicators/Market, same terminal, and tester license.");
  g_done=true;
 }
 else
 {
  PrintFormat("PLASA_YOSHI_DIAG: iCustom handle OK, path='%s'",InpIndicatorName);
  g_status="iCustom OK; waiting for buffer scan";
 }
 EventSetTimer(InpRetrySeconds);
 return INIT_SUCCEEDED;
}
void OnTimer()
{
 Probe();
 Comment("PLASA / YOSHI DIAGNOSTIC v1.00\n",
         "NO TRADING\n","STATUS: ",g_status,"\n",
         "Indicator: ",InpIndicatorName,"\n",
         "Check Strategy Tester -> Journal");
}
void OnTick(){}
void OnDeinit(const int reason)
{
 EventKillTimer();
 if(g_handle!=INVALID_HANDLE)IndicatorRelease(g_handle);
 Comment("");
}