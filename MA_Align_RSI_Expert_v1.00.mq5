//+------------------------------------------------------------------+
//|                                  MA_Align_RSI_Expert_v1.00.mq5    |
//|                                                                  |
//| XAUUSD M1 정배열 매수 + RSI 매도 물타기 EA                         |
//| [매수]                                                            |
//|  - SMA 5>20>60>120>240 정배열이 되는 순간 매수 (봉 마감 기준)      |
//|  - 120선이 240선을 하회했다가 다시 정배열될 때만 다음 매수         |
//|  - 최대 10개, 손절 없음 / RSI 80 이상이면 매수 전체 청산(손실 포함)|
//| [매도]                                                            |
//|  - 정배열 + RSI 80 이상이면 첫 매도 (매도 묶음 진행 중엔 새 매도 X)|
//|  - 마지막 매도보다 $5 오를 때마다 사다리 랏으로 물타기             |
//|      0.01 → 0.02 → 0.03 → 0.05 → 0.08 → 0.12                     |
//|  - 매도 합계 +$20 이상이면 매도 전체 청산                         |
//| [공통]                                                            |
//|  - 기준랏 비례: 사다리 랏·매수 랏·익절 목표가 기준랏/0.01 배       |
//|  - EA 포지션 합계 손실 -$2,000(고정) 이면 전체 청산 후 EA 정지     |
//|  - 매수·매도 동시 보유 → 헤지 계좌 전용                           |
//+------------------------------------------------------------------+
#property copyright "Code Expert"
#property link      "https://mql5.com"
#property version   "1.00"

#include <Trade\Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
input group "--- 1. 자금 관리 ---"
input double InpBaseLot = 0.01;           // 기준 랏 (0.02면 모든 랏·익절 목표 2배)

input group "--- 2. 이평선 정배열 (M1 / 단순이동평균) ---"
input int    InpMA1 = 5;                  // 1번 이평선
input int    InpMA2 = 20;                 // 2번 이평선
input int    InpMA3 = 60;                 // 3번 이평선
input int    InpMA4 = 120;                // 4번 이평선 (재진입 기준)
input int    InpMA5 = 240;                // 5번 이평선 (재진입 기준)

input group "--- 3. RSI (M1 / 봉 마감 기준) ---"
input int    InpRSIPeriod   = 14;         // RSI 기간
input double InpBuyCloseRSI = 80.0;       // 이 값 이상이면 매수 전체 청산
input double InpSellRSI     = 80.0;       // 정배열 + 이 값 이상이면 첫 매도

input group "--- 4. 매수 ---"
input int    InpMaxBuys = 10;             // 최대 매수 포지션 개수

input group "--- 5. 매도 물타기 ---"
input string InpSellLadder   = "0.01,0.02,0.03,0.05,0.08,0.12"; // 매도 사다리 랏 (0.01 기준)
input double InpGridDollar   = 5.0;       // 물타기 간격: 0.01랏 기준 손실 $ (골드 $5 = 500포인트)
input double InpSellTPDollar = 20.0;      // 매도 합계 익절 목표 (0.01 기준 $)

input group "--- 6. 안전 장치 ---"
input double InpMaxLoss  = 2000.0;        // EA 포지션 합계 손실 한도 ($, 고정) → 전체 청산 후 EA 정지
input int    InpSlippage = 30;            // 허용 슬리피지 (POINTS)
input ulong  MagicNumber = 20261011;      // 매직넘버

//+------------------------------------------------------------------+
int      g_maHandle[5];
int      g_rsiHandle   = INVALID_HANDLE;
double   g_ladder[];                      // 기준랏 비례 적용 전 사다리
double   g_lotScale    = 1.0;             // 기준랏 / 0.01
datetime g_lastBar     = 0;
bool     g_armReady    = false;           // 재진입 상태 초기화 완료 여부
bool     g_buyArmed    = false;           // true = 120<240 이후 아직 정배열 매수 안 함
bool     g_halted      = false;           // 손실 한도 도달 → 전체 청산 후 정지

//+------------------------------------------------------------------+
int OnInit()
{
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("헤지 계좌에서만 동작합니다 (매수·매도 동시 보유).");
      return INIT_FAILED;
   }
   if(InpBaseLot <= 0.0 || InpMaxBuys < 0 || InpGridDollar <= 0.0)
   {
      Print("입력값 오류: 기준 랏 / 최대 매수 / 물타기 간격을 확인하세요.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(!ParseLadder())
   {
      Print("매도 사다리 입력 오류: ", InpSellLadder);
      return INIT_PARAMETERS_INCORRECT;
   }
   g_lotScale = InpBaseLot / 0.01;

   int periods[5];
   periods[0] = InpMA1; periods[1] = InpMA2; periods[2] = InpMA3;
   periods[3] = InpMA4; periods[4] = InpMA5;
   for(int i = 0; i < 5; i++)
   {
      g_maHandle[i] = iMA(_Symbol, PERIOD_M1, periods[i], 0, MODE_SMA, PRICE_CLOSE);
      if(g_maHandle[i] == INVALID_HANDLE)
      {
         Print("이평선 핸들 생성 실패: ", periods[i]);
         return INIT_FAILED;
      }
   }
   g_rsiHandle = iRSI(_Symbol, PERIOD_M1, InpRSIPeriod, PRICE_CLOSE);
   if(g_rsiHandle == INVALID_HANDLE)
   {
      Print("RSI 핸들 생성 실패");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_lastBar  = 0;
   g_armReady = false;
   g_halted   = false;
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i = 0; i < 5; i++)
      if(g_maHandle[i] != INVALID_HANDLE) IndicatorRelease(g_maHandle[i]);
   if(g_rsiHandle != INVALID_HANDLE) IndicatorRelease(g_rsiHandle);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   // 손실 한도 도달 후: 남은 포지션 모두 청산되면 EA 제거
   if(g_halted)
   {
      ClosePositions(-1);
      if(CountPositions(-1) == 0) ExpertRemove();
      return;
   }

   // 1. 계좌 손실 한도 (EA 포지션 현재 손실 합계)
   double total = TotalProfit(-1);
   if(total <= -InpMaxLoss)
   {
      PrintFormat("손실 한도 도달 (%.2f$) → 전체 청산 후 EA 정지", total);
      g_halted = true;
      ClosePositions(-1);
      if(CountPositions(-1) == 0) ExpertRemove();
      return;
   }

   // 2. 매도 합계 익절
   if(CountPositions(POSITION_TYPE_SELL) > 0 && TotalProfit(POSITION_TYPE_SELL) >= SellTarget())
      ClosePositions(POSITION_TYPE_SELL);

   // 3. 매도 물타기 (틱 기준)
   CheckSellGrid();

   // 4. M1 새 봉 → 직전 마감봉 기준 판단
   datetime barTime = iTime(_Symbol, PERIOD_M1, 0);
   if(barTime != 0 && barTime != g_lastBar)
   {
      if(OnNewBar()) g_lastBar = barTime;   // 지표 준비 안 됐으면 다음 틱에 재시도
   }

   UpdateComment();
}

//+------------------------------------------------------------------+
//| 마감봉(shift 1) 기준 매수 청산 / 매수 진입 / 첫 매도 진입          |
//+------------------------------------------------------------------+
bool OnNewBar()
{
   double ma[5];
   for(int i = 0; i < 5; i++)
      if(!GetValue(g_maHandle[i], 1, ma[i])) return false;
   double rsi;
   if(!GetValue(g_rsiHandle, 1, rsi)) return false;

   if(!g_armReady)
   {
      if(!InitBuyArmed()) return false;
      g_armReady = true;
   }

   bool aligned = IsAligned(ma[0], ma[1], ma[2], ma[3], ma[4]);
   if(ma[3] < ma[4]) g_buyArmed = true;

   // 매수 청산: RSI 80 이상이면 손익 관계없이 전체 청산
   if(rsi >= InpBuyCloseRSI && CountPositions(POSITION_TYPE_BUY) > 0)
      ClosePositions(POSITION_TYPE_BUY);

   // 매수 진입: 120<240 이후 처음 정배열 되는 순간
   if(aligned && g_buyArmed)
   {
      g_buyArmed = false;
      if(CountPositions(POSITION_TYPE_BUY) < InpMaxBuys)
      {
         double lot = NormalizeLot(InpBaseLot);
         if(!trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, "MA_ALIGN BUY"))
            PrintFormat("매수 실패: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
      else
         Print("정배열 신호 발생, 매수 최대 개수 도달로 진입 생략");
   }

   // 첫 매도: 정배열 + RSI 80 이상, 매도 묶음이 없을 때만
   if(aligned && rsi >= InpSellRSI && CountPositions(POSITION_TYPE_SELL) == 0)
      OpenSell(0);

   return true;
}

//+------------------------------------------------------------------+
//| EA 시작 시 과거 봉을 거슬러 올라가 재진입 상태 결정               |
//| 정배열이 먼저 나오면 대기, 120<240 이 먼저 나오면 매수 대기 해제  |
//+------------------------------------------------------------------+
bool InitBuyArmed()
{
   int count = MathMin(5000, BarsCalculated(g_maHandle[4]) - 2);
   if(count <= 0) return false;

   double m1[], m2[], m3[], m4[], m5[];
   ArraySetAsSeries(m1, true); ArraySetAsSeries(m2, true); ArraySetAsSeries(m3, true);
   ArraySetAsSeries(m4, true); ArraySetAsSeries(m5, true);
   if(CopyBuffer(g_maHandle[0], 0, 2, count, m1) != count) return false;
   if(CopyBuffer(g_maHandle[1], 0, 2, count, m2) != count) return false;
   if(CopyBuffer(g_maHandle[2], 0, 2, count, m3) != count) return false;
   if(CopyBuffer(g_maHandle[3], 0, 2, count, m4) != count) return false;
   if(CopyBuffer(g_maHandle[4], 0, 2, count, m5) != count) return false;

   g_buyArmed = false;
   for(int k = 0; k < count; k++)
   {
      if(IsAligned(m1[k], m2[k], m3[k], m4[k], m5[k])) { g_buyArmed = false; break; }
      if(m4[k] < m5[k])                                { g_buyArmed = true;  break; }
   }
   return true;
}

//+------------------------------------------------------------------+
//| 마지막 매도보다 간격 이상 오르면 다음 사다리 랏으로 추가 매도      |
//+------------------------------------------------------------------+
void CheckSellGrid()
{
   int n = CountPositions(POSITION_TYPE_SELL);
   if(n == 0 || n >= ArraySize(g_ladder)) return;

   double lastPrice = LastSellPrice();
   double distance  = GridDistancePrice();
   if(lastPrice <= 0.0 || distance <= 0.0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid >= lastPrice + distance)
      OpenSell(n);
}

//+------------------------------------------------------------------+
bool OpenSell(int index)
{
   double lot = NormalizeLot(g_ladder[index] * g_lotScale);
   string comment = StringFormat("MA_ALIGN SELL #%d", index + 1);
   if(!trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, comment))
   {
      PrintFormat("매도 실패 (#%d): %d %s", index + 1, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| 0.01랏 기준 InpGridDollar 손실이 나는 가격 폭                      |
//+------------------------------------------------------------------+
double GridDistancePrice()
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0.0) tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0) return 0.0;
   return InpGridDollar / (tickValue * 0.01) * tickSize;
}

//+------------------------------------------------------------------+
double SellTarget()
{
   return InpSellTPDollar * g_lotScale;
}

//+------------------------------------------------------------------+
bool IsAligned(double a, double b, double c, double d, double e)
{
   return (a > b && b > c && c > d && d > e);
}

//+------------------------------------------------------------------+
bool GetValue(int handle, int shift, double &value)
{
   double buf[1];
   if(CopyBuffer(handle, 0, shift, 1, buf) != 1) return false;
   value = buf[0];
   return true;
}

//+------------------------------------------------------------------+
bool ParseLadder()
{
   string parts[];
   int n = StringSplit(InpSellLadder, ',', parts);
   if(n <= 0) return false;
   ArrayResize(g_ladder, n);
   for(int i = 0; i < n; i++)
   {
      StringTrimLeft(parts[i]);
      StringTrimRight(parts[i]);
      g_ladder[i] = StringToDouble(parts[i]);
      if(g_ladder[i] <= 0.0) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0) step = 0.01;
   lot = MathRound(lot / step) * step;
   lot = MathMax(minL, MathMin(maxL, lot));
   int digits = (int)MathMax(0, MathCeil(-MathLog10(step) - 1e-9));
   return NormalizeDouble(lot, digits);
}

//+------------------------------------------------------------------+
//| type: POSITION_TYPE_BUY / POSITION_TYPE_SELL / -1 = 전체           |
//+------------------------------------------------------------------+
bool IsMine(long type)
{
   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
   if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) return false;
   if(type >= 0 && PositionGetInteger(POSITION_TYPE) != type) return false;
   return true;
}

int CountPositions(long type)
{
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(IsMine(type)) cnt++;
   }
   return cnt;
}

double TotalProfit(long type)
{
   double sum = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(IsMine(type))
         sum += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return sum;
}

double LastSellPrice()
{
   long   lastTime  = 0;
   double lastPrice = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(!IsMine(POSITION_TYPE_SELL)) continue;
      long t = PositionGetInteger(POSITION_TIME_MSC);
      if(t > lastTime)
      {
         lastTime  = t;
         lastPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }
   return lastPrice;
}

void ClosePositions(long type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!IsMine(type)) continue;
      if(!trade.PositionClose(ticket))
         PrintFormat("청산 실패 #%I64u: %d %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
void UpdateComment()
{
   int buys  = CountPositions(POSITION_TYPE_BUY);
   int sells = CountPositions(POSITION_TYPE_SELL);
   Comment(StringFormat(
      "MA_Align_RSI v1.00\n"
      "매수: %d / %d   손익 %.2f$\n"
      "매도: %d / %d   손익 %.2f$  (익절 목표 %.2f$)\n"
      "합계 손익: %.2f$  (손실 한도 -%.0f$)\n"
      "정배열 매수 대기: %s",
      buys, InpMaxBuys, TotalProfit(POSITION_TYPE_BUY),
      sells, ArraySize(g_ladder), TotalProfit(POSITION_TYPE_SELL), SellTarget(),
      TotalProfit(-1), InpMaxLoss,
      g_buyArmed ? "예" : "아니오 (120<240 대기)"));
}
//+------------------------------------------------------------------+
