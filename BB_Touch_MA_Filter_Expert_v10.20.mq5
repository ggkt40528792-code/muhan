//+------------------------------------------------------------------+
//|                           BB_Touch_MA_Filter_Expert_v10.20.mq5    |
//|                                                                  |
//| BB_Touch_Martingale_Expert_v10.00 기반 변경판                     |
//| - M1 SMA 60/120/240 배열 필터 추가 (신규 진입에만 적용)           |
//|     정배열(60>120>240): 신규 매수만 / 볼밴 하단 + InpBuyOffset 이하 |
//|     역배열(60<120<240): 신규 매도만 / 볼밴 상단 정확히 터치         |
//|     혼재              : 하단 터치 매수 / 상단 터치 매도 (기존 동일) |
//| - 기존 포지션의 물타기·익절·최대손실 청산은 배열과 무관하게 동작   |
//| - 비밀번호(보안 설정) 삭제                                        |
//| - 차트 우상단 표시: 현재손익(초록) / 오늘익절(노랑) / 배열 상태    |
//+------------------------------------------------------------------+
#property copyright "Code Expert"
#property link      "https://mql5.com"
#property version   "10.20"

#include <Trade\Trade.mqh>
CTrade trade;

enum ENUM_GRID_MODE
{
   MODE_BUY_ONLY     = 0,
   MODE_SELL_ONLY    = 1,
   MODE_BI_DIRECTION = 2
};

enum ENUM_MA_STATE
{
   MA_STATE_MIXED   = 0,   // 혼재
   MA_STATE_BULLISH = 1,   // 완전 정배열
   MA_STATE_BEARISH = 2    // 완전 역배열
};

//+------------------------------------------------------------------+
input group "--- 1. 자금 관리 설정 ---"
input double InpFixedLotSize = 0.01;      // 최초 진입 기본 수량 (LOT)

input group "--- 2. 매매 모드 ---"
input ENUM_GRID_MODE InpGridMode = MODE_BI_DIRECTION; // 매수 / 매도 / 양방향

input group "--- 3. 볼린저밴드 진입 설정 (M1) ---"
input int    InpBBPeriod    = 20;         // 볼린저밴드 기간
input double InpBBDeviation = 2.0;        // 볼린저밴드 편차

input group "--- 4. 이평선 배열 필터 (M1 / 단순이동평균) ---"
input bool   InpUseMAFilter = true;       // 이평선 배열 필터 사용
input int    InpMAFast      = 60;         // 단기 이평선 기간
input int    InpMAMid       = 120;        // 중기 이평선 기간
input int    InpMASlow      = 240;        // 장기 이평선 기간
input double InpBuyOffset   = 1.0;        // 정배열 매수 위치: 볼밴 하단 + 이 값 (가격 단위, 골드 1.0 = $1)

input group "--- 5. 물타기 설정 (고정 간격) ---"
input double InpGridDistance = 5.0;       // 물타기 간격 (가격 단위, 골드 5.0 = $5)
input double Martingale      = 1.5;       // 물타기 랏 배수
input int    MaxTrades       = 8;         // 방향별 최대 포지션 개수
input ulong  MagicNumber     = 123456;    // 매직넘버

input group "--- 6. 일괄 합산 청산 ---"
input double TPAmount = 3.0;              // 방향별 합산 익절 목표 금액 ($)

input group "--- 7. 사용시간대 (서버시간 / HHMM) ---"
input bool InpUseTimeRange1 = true;
input int  InpTimeStart1    = 110;        // 01:10
input int  InpTimeEnd1      = 2100;       // 21:00
input bool InpUseTimeRange2 = false;
input int  InpTimeStart2    = 0;
input int  InpTimeEnd2      = 0;
input bool InpUseTimeRange3 = false;
input int  InpTimeStart3    = 0;
input int  InpTimeEnd3      = 0;

input group "--- 8. 안전 장치 ---"
input int    InpMaxSpread     = 30;       // 최대 허용 스프레드 (POINTS)
input double InpMaxLossAmount = 300.0;    // 최대 허용 합산 손실금 ($) 초과 시 전체 청산
input double InpMaxBarRange   = 200.0;    // 직전 M1 캔들 최대 변동폭 (POINTS)

input group "--- 9. 청산 버튼 ---"
input bool InpConfirmClose = false;       // 청산 버튼 클릭 시 확인창 표시 (true = 한 번 더 확인)

//+------------------------------------------------------------------+
int      bbHandle     = INVALID_HANDLE;
int      maFastHandle = INVALID_HANDLE;
int      maMidHandle  = INVALID_HANDLE;
int      maSlowHandle = INVALID_HANDLE;
datetime lastCheckedBar = 0;

bool buyEnteredThisBar  = false;   // 같은 봉 최초 진입/재진입 중복 방지
bool sellEnteredThisBar = false;
bool buyGridTriggeredThisTick  = false;
bool sellGridTriggeredThisTick = false;

double lastBuyEntryPrice  = 0.0;
double lastSellEntryPrice = 0.0;
long   lastBuyEntryTimeMsc  = 0;
long   lastSellEntryTimeMsc = 0;

int    lastLoggedMAState = -1;          // 배열 변경 로그용 (-1 = 아직 없음)

string LABEL_CURRENT_PNL  = "EA_Label_CurrentPnL";
string LABEL_TODAY_PROFIT = "EA_Label_TodayProfit";
string LABEL_MA_STATE     = "EA_Label_MAState";
string BTN_CLOSE_ALL      = "EA_Btn_CloseAll";
bool   forceHistoryRefresh = false;   // 오늘익절 즉시 재계산 요청

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFillingBySymbol(_Symbol);

   bbHandle = iBands(_Symbol, PERIOD_M1, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   if(bbHandle == INVALID_HANDLE)
   {
      Print("볼린저밴드 핸들 생성 실패");
      return(INIT_FAILED);
   }

   if(InpUseMAFilter)
   {
      maFastHandle = iMA(_Symbol, PERIOD_M1, InpMAFast, 0, MODE_SMA, PRICE_CLOSE);
      maMidHandle  = iMA(_Symbol, PERIOD_M1, InpMAMid,  0, MODE_SMA, PRICE_CLOSE);
      maSlowHandle = iMA(_Symbol, PERIOD_M1, InpMASlow, 0, MODE_SMA, PRICE_CLOSE);
      if(maFastHandle == INVALID_HANDLE || maMidHandle == INVALID_HANDLE || maSlowHandle == INVALID_HANDLE)
      {
         Print("이동평균 핸들 생성 실패");
         return(INIT_FAILED);
      }
   }

   ObjectDelete(0, LABEL_CURRENT_PNL);
   ObjectDelete(0, LABEL_TODAY_PROFIT);
   ObjectDelete(0, LABEL_MA_STATE);

   CreateCloseButton();
   RestoreLatestEntryPrices();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(bbHandle != INVALID_HANDLE)     IndicatorRelease(bbHandle);
   if(maFastHandle != INVALID_HANDLE) IndicatorRelease(maFastHandle);
   if(maMidHandle != INVALID_HANDLE)  IndicatorRelease(maMidHandle);
   if(maSlowHandle != INVALID_HANDLE) IndicatorRelease(maSlowHandle);

   ObjectDelete(0, LABEL_CURRENT_PNL);
   ObjectDelete(0, LABEL_TODAY_PROFIT);
   ObjectDelete(0, LABEL_MA_STATE);
   ObjectDelete(0, BTN_CLOSE_ALL);
}

//+------------------------------------------------------------------+
//| 차트 이벤트: 청산 버튼 클릭                                       |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK || sparam != BTN_CLOSE_ALL)
      return;

   // 버튼 눌림 상태 원복
   ObjectSetInteger(0, BTN_CLOSE_ALL, OBJPROP_STATE, false);
   ChartRedraw(0);

   if(InpConfirmClose)
   {
      if(MessageBox("이 EA의 모든 포지션을 청산할까요?", "전체 청산", MB_YESNO | MB_ICONQUESTION) != IDYES)
         return;
   }

   Print("[수동 청산 버튼] 전체 포지션 시장가 청산");
   CloseAllPositions(POSITION_TYPE_BUY);
   CloseAllPositions(POSITION_TYPE_SELL);

   // 같은 봉에서 즉시 재진입 방지 + 오늘익절 즉시 갱신
   buyEnteredThisBar  = true;
   sellEnteredThisBar = true;
   forceHistoryRefresh = true;
}

//+------------------------------------------------------------------+
//| 청산 버튼 생성 (차트 왼쪽 아래)                                   |
//+------------------------------------------------------------------+
void CreateCloseButton()
{
   ObjectDelete(0, BTN_CLOSE_ALL);
   ObjectCreate(0, BTN_CLOSE_ALL, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, BTN_CLOSE_ALL, OBJPROP_CORNER, CORNER_LEFT_LOWER);
   ObjectSetInteger(0, BTN_CLOSE_ALL, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, BTN_CLOSE_ALL, OBJPROP_XDISTANCE, 15);
   ObjectSetInteger(0, BTN_CLOSE_ALL, OBJPROP_YDISTANCE, 60);   // 차트 하단에서 위로 띄우는 거리 (px) - 더 올리려면 값을 키우세요
   ObjectSetInteger(0, BTN_CLOSE_ALL, OBJPROP_XSIZE, 130);
   ObjectSetInteger(0, BTN_CLOSE_ALL, OBJPROP_YSIZE, 34);
   ObjectSetString(0, BTN_CLOSE_ALL, OBJPROP_TEXT, "전체 청산");
   ObjectSetString(0, BTN_CLOSE_ALL, OBJPROP_FONT, "맑은 고딕");
   ObjectSetInteger(0, BTN_CLOSE_ALL, OBJPROP_FONTSIZE, 11);
   ObjectSetInteger(0, BTN_CLOSE_ALL, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, BTN_CLOSE_ALL, OBJPROP_BGCOLOR, clrCrimson);
   ObjectSetInteger(0, BTN_CLOSE_ALL, OBJPROP_BORDER_COLOR, clrWhite);
   ObjectSetInteger(0, BTN_CLOSE_ALL, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, BTN_CLOSE_ALL, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, BTN_CLOSE_ALL, OBJPROP_ZORDER, 10);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| 이평선 배열 상태 판단 (M1 SMA, 현재 진행 중인 봉 기준)            |
//| 반환값 false = 데이터 준비 안 됨 (신규 진입 보류)                 |
//+------------------------------------------------------------------+
bool GetMAState(ENUM_MA_STATE &state)
{
   state = MA_STATE_MIXED;
   if(!InpUseMAFilter)
      return true;

   double fast[1], mid[1], slow[1];
   if(CopyBuffer(maFastHandle, 0, 0, 1, fast) != 1) return false;
   if(CopyBuffer(maMidHandle,  0, 0, 1, mid)  != 1) return false;
   if(CopyBuffer(maSlowHandle, 0, 0, 1, slow) != 1) return false;

   if(fast[0] > mid[0] && mid[0] > slow[0])
      state = MA_STATE_BULLISH;
   else if(fast[0] < mid[0] && mid[0] < slow[0])
      state = MA_STATE_BEARISH;
   else
      state = MA_STATE_MIXED;

   return true;
}

string MAStateText(ENUM_MA_STATE state, bool ready)
{
   if(!InpUseMAFilter) return "배열: 필터 꺼짐";
   if(!ready)          return "배열: 데이터 대기";
   if(state == MA_STATE_BULLISH) return "배열: 정배열 (매수만)";
   if(state == MA_STATE_BEARISH) return "배열: 역배열 (매도만)";
   return "배열: 혼재 (양방향)";
}

color MAStateColor(ENUM_MA_STATE state, bool ready)
{
   if(!InpUseMAFilter || !ready) return clrSilver;
   if(state == MA_STATE_BULLISH) return clrDodgerBlue;
   if(state == MA_STATE_BEARISH) return clrTomato;
   return clrWhite;
}

//+------------------------------------------------------------------+
void OnTick()
{
   // 새 봉 초기화
   datetime currentBarTime = iTime(_Symbol, PERIOD_M1, 0);
   if(currentBarTime != lastCheckedBar)
   {
      lastCheckedBar = currentBarTime;
      buyEnteredThisBar  = false;
      sellEnteredThisBar = false;
   }
   buyGridTriggeredThisTick  = false;
   sellGridTriggeredThisTick = false;

   // 포지션 집계
   int    totalBuyPositions  = 0, totalSellPositions = 0;
   double totalBuyProfit     = 0.0, totalSellProfit  = 0.0;
   double latestBuyPrice     = 0.0, latestSellPrice  = 0.0;
   double latestBuyVolume    = InpFixedLotSize, latestSellVolume = InpFixedLotSize;
   long   latestBuyTimeMsc   = 0, latestSellTimeMsc  = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;

      long   posType = PositionGetInteger(POSITION_TYPE);
      double profit  = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double price   = PositionGetDouble(POSITION_PRICE_OPEN);
      double volume  = PositionGetDouble(POSITION_VOLUME);
      long   timeMsc = PositionGetInteger(POSITION_TIME_MSC);

      if(posType == POSITION_TYPE_BUY)
      {
         totalBuyPositions++;
         totalBuyProfit += profit;
         if(timeMsc > latestBuyTimeMsc)
         {
            latestBuyTimeMsc = timeMsc;
            latestBuyPrice   = price;
            latestBuyVolume  = volume;
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         totalSellPositions++;
         totalSellProfit += profit;
         if(timeMsc > latestSellTimeMsc)
         {
            latestSellTimeMsc = timeMsc;
            latestSellPrice   = price;
            latestSellVolume  = volume;
         }
      }
   }

   // 이평선 배열 상태
   ENUM_MA_STATE maState = MA_STATE_MIXED;
   bool maReady = GetMAState(maState);
   if(maReady && (int)maState != lastLoggedMAState)
   {
      PrintFormat("[배열 변경] %s", MAStateText(maState, true));
      lastLoggedMAState = (int)maState;
   }

   // 차트 표시 (현재손익 / 오늘익절 / 배열 상태)
   UpdateProfitDisplay(totalBuyProfit + totalSellProfit, GetTodayClosedProfit(),
                       MAStateText(maState, maReady), MAStateColor(maState, maReady));

   // 최근 진입가 동기화
   if(totalBuyPositions > 0)
   {
      if(latestBuyTimeMsc > lastBuyEntryTimeMsc)
      {
         lastBuyEntryPrice   = latestBuyPrice;
         lastBuyEntryTimeMsc = latestBuyTimeMsc;
      }
   }
   else { lastBuyEntryPrice = 0.0; lastBuyEntryTimeMsc = 0; }

   if(totalSellPositions > 0)
   {
      if(latestSellTimeMsc > lastSellEntryTimeMsc)
      {
         lastSellEntryPrice   = latestSellPrice;
         lastSellEntryTimeMsc = latestSellTimeMsc;
      }
   }
   else { lastSellEntryPrice = 0.0; lastSellEntryTimeMsc = 0; }

   // 최대 손실 초과 시 전체 강제 청산
   double totalFloatingProfit = totalBuyProfit + totalSellProfit;
   if(InpMaxLossAmount > 0.0 && totalFloatingProfit <= -InpMaxLossAmount)
   {
      PrintFormat("[최대 손실 차단] 현재 손실: %.2f (제한: -%.2f) -> 전체 강제 청산",
                  totalFloatingProfit, InpMaxLossAmount);
      CloseAllPositions(POSITION_TYPE_BUY);
      CloseAllPositions(POSITION_TYPE_SELL);
      buyEnteredThisBar = true;     // 같은 봉 즉시 재진입 방지
      sellEnteredThisBar = true;
      return;
   }

   // 방향별 합산 익절
   if(totalBuyPositions > 0 && totalBuyProfit >= TPAmount)
   {
      CloseAllPositions(POSITION_TYPE_BUY);
      buyEnteredThisBar = true;     // 같은 봉 즉시 재진입 방지 (다음 봉부터 재진입)
      return;
   }
   if(totalSellPositions > 0 && totalSellProfit >= TPAmount)
   {
      CloseAllPositions(POSITION_TYPE_SELL);
      sellEnteredThisBar = true;
      return;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return;

   bool isAllowedTime  = IsAllowedTradingTime();
   bool isSafetyPassed = IsSafetyPassed();
   if(!isSafetyPassed) return;

   // 볼린저밴드 값 (현재 진행 중인 봉 기준 = 터치 즉시 반응)
   double upper[1], lower[1];
   if(CopyBuffer(bbHandle, UPPER_BAND, 0, 1, upper) != 1) return;
   if(CopyBuffer(bbHandle, LOWER_BAND, 0, 1, lower) != 1) return;

   double initialLot = CalculateLot(InpFixedLotSize);

   // 배열에 따른 신규 진입 허용 여부 / 매수 기준가
   // (이평선 데이터가 준비되지 않으면 신규 진입만 보류, 물타기·익절은 계속)
   bool   allowNewBuy  = maReady && (maState != MA_STATE_BEARISH);
   bool   allowNewSell = maReady && (maState != MA_STATE_BULLISH);
   double buyTrigger   = lower[0];
   if(InpUseMAFilter && maState == MA_STATE_BULLISH)
      buyTrigger = lower[0] + InpBuyOffset;   // 정배열: 하단보다 약간 위에서 매수

   //=========== 최초 BUY ===========
   if(totalBuyPositions == 0 && !buyEnteredThisBar && isAllowedTime && allowNewBuy &&
      (InpGridMode == MODE_BUY_ONLY || InpGridMode == MODE_BI_DIRECTION))
   {
      if(ask <= buyTrigger)
      {
         if(trade.Buy(initialLot, _Symbol, ask, 0, 0, "Initial_Buy") && IsTradeSuccess())
         {
            double executedPrice = trade.ResultPrice();
            if(executedPrice <= 0.0) executedPrice = ask;
            lastBuyEntryPrice   = executedPrice;
            lastBuyEntryTimeMsc = GetCurrentTimeMsc();
            buyEnteredThisBar   = true;
            PrintFormat("[최초 BUY 성공] %s | 밴드하단=%.2f | 기준가=%.2f | 체결가=%.2f",
                        MAStateText(maState, maReady), lower[0], buyTrigger, executedPrice);
         }
      }
   }

   //=========== 최초 SELL: 볼린저 상단 터치 ===========
   if(totalSellPositions == 0 && !sellEnteredThisBar && isAllowedTime && allowNewSell &&
      (InpGridMode == MODE_SELL_ONLY || InpGridMode == MODE_BI_DIRECTION))
   {
      if(bid >= upper[0])
      {
         if(trade.Sell(initialLot, _Symbol, bid, 0, 0, "Initial_Sell") && IsTradeSuccess())
         {
            double executedPrice = trade.ResultPrice();
            if(executedPrice <= 0.0) executedPrice = bid;
            lastSellEntryPrice   = executedPrice;
            lastSellEntryTimeMsc = GetCurrentTimeMsc();
            sellEnteredThisBar   = true;
            PrintFormat("[최초 SELL 성공] %s | 밴드상단=%.2f | 체결가=%.2f",
                        MAStateText(maState, maReady), upper[0], executedPrice);
         }
      }
   }

   //=========== BUY 물타기 (고정 간격 / 배열과 무관) ===========
   if(totalBuyPositions > 0 && totalBuyPositions < MaxTrades &&
      lastBuyEntryPrice > 0.0 && !buyGridTriggeredThisTick)
   {
      if(lastBuyEntryPrice - ask >= InpGridDistance)
      {
         double nextLot = CalculateLot(latestBuyVolume * Martingale);
         if(nextLot <= latestBuyVolume)
            nextLot = CalculateLot(latestBuyVolume + InpFixedLotSize);

         buyGridTriggeredThisTick = true;
         double prevPrice = lastBuyEntryPrice;

         if(trade.Buy(nextLot, _Symbol, ask, 0, 0, "Avg_Buy_" + IntegerToString(totalBuyPositions)) && IsTradeSuccess())
         {
            double executedPrice = trade.ResultPrice();
            if(executedPrice <= 0.0) executedPrice = ask;
            lastBuyEntryPrice   = executedPrice;
            lastBuyEntryTimeMsc = GetCurrentTimeMsc();
            PrintFormat("[BUY 물타기 성공] 이전가=%.2f | 체결가=%.2f | 거리=%.2f | Lot=%.2f",
                        prevPrice, executedPrice, prevPrice - executedPrice, nextLot);
         }
      }
   }

   //=========== SELL 물타기 (고정 간격 / 배열과 무관) ===========
   if(totalSellPositions > 0 && totalSellPositions < MaxTrades &&
      lastSellEntryPrice > 0.0 && !sellGridTriggeredThisTick)
   {
      if(bid - lastSellEntryPrice >= InpGridDistance)
      {
         double nextLot = CalculateLot(latestSellVolume * Martingale);
         if(nextLot <= latestSellVolume)
            nextLot = CalculateLot(latestSellVolume + InpFixedLotSize);

         sellGridTriggeredThisTick = true;
         double prevPrice = lastSellEntryPrice;

         if(trade.Sell(nextLot, _Symbol, bid, 0, 0, "Avg_Sell_" + IntegerToString(totalSellPositions)) && IsTradeSuccess())
         {
            double executedPrice = trade.ResultPrice();
            if(executedPrice <= 0.0) executedPrice = bid;
            lastSellEntryPrice   = executedPrice;
            lastSellEntryTimeMsc = GetCurrentTimeMsc();
            PrintFormat("[SELL 물타기 성공] 이전가=%.2f | 체결가=%.2f | 거리=%.2f | Lot=%.2f",
                        prevPrice, executedPrice, executedPrice - prevPrice, nextLot);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 차트 표시 (우상단 자동매매 표시 아래쪽)                           |
//+------------------------------------------------------------------+
void UpdateProfitDisplay(double currentPnL, double todayProfit, string maText, color maColor)
{
   string txtPnL   = "현재손익: " + DoubleToString(currentPnL, 2) + " USD";
   string txtToday = "오늘익절: " + DoubleToString(todayProfit, 2) + " USD";

   SetChartLabel(LABEL_CURRENT_PNL,  txtPnL,   15, 30, clrLime,   11, "맑은 고딕");
   SetChartLabel(LABEL_TODAY_PROFIT, txtToday, 15, 55, clrYellow, 11, "맑은 고딕");
   SetChartLabel(LABEL_MA_STATE,     maText,   15, 80, maColor,   11, "맑은 고딕");
   ChartRedraw(0);
}

void SetChartLabel(string name, string text, int x, int y, color textColor, int fontSize, string font)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, textColor);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, font);
}

//+------------------------------------------------------------------+
//| 오늘(00:00 이후) 청산된 확정 손익                                 |
//| - EA가 청산한 딜 + 수동으로 청산한 EA 진입 포지션 모두 포함       |
//|   (수동 청산 딜은 magic=0 이라서, 해당 포지션의 진입 딜 magic으로 판별) |
//+------------------------------------------------------------------+
double GetTodayClosedProfit()
{
   static double   cached = 0.0;
   static datetime lastCalc = 0;

   // 1초 이내 재호출은 캐시 사용 (버튼 청산 직후엔 강제 갱신)
   datetime nowLocal = TimeLocal();
   if(!forceHistoryRefresh && lastCalc != 0 && nowLocal - lastCalc < 1)
      return cached;
   lastCalc = nowLocal;
   forceHistoryRefresh = false;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime todayStart = StructToTime(dt);

   if(!HistorySelect(todayStart, TimeCurrent() + 60))
      return cached;

   double sum = 0.0;

   // 1차: 청산 딜 수집 (EA magic이면 바로 합산, 아니면 포지션 확인 대기열)
   ulong  pendPos[];
   double pendProfit[];
   int    pendCount = 0;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol) continue;

      long entry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY)
         continue;

      double dealPnL = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                     + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                     + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == (long)MagicNumber)
      {
         sum += dealPnL;
      }
      else
      {
         ArrayResize(pendPos, pendCount + 1);
         ArrayResize(pendProfit, pendCount + 1);
         pendPos[pendCount]    = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
         pendProfit[pendCount] = dealPnL;
         pendCount++;
      }
   }

   // 2차: magic이 다른(수동 청산 등) 딜은 해당 포지션의 진입 딜 magic 확인
   for(int k = 0; k < pendCount; k++)
   {
      if(pendPos[k] == 0) continue;
      if(!HistorySelectByPosition(pendPos[k])) continue;

      int n = HistoryDealsTotal();
      for(int j = 0; j < n; j++)
      {
         ulong t = HistoryDealGetTicket(j);
         if(t == 0) continue;
         if(HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_IN)
         {
            if(HistoryDealGetInteger(t, DEAL_MAGIC) == (long)MagicNumber &&
               HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol)
               sum += pendProfit[k];
            break;
         }
      }
   }

   cached = sum;
   return cached;
}

//+------------------------------------------------------------------+
bool IsSafetyPassed()
{
   if(InpMaxSpread > 0)
   {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > InpMaxSpread)
         return false;
   }

   if(InpMaxBarRange > 0.0)
   {
      double high1 = iHigh(_Symbol, PERIOD_M1, 1);
      double low1  = iLow(_Symbol, PERIOD_M1, 1);
      if(high1 > 0.0 && low1 > 0.0)
      {
         if((high1 - low1) / _Point > InpMaxBarRange)
            return false;
      }
   }
   return true;
}

//+------------------------------------------------------------------+
bool IsAllowedTradingTime()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hhmm = dt.hour * 100 + dt.min;

   if(InpUseTimeRange1 && hhmm >= InpTimeStart1 && hhmm <= InpTimeEnd1) return true;
   if(InpUseTimeRange2 && hhmm >= InpTimeStart2 && hhmm <= InpTimeEnd2) return true;
   if(InpUseTimeRange3 && hhmm >= InpTimeStart3 && hhmm <= InpTimeEnd3) return true;
   return false;
}

//+------------------------------------------------------------------+
bool IsTradeSuccess()
{
   uint retcode = trade.ResultRetcode();
   return (retcode == TRADE_RETCODE_DONE ||
           retcode == TRADE_RETCODE_DONE_PARTIAL ||
           retcode == TRADE_RETCODE_PLACED);
}

//+------------------------------------------------------------------+
long GetCurrentTimeMsc()
{
   MqlTick tick;
   if(SymbolInfoTick(_Symbol, tick))
      return (long)tick.time_msc;
   return (long)TimeCurrent() * 1000;
}

//+------------------------------------------------------------------+
void RestoreLatestEntryPrices()
{
   lastBuyEntryPrice = 0.0;  lastSellEntryPrice = 0.0;
   lastBuyEntryTimeMsc = 0;  lastSellEntryTimeMsc = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;

      long   type    = PositionGetInteger(POSITION_TYPE);
      double price   = PositionGetDouble(POSITION_PRICE_OPEN);
      long   timeMsc = PositionGetInteger(POSITION_TIME_MSC);

      if(type == POSITION_TYPE_BUY && timeMsc > lastBuyEntryTimeMsc)
      {
         lastBuyEntryTimeMsc = timeMsc;
         lastBuyEntryPrice   = price;
      }
      else if(type == POSITION_TYPE_SELL && timeMsc > lastSellEntryTimeMsc)
      {
         lastSellEntryTimeMsc = timeMsc;
         lastSellEntryPrice   = price;
      }
   }
}

//+------------------------------------------------------------------+
double CalculateLot(double targetLot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0.0)
      return targetLot;

   double normalizedLot = MathFloor(targetLot / lotStep + 1e-8) * lotStep;
   if(normalizedLot < minLot) normalizedLot = minLot;
   if(normalizedLot > maxLot) normalizedLot = maxLot;

   int volumeDigits = 0;
   double stepCheck = lotStep;
   while(volumeDigits < 8 && MathAbs(stepCheck - MathRound(stepCheck)) > 0.00000001)
   {
      stepCheck *= 10.0;
      volumeDigits++;
   }
   return NormalizeDouble(normalizedLot, volumeDigits);
}

//+------------------------------------------------------------------+
void CloseAllPositions(long positionType)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;
      if(PositionGetInteger(POSITION_TYPE) != positionType) continue;

      bool result = trade.PositionClose(ticket);
      if(!result || !IsTradeSuccess())
      {
         PrintFormat("[청산 실패] Ticket=%I64u | %u | %s",
                     ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
   }
}
//+------------------------------------------------------------------+
