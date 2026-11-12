// PLASA S/R ZONES v1.00 — indicator, no external dependencies
#property strict
#property version "1.00"
#property indicator_chart_window
#property indicator_plots 0

input int InpZoneLifeBars=48;        // 12 hours at M15
input double InpPip=0.10;           // Gold pip price units
input double InpClusterPips=30.0;   // Maximum distance between reactions
input double InpZoneHalfWidthPips=15.0;
input bool InpDrawZones=true;

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

SRZone gSupport,gResistance;
datetime gLastM15=0;
int OnInit()
{
 if(InpZoneLifeBars<6||InpPip<=0||InpClusterPips<=0||InpZoneHalfWidthPips<=0)
   return INIT_PARAMETERS_INCORRECT;
 ClearZone(gSupport);ClearZone(gResistance);
 return INIT_SUCCEEDED;
}
int OnCalculate(const int total,const int prev,const datetime &time[],
 const double &open[],const double &high[],const double &low[],
 const double &close[],const long &tick_volume[],const long &volume[],
 const int &spread[])
{
 datetime now=iTime(_Symbol,PERIOD_M15,0);
 if(now>0&&now!=gLastM15)
 {
  gLastM15=now;
  ScanZones(gSupport,gResistance,InpZoneLifeBars,InpClusterPips,InpZoneHalfWidthPips,InpPip);
  if(InpDrawZones)
  {
   DrawSRBox("PLASA_SR_IND_SUPPORT",gSupport,clrForestGreen);
   DrawSRBox("PLASA_SR_IND_RESISTANCE",gResistance,clrFireBrick);
  }
 }
 return total;
}
void OnDeinit(const int reason)
{
 ObjectDelete(0,"PLASA_SR_IND_SUPPORT");
 ObjectDelete(0,"PLASA_SR_IND_SUPPORT_T");
 ObjectDelete(0,"PLASA_SR_IND_RESISTANCE");
 ObjectDelete(0,"PLASA_SR_IND_RESISTANCE_T");
}
