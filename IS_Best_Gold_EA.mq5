//+------------------------------------------------------------------+
//|                                              IS_Best_Gold_EA.mq5 |
//|                                           www.t.me/invest_sniper |
//|                                                                  |
//| IS Best Gold EA.mq4 (MT4) → MT5 변환판                            |
//| - 주문(Order) 기반 → 포지션(Position) / 거래내역(Deal) 기반으로 변경 |
//| - 매매 로직·파라미터·정보 패널은 원본과 동일하게 유지              |
//| - 그리드(추가 진입) 구조상 헤징(Hedging) 계좌 전용                 |
//+------------------------------------------------------------------+
#property copyright "www.t.me/invest_sniper"
#property link      "https://www.t.me/invest_sniper"
#property version   "1.00"

#include <Trade\Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
//|========================= 파라미터 ===============================|
//+------------------------------------------------------------------+
input double    LotPercent       =0.01;       // 잔고 대비 랏 비율
input double    StopLossPercent  =0;          // 손절 (잔고 대비 %, 0 = 사용 안 함)
input int       TakeProfit       =300;        // 그리드 익절 (1랏당 금액)
input int       Trail            =800;        // 트레일링 간격 (포인트)
input int       TrailStart       =600;        // 트레일링 시작 / 본절 이익 (포인트)
input int       AvBarPercent     =100;        // 평균 봉 크기 대비 진입 기준 (%)
input int       MinimumBarSize   =200;        // 최소 진입 기준 봉 크기 (포인트)
input int       PeriodBar        =100;        // 평균 봉 크기 계산 기간
input int       BarProcessing    =100;        // 고점/저점 탐색 봉 수
input int       MaxSpread        =10;         // 최대 허용 스프레드 (포인트)
input bool      UseAddOrder      =true;       // 추가 진입(그리드) 사용
input int       MaxOrders        =100;        // 최대 포지션 수
input int       TimeStart        =2;          // 거래 시작 시각 (서버 시간)
input int       TimeEnd          =23;         // 거래 종료 시각 (서버 시간)
input int       Magic            =2025;       // 매직넘버
input bool      Info             =true;       // 정보 패널 표시
input color     TextColor        =clrWhite;   // 패널 글자색
input color     InfoDataColor    =clrDodgerBlue; // 패널 데이터 글자색
input color     FonColor         =clrBlack;   // 패널 배경색
input int       FontSizeInfo     =7;          // 패널 글자 크기
//+------------------------------------------------------------------+
//|======================= 추가 변수 ================================|
//+------------------------------------------------------------------+
string           Comemt           ="Best Gold t.me/invest_sniper";
int              SpeedEA          =200;
color            FonButtonBuy     =clrBlue;
color            FonButtonSell    =clrRed;
color            TextButtonBS     =clrWhite;
color            ButtonBorder     =clrBlue;
color            ClickButton      =clrBlack;
int              D,Spread;
double           Lot              =0;
int              DTime            =0;
double           DPrice           =0;
double           GapBar;
//+------------------------------------------------------------------+
//|======================= 라이선스 변수 ============================|
//+------------------------------------------------------------------+
bool   Demo             =false;
long   AccNumber        =0;
bool   LimitLicense     =true;
int    DeyLicense       =7;
int    DeyLimit         =0;
//+------------------------------------------------------------------+
//|========================= 초기화 =================================|
//+------------------------------------------------------------------+
int OnInit()
{
EventSetMillisecondTimer(SpeedEA);
D=1;
if(_Digits==5 || _Digits==3)
{D=10;}
trade.SetExpertMagicNumber(Magic);
trade.SetTypeFillingBySymbol(_Symbol);
if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
{Print("경고: 헤징 계좌가 아닙니다. 그리드 추가 진입이 하나의 포지션으로 합쳐져 원본과 다르게 동작합니다.");}
return(INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
//|======================== 종료 처리 ===============================|
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
EventKillTimer();
ObjectsDeleteAll(0,-1,OBJ_LABEL);
ObjectsDeleteAll(0,-1,OBJ_BUTTON);
ObjectsDeleteAll(0,-1,OBJ_RECTANGLE_LABEL);
}
//+------------------------------------------------------------------+
//|========================== 시작 ==================================|
//+------------------------------------------------------------------+
void OnTick()
{
//======= 랏 계산
Lot=CalcLot();
//============== 계좌번호 제한 ========================
if(AccNumber>0 && AccountInfoInteger(ACCOUNT_LOGIN)!=AccNumber)
{

}
else
{
bool IsDemoAcc=(AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_DEMO);
bool GoBuy =false;
bool GoSell =false;
//---------데모 제한-------
if(Demo && IsDemoAcc==false)
{

}
//============ 제한이 없거나 데모 계좌인 경우 ==================
if(!Demo || (Demo && IsDemoAcc==true))
{
MqlDateTime tm;
TimeToStruct(TimeCurrent(),tm);
//======= 진입 조건
if(tm.hour>=TimeStart && tm.hour<TimeEnd)
{
Spread=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);

double Open0 =iOpen(_Symbol,_Period,0);
double Close0=iClose(_Symbol,_Period,0);

if(DTime==0 || DTime!=tm.sec)
{DPrice=Close0;
 DTime=tm.sec;}

int LowBar=iLowest(_Symbol,_Period,MODE_LOW,BarProcessing,0);
int HighBar=iHighest(_Symbol,_Period,MODE_HIGH,BarProcessing,0);

double AvBar=AverageBar(PeriodBar);
if(AvBar/100*AvBarPercent<MinimumBarSize)
{GapBar=MinimumBarSize;}
else
{GapBar=AvBar/100*AvBarPercent;}

if(Spread<=MaxSpread)
{
if(Open0>Close0 && DPrice-GapBar*_Point>=Close0 && LowBar!=-1 && LowBar!=0 && LowBar!=1)
  {GoSell=true;}
if(Open0<Close0 && DPrice+GapBar*_Point<=Close0 && HighBar!=-1 && HighBar!=0 && HighBar!=1)
  {GoBuy=true;}
}
//======= 최초 진입
if(Count(-1)==0 && GoSell && CountBarHist(-1)==0)
{trade.SetDeviationInPoints(5);
 trade.Sell(Lot,_Symbol,SymbolInfoDouble(_Symbol,SYMBOL_BID),0,0,Comemt);}

if(Count(-1)==0 && GoBuy && CountBarHist(-1)==0)
{trade.SetDeviationInPoints(5);
 trade.Buy(Lot,_Symbol,SymbolInfoDouble(_Symbol,SYMBOL_ASK),0,0,Comemt);}
}
}
//======= 그리드 추가 진입
if(UseAddOrder && Count(-1)<MaxOrders)
{
long LimitOrders=AccountInfoInteger(ACCOUNT_LIMIT_ORDERS);
if((CountAll(-1)<LimitOrders || LimitOrders==0) && CountBar(-1)==0)
{
if(Count(POSITION_TYPE_BUY)>0 && GoBuy)
{trade.SetDeviationInPoints(10);
 trade.Buy(Lot,_Symbol,SymbolInfoDouble(_Symbol,SYMBOL_ASK),0,0,Comemt);}

if(Count(POSITION_TYPE_SELL)>0 && GoSell)
{trade.SetDeviationInPoints(10);
 trade.Sell(Lot,_Symbol,SymbolInfoDouble(_Symbol,SYMBOL_BID),0,0,Comemt);}
}
}
//======= 목표 수익 도달 시 전체 청산
double ProfProc=AllLots(-1)*TakeProfit;
if(ProfitAll(-1)>=ProfProc && ProfProc!=0 && Count(-1)>1)
{
ClosePos();
}
//--- 잔고 대비 % 손절
double LossProc=(AccountInfoDouble(ACCOUNT_BALANCE)/100)*StopLossPercent*(-1);
if(ProfitAll(-1)<LossProc && LossProc!=0)
{
ClosePos();
}
//======= 단일 포지션 트레일링
if(CountAll(-1)==1) {Trailing();}
//======= 차트 정보 표시
if(Info)
{
   RectLabelCreate3("INFO_fon",220,20,200,225,FonColor);

   PutLabel("INFO_LOGO",200,24,"Telegram @INVEST_SNIPER");
   PutLabel("INFO_Line",215,27,"___________________________");
   PutLabel_("INFO_txt1",215,45,"Account information");
   PutLabel("INFO_Line2",215,47,"___________________________");
   PutLabel("INFO_txt2",215,65,"Minimum stop:");
   PutLabel("INFO_txt3",215,80,"Average Bar Size:");
   PutLabel("INFO_txt4",215,95,"Bar Size for Open:");
   PutLabel("INFO_txt5",215,110,"Minimum Bar Size:");
   PutLabel("INFO_Line3",215,112,"___________________________");
   PutLabel_("INFO_txt6",215,130,"Profit on account");
   PutLabel("INFO_Line4",215,132,"___________________________");
   PutLabel("INFO_txt7",215,150,"Balance:");
   PutLabel("INFO_txt8",215,165,"Current Profit:");
   PutLabel("INFO_txt9",215,180,"Profit for today:");
   PutLabel("INFO_txt10",215,195,"Profit for yesterday:");
   PutLabel("INFO_txt11",215,210,"Profit for week:");
   PutLabel("INFO_txt12",215,225,"Profit for month:");

   PutLabel_("INFO_txt13",85,65,IntegerToString(SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)));
   PutLabel_("INFO_txt14",85,80,DoubleToString(AverageBar(PeriodBar),2));
   PutLabel_("INFO_txt15",85,95,DoubleToString(GapBar,2));
   PutLabel_("INFO_txt16",85,110,IntegerToString(MinimumBarSize));
   PutLabel_("INFO_txt17",85,150,DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2));
   PutLabel_("INFO_txt18",85,165,DoubleToString(ProfitAll(-1),2));
   PutLabel_("INFO_txt19",85,180,DoubleToString(ProfitDey(-1),2));
   PutLabel_("INFO_txt20",85,195,DoubleToString(ProfitTuDey(-1),2));
   PutLabel_("INFO_txt21",85,210,DoubleToString(ProfitWeek(-1),2));
   PutLabel_("INFO_txt22",85,225,DoubleToString(ProfitMontag(-1),2));

   PutButtonBS("TRADEs_B",220,245,"BUY           " + DoubleToString(Lot,2),100,22,FonButtonBuy,TextButtonBS);
   PutButtonBS("TRADEs_S",118,245,"SELL           " + DoubleToString(Lot,2),100,22,FonButtonSell,TextButtonBS);
}
//======= 종료
}
}
//+------------------------------------------------------------------+
//|   버튼                                                           |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
//+------------------------------------------------------------------+
//   클릭 시 버튼 색 변경
//+------------------------------------------------------------------+
if(ObjectGetInteger(0,"TRADEs_B",OBJPROP_STATE))
 {ObjectSetInteger(0,"TRADEs_B",OBJPROP_BGCOLOR,ClickButton);}
else
 {ObjectSetInteger(0,"TRADEs_B",OBJPROP_BGCOLOR,FonButtonBuy);}
//------------------
if(ObjectGetInteger(0,"TRADEs_S",OBJPROP_STATE))
 {ObjectSetInteger(0,"TRADEs_S",OBJPROP_BGCOLOR,ClickButton);}
else
 {ObjectSetInteger(0,"TRADEs_S",OBJPROP_BGCOLOR,FonButtonSell);}
//------------------
//+------------------------------------------------------------------+
//    버튼 클릭 이벤트 처리
//+------------------------------------------------------------------+
if(id==CHARTEVENT_OBJECT_CLICK)
{string clickedChartObject=sparam;

if(clickedChartObject=="TRADEs_B")
  {trade.SetDeviationInPoints(10);
   trade.Buy(Lot,_Symbol,SymbolInfoDouble(_Symbol,SYMBOL_ASK),0,0,Comemt);
   ObjectSetInteger(0,"TRADEs_B",OBJPROP_STATE,false);}
if(clickedChartObject=="TRADEs_S")
  {trade.SetDeviationInPoints(10);
   trade.Sell(Lot,_Symbol,SymbolInfoDouble(_Symbol,SYMBOL_BID),0,0,Comemt);
   ObjectSetInteger(0,"TRADEs_S",OBJPROP_STATE,false);}
//--- 차트 객체 다시 그리기
ChartRedraw();
}}

//+------------------------------------------------------------------+
//|========================== 함수 ==================================|
//+------------------------------------------------------------------+
//--- 랏 계산 (원본 공식 + 브로커 랏 단위 맞춤)
double CalcLot()
{
double TickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
double MinLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
double MaxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
double StepLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
double lot=0;
if(TickValue>0)
{lot=NormalizeDouble(AccountInfoDouble(ACCOUNT_BALANCE)/10*LotPercent/(TickValue*100*D),2);}
if(StepLot>0) {lot=MathFloor(lot/StepLot+1e-9)*StepLot;}
if(lot<MinLot) {lot=MinLot;}
if(lot>=MaxLot) {lot=MaxLot;}
return(NormalizeDouble(lot,2));
}
//--- 평균 봉 크기 (원본과 동일하게 정수로 절삭)
double AverageBar(int PerBar)
{double Size=0;
 int AvBar=0;
   for(int i=PerBar-1;i>=0;i--)
   {
    if(PerBar!=0) {Size+=(iHigh(_Symbol,_Period,i)-iLow(_Symbol,_Period,i))/_Point;}
    AvBar=(int)(Size/PerBar);
   }
   return(AvBar);}
//--- 전체 청산
void ClosePos()
{
 trade.SetDeviationInPoints(10);
 for(int i=PositionsTotal()-1;i>=0;i--)
 {ulong ticket=PositionGetTicket(i);
  if(ticket==0) continue;
  if(PositionGetInteger(POSITION_MAGIC)==Magic)
   {trade.PositionClose(ticket);}}
}
//--- 보유 랏 합계
double AllLots(int type)
{double lot=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {ulong ticket=PositionGetTicket(i);
    if(ticket==0) continue;
    if(PositionGetInteger(POSITION_MAGIC)==Magic && (type==-1 || PositionGetInteger(POSITION_TYPE)==type)) lot+=PositionGetDouble(POSITION_VOLUME);}
   return(lot);}
//======== 현재 봉에서 진입한 보유 포지션 수 ================
int CountBar(int type)
{
int count=0;
datetime BarTime=iTime(_Symbol,_Period,0);
for(int i=PositionsTotal()-1;i>=0;i--)
 {
 ulong ticket=PositionGetTicket(i);
 if(ticket==0) continue;
 if(PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==Magic && (datetime)PositionGetInteger(POSITION_TIME)>=BarTime && (type==-1 || PositionGetInteger(POSITION_TYPE)==type))
  {count++;}
 }
return(count);}
//======== 현재 봉에서 발생한 진입 거래 수 (거래내역) ================
int CountBarHist(int type)
{
int count=0;
datetime BarTime=iTime(_Symbol,_Period,0);
if(!HistorySelect(BarTime,TimeCurrent()+86400)) return(0);
for(int i=HistoryDealsTotal()-1;i>=0;i--)
 {
 ulong ticket=HistoryDealGetTicket(i);
 if(ticket==0) continue;
 if(HistoryDealGetString(ticket,DEAL_SYMBOL)==_Symbol && HistoryDealGetInteger(ticket,DEAL_MAGIC)==Magic
    && HistoryDealGetInteger(ticket,DEAL_ENTRY)==DEAL_ENTRY_IN && (datetime)HistoryDealGetInteger(ticket,DEAL_TIME)>=BarTime
    && (type==-1 || HistoryDealGetInteger(ticket,DEAL_TYPE)==type))
  {count++;}
 }
return(count);}
//--- 계좌 전체 포지션 수 (심볼 무관)
int CountAll(int type)
{
int count=0;
for(int i=PositionsTotal()-1;i>=0;i--)
 {
 ulong ticket=PositionGetTicket(i);
 if(ticket==0) continue;
 if(PositionGetInteger(POSITION_MAGIC)==Magic && (type==-1 || PositionGetInteger(POSITION_TYPE)==type))
  {count++;}
 }
return(count);}
//======= 트레일링
void Trailing()
{ulong tic;
 double Price,Stop,TP;
 double Bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
 double Ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
for(int i=PositionsTotal()-1;i>=0;i--)
{tic=PositionGetTicket(i);
 if(tic==0) continue;
 if(PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==Magic)
{
Price=PositionGetDouble(POSITION_PRICE_OPEN);
Stop=PositionGetDouble(POSITION_SL);
TP=PositionGetDouble(POSITION_TP);

if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY && Trail!=0)
   {if((Stop<Price || Stop==0) && Bid-(Trail+TrailStart)*_Point>=Price)
      {trade.PositionModify(tic,NormalizeDouble(Price+TrailStart*_Point,_Digits),TP);}
    if(Stop>=Price && Bid-Trail*_Point>Stop)
      {trade.PositionModify(tic,NormalizeDouble(Bid-Trail*_Point,_Digits),TP);}}

if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL && Trail!=0)
   {if((Stop>Price || Stop==0) && Ask+(Trail+TrailStart)*_Point<=Price)
      {trade.PositionModify(tic,NormalizeDouble(Price-TrailStart*_Point,_Digits),TP);}
    if(Stop<=Price && Stop!=0 && Ask+Trail*_Point<Stop)
      {trade.PositionModify(tic,NormalizeDouble(Ask+Trail*_Point,_Digits),TP);}}
}}}
//======= 현재 심볼 포지션 수
int Count(int type)
{
int count=0;
for(int i=PositionsTotal()-1;i>=0;i--)
 {
 ulong ticket=PositionGetTicket(i);
 if(ticket==0) continue;
 if(PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==Magic && (type==-1 || PositionGetInteger(POSITION_TYPE)==type))
  {count++;}
 }
return(count);}
//======= 현재 평가 손익
double ProfitAll(int type)
{double Profit=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {ulong ticket=PositionGetTicket(i);
    if(ticket==0) continue;
    if(PositionGetInteger(POSITION_MAGIC)==Magic && (type==-1 || PositionGetInteger(POSITION_TYPE)==type))
     Profit+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);}
   return(Profit);}
//======= 기간별 확정 손익 (거래내역 기준)
//   MT5 는 수수료가 진입·청산 거래에 각각 기록되므로 기간 내 모든 거래의
//   손익+스왑+수수료+fee 를 합산 (진입 수수료는 진입 시점 기간에 포함됨)
double ProfitHist(int type,datetime from,datetime to)
{double Profit=0;
   if(!HistorySelect(from,to)) return(0);
   for(int i=HistoryDealsTotal()-1;i>=0;i--)
   {ulong ticket=HistoryDealGetTicket(i);
    if(ticket==0) continue;
    if(HistoryDealGetInteger(ticket,DEAL_MAGIC)!=Magic) continue;
    long DealType=HistoryDealGetInteger(ticket,DEAL_TYPE);
    if(DealType!=DEAL_TYPE_BUY && DealType!=DEAL_TYPE_SELL) continue;
    datetime DealTime=(datetime)HistoryDealGetInteger(ticket,DEAL_TIME);
    if(DealTime<from || DealTime>=to) continue;
    if(type!=-1)
     {//--- 청산 거래의 방향은 포지션 방향의 반대
      long PosType=(HistoryDealGetInteger(ticket,DEAL_ENTRY)==DEAL_ENTRY_IN) ? DealType : 1-DealType;
      if(PosType!=type) continue;}
    Profit+=HistoryDealGetDouble(ticket,DEAL_PROFIT)+HistoryDealGetDouble(ticket,DEAL_SWAP)
           +HistoryDealGetDouble(ticket,DEAL_COMMISSION)+HistoryDealGetDouble(ticket,DEAL_FEE);}
   return(Profit);}
//======= 오늘 확정 손익
double ProfitDey(int type)
{return(ProfitHist(type,iTime(_Symbol,PERIOD_D1,0),TimeCurrent()+86400));}
//======= 어제 확정 손익
double ProfitTuDey(int type)
{return(ProfitHist(type,iTime(_Symbol,PERIOD_D1,1),iTime(_Symbol,PERIOD_D1,0)));}
//======= 그제 확정 손익
double ProfitEsTuDey(int type)
{return(ProfitHist(type,iTime(_Symbol,PERIOD_D1,2),iTime(_Symbol,PERIOD_D1,1)));}
//======= 이번 주 확정 손익
double ProfitWeek(int type)
{return(ProfitHist(type,iTime(_Symbol,PERIOD_W1,0),TimeCurrent()+86400));}
//======= 이번 달 확정 손익
double ProfitMontag(int type)
{return(ProfitHist(type,iTime(_Symbol,PERIOD_MN1,0),TimeCurrent()+86400));}
//======= 텍스트 라벨 생성
void PutLabel(string name,int x,int y,string text)
  {ObjectCreate(0,name,OBJ_LABEL,0,0,0);
//--- 좌표
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
//--- 기준 모서리 (MT4 의 1 = MT5 의 CORNER_RIGHT_UPPER)
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
//--- 텍스트
   ObjectSetString(0,name,OBJPROP_TEXT,text);
//--- 글꼴
   ObjectSetString(0,name,OBJPROP_FONT,"Arial");
//--- 글자 크기
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,FontSizeInfo);
//--- 색상
   ObjectSetInteger(0,name,OBJPROP_COLOR,TextColor);
//--- 객체 목록 표시 여부
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,false);
//--- 전경(false) / 배경(true)
   ObjectSetInteger(0,name,OBJPROP_BACK,false);}

//======= 데이터 텍스트 라벨 생성
void PutLabel_(string name,int x,int y,string text)
  {ObjectCreate(0,name,OBJ_LABEL,0,0,0);
//--- 좌표
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
//--- 기준 모서리
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
//--- 텍스트
   ObjectSetString(0,name,OBJPROP_TEXT,text);
//--- 글꼴
   ObjectSetString(0,name,OBJPROP_FONT,"Arial");
//--- 글자 크기
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,FontSizeInfo);
//--- 색상
   ObjectSetInteger(0,name,OBJPROP_COLOR,InfoDataColor);
//--- 객체 목록 표시 여부
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,false);
//--- 전경(false) / 배경(true)
   ObjectSetInteger(0,name,OBJPROP_BACK,false);}

//======= 사각형 배경 생성
bool RectLabelCreate3(string name,int x,int y,int width,int height,color back_clr)
  {ResetLastError();
//--- 사각형 라벨 생성 (이미 있으면 그대로 둠)
if(ObjectFind(0,name)<0 && !ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0))
  {return(false);}
//--- 좌표
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
//--- 크기
   ObjectSetInteger(0,name,OBJPROP_XSIZE,width);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,height);
//--- 배경색
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,back_clr);
//--- 테두리 형태
   ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_SUNKEN);
//--- 기준 모서리
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
//--- 테두리 색 (Flat 모드)
   ObjectSetInteger(0,name,OBJPROP_COLOR,clrBlue);
//--- 테두리 두께
   ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
//--- 전경(false) / 배경(true)
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
//--- 객체 목록 표시 여부
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,false);
return(true);}
//--- 매수/매도 버튼

void PutButtonBS(string name,int x,int y,string text,int BWidth2,int BHeigh2,color FonButtonBS,color TXTButtonBS)
  {if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
//--- 좌표
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
//--- 크기
   ObjectSetInteger(0,name,OBJPROP_XSIZE,BWidth2);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,BHeigh2);
//--- 기준 모서리
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
//--- 텍스트
   ObjectSetString(0,name,OBJPROP_TEXT,text);
//--- 글꼴
   ObjectSetString(0,name,OBJPROP_FONT,"Arial");
//--- 글자 크기
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,FontSizeInfo);
//--- 글자색
   ObjectSetInteger(0,name,OBJPROP_COLOR,TXTButtonBS);
//--- 배경색
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,FonButtonBS);
//--- 테두리색
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,ButtonBorder);
//--- 객체 목록 표시 여부
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,false);
//--- 전경(false) / 배경(true)
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
  }
//--- 타이머 (원본과 동일하게 200ms 마다 OnTick 실행)

void OnTimer()
  {
   OnTick();
  }
