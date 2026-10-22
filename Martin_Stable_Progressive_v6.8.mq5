//+------------------------------------------------------------------+
//|                         Martin_Stable_Progressive_v6.8            |
//|     ATR Grid & Lot Symmetry - Manual + Price Trigger Version     |
//+------------------------------------------------------------------+
//| v6.8 변경 사항 (느린 서버 대응)                                   |
//|  1. 체결 확인 시 포지션 목록 + 서버 주문/체결 기록을 함께 확인     |
//|  2. 거절/취소 기록이 확인될 때만 실패로 보고 대기 해제            |
//|  3. 5초 내 미확인 시 마틴 정지 + "수동 확인 필요" 알림            |
//|     (경고창 + 소리 + 휴대폰 푸시, 10초 간격 반복)                 |
//|  4. [확인 해제] 버튼으로 수동 해제 (수동 확인 상태일 때만 표시)    |
//|  5. 1초 타이머로 틱이 없어도 확인/알림 동작                       |
//+------------------------------------------------------------------+
//| v6.7 변경 사항 (마틴 중복 진입 방지)                              |
//|  1. 체결 확인 대기: 주문 후 포지션 수가 실제로 늘어날 때까지      |
//|     모든 신규 진입(마틴/헤지/첫 진입) 차단, 최대 N초 후 자동 해제 |
//|  2. 타임아웃 등 결과 미확정 응답은 실패가 아닌 "확인 대기"로 처리 |
//|  3. 주문 쿨다운을 서버 응답을 받은 시각부터 다시 계산             |
//|  4. 같은 심볼+매직 EA 이중 실행 차단 (같은 터미널 내)             |
//|  5. 체결 확인 대기 중에는 "포지션 0개 → 사이클 리셋" 하지 않음    |
//+------------------------------------------------------------------+
//| v6.6 변경 사항                                                   |
//|  1. GetAverageATR 배열 범위 초과(array out of range) 수정        |
//|  2. 손절/익절/트레일링 체크를 스프레드 필터보다 먼저 실행         |
//|  3. 뉴스 필터는 첫 진입(수동/예약)에만 적용, 진행 중 마틴은 허용  |
//|  4. 손절 후 대기 중에는 첫 진입(수동/예약)도 차단                 |
//|  5. 체결 방식(Filling) 자동 설정, 랏을 브로커 규격에 맞게 보정    |
//|  6. 주문 전 증거금 확인, 주문 결과 Retcode 확인                   |
//|  7. 전체 청산 실패 시 상태 유지 + 다음 틱에 재시도                |
//|  8. 상태 라벨 추가 (현재 대기/차단 사유 표시)                     |
//|  9. 손익 라벨: $ 제거, +/- 부호 표시 (0은 0.00)                  |
//+------------------------------------------------------------------+
#property copyright "Reconstructed EA v6.8"
#property version   "6.80"

#include <Trade\Trade.mqh>

//====================================================================
// 오브젝트 이름
//====================================================================
#define LABEL_NAME              "TodayProfitLabel"
#define CURRENT_PROFIT_LABEL    "CurrentProfitLabel"
#define STATUS_LABEL            "StatusLabel"

#define BTN_BUY_NAME            "Btn_Buy_Start"
#define BTN_SELL_NAME           "Btn_Sell_Start"
#define BTN_CLOSE_NAME          "Btn_All_Close"
#define BTN_RELEASE_NAME        "Btn_Confirm_Release"

#define EDIT_BUY_PRICE          "Edit_Buy_Price"
#define EDIT_SELL_PRICE         "Edit_Sell_Price"

#define LABEL_BUY_PRICE         "Label_Buy_Price"
#define LABEL_SELL_PRICE        "Label_Sell_Price"

//====================================================================
// 체결 확인 / 알림 고정값 (바꾸려면 이 값을 고치고 다시 컴파일)
//====================================================================
#define CONFIRM_WAIT_SEC        5              // 주문 후 체결 확인 대기(초)
#define ALERT_INTERVAL_SEC      10             // 수동 확인 알림 반복 간격(초)
#define USE_PUSH_ALERT          true           // 휴대폰 푸시 알림
#define ALERT_SOUND_FILE        "alert2.wav"   // 알림 소리 (MT5 Sounds 폴더)

//====================================================================
// 보낸 주문의 서버 기록 상태
//====================================================================
enum ENUM_SENT_STATE
{
   SENT_UNKNOWN  = 0,   // 기록 없음
   SENT_ACTIVE   = 1,   // 처리 중
   SENT_FILLED   = 2,   // 체결 기록 있음
   SENT_REJECTED = 3    // 거절/취소/만료
};

//====================================================================
// 거래 모드
//====================================================================
enum ENUM_TRADE_MODE
{
   MODE_NONE = 0,
   MODE_BUY  = 1,
   MODE_SELL = 2
};

//====================================================================
// [1. 기본 설정]
//====================================================================
input group "1. 기본 설정"

input double     InpInitLot              = 0.01;
input long       InpMagicNumber          = 999;
input double     InpMaxSpread            = 3000.0;
input bool       InpAutoCloseOnFail      = true;
input int        InpOrderCoolDownSec     = 3;
input bool       InpUseInstanceLock      = true;   // 같은 심볼+매직 이중 실행 차단

//====================================================================
// [2. 시간대 필터]
//====================================================================
input group "2. 시간대 필터 (세션 관리)"

input bool       InpUseTimeFilter        = true;
input int        InpTime1Start           = 900;
input int        InpTime1End             = 1430;
input int        InpTime2Start           = 1600;
input int        InpTime2End             = 2200;

//====================================================================
// [2-1. 뉴스 필터]  ※ 첫 진입에만 적용
//====================================================================
input group "2-1. 중요 경제뉴스 필터 (첫 진입에만 적용)"

input bool       InpUseNewsFilter        = true;
input int        InpNewsPreHours         = 4;
input int        InpNewsPostHours        = 4;
input string     InpNewsCurrency         = "USD";

//====================================================================
// [3. 전체 청산 / 손절 / 트레일링]
//====================================================================
input group "3. 전체 청산 / 손절 / 트레일링 (익절 제어 구조)"

input bool       InpUseTotalTP           = true;
input double     InpTotalTPDollar        = 6.0;

input bool       InpUseTrailingClose     = true;
input double     InpTrailStartDollar     = 4.0;
input double     InpTrailRetratePct      = 25.0;
input double     InpTrailMinLockDollar   = 3.0;

input bool       InpUseWaitAfterClose    = true;
input int        InpWaitAfterCloseSec    = 5;

input bool       InpUseMaxLoss           = true;
input double     InpMaxLossDollar        = 1200.0;

input bool       InpUseStopAfterLoss     = true;
input int        InpStopWaitMinutes      = 60;
input bool       InpBlockEntryAfterLoss  = true;   // 손절 후 대기 중 첫 진입도 차단

//====================================================================
// [4. 마틴 / ATR]
//====================================================================
input group "4. 마틴 단계 및 ATR 동적 간격 / 랏수 설정"

input int        InpBaseDistance         = 300;
input bool       InpUseATRScale          = true;
input int        InpATRPeriod            = 14;
input bool       InpUseATRLotScale       = true;
input bool       InpUseLowVolLotExpand   = true;
input int        InpMaxMartinStep        = 10;

//====================================================================
// [5. 추세 트리거]
//====================================================================
input group "5. 추세 트리거"

input bool       InpUseTrendTrigger      = true;
input long       InpTrendMagicNumber     = 2003;
input int        InpTrendTriggerStep     = 7;
input double     InpTrendLotPct          = 50.0;

//====================================================================
// 내부 변수
//====================================================================
CTrade           m_trade;
CTrade           m_trade_trend;

double           g_point = 0.0;
int              g_atr_handle = INVALID_HANDLE;
double           g_highest_profit = 0.0;

datetime         g_last_close_time = 0;
datetime         g_last_loss_time  = 0;
ulong            g_last_order_tick_ms = 0;

ENUM_TRADE_MODE  g_trade_mode = MODE_NONE;
bool             g_cycle_active = false;

double           g_buy_reserve_price  = 0.0;
double           g_sell_reserve_price = 0.0;

// 전체 청산 진행 상태 (일부 실패 시 재시도용)
bool             g_close_pending     = false;
bool             g_close_record_time = false;
bool             g_close_is_loss     = false;

// 체결 확인 대기 (주문 후 포지션 수가 이 값에 도달할 때까지 신규 진입 차단)
int              g_confirm_expect   = 0;
ulong            g_confirm_start_ms = 0;
ulong            g_confirm_order    = 0;     // 서버가 준 주문번호 (타임아웃이면 0)
long             g_confirm_magic    = 0;
string           g_confirm_comment  = "";
datetime         g_confirm_send_time = 0;
ENUM_SENT_STATE  g_confirm_state    = SENT_UNKNOWN;
ulong            g_confirm_check_ms = 0;     // 서버 기록 마지막 조회 시각

// 수동 확인 필요 상태
bool             g_manual_check     = false;
ulong            g_last_alert_ms    = 0;

// 이중 실행 방지 잠금
string           g_lock_name  = "";
double           g_lock_token = 0.0;
bool             g_lock_owned = false;

// 뉴스 차단 해제 시각 (상태 표시용)
datetime         g_news_block_until = 0;

// 상태 표시
string           g_status_text   = "";
string           g_last_fail_msg = "";
ulong            g_last_fail_ms  = 0;


//+------------------------------------------------------------------+
//| 이중 실행 잠금 획득                                               |
//| 같은 터미널에서 같은 심볼+매직 EA는 하나만 실행되도록 한다.        |
//| 임시 전역변수라 터미널을 종료하면 자동으로 사라진다.               |
//+------------------------------------------------------------------+
bool AcquireInstanceLock()
{
   if(!InpUseInstanceLock || MQLInfoInteger(MQL_TESTER))
      return true;

   g_lock_name  = "MSP_LOCK_" + _Symbol + "_" + IntegerToString(InpMagicNumber);
   // ChartID는 double 정밀도를 넘으므로 하위 자리만 사용 (0은 "비어 있음" 표시)
   g_lock_token = (double)(ChartID() % 1000000000) + 1.0;

   if(!GlobalVariableCheck(g_lock_name))
      GlobalVariableTemp(g_lock_name);

   // 비어 있으면(0) 원자적으로 내 토큰을 기록
   if(GlobalVariableSetOnCondition(g_lock_name, g_lock_token, 0.0))
   {
      g_lock_owned = true;
      return true;
   }

   // 같은 차트에서 재초기화(타임프레임 변경 등)된 경우
   if(GlobalVariableGet(g_lock_name) == g_lock_token)
   {
      g_lock_owned = true;
      return true;
   }

   return false;
}

void ReleaseInstanceLock()
{
   if(!g_lock_owned)
      return;

   GlobalVariableSetOnCondition(g_lock_name, 0.0, g_lock_token);
   g_lock_owned = false;
}


//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!AcquireInstanceLock())
   {
      string msg = "같은 심볼(" + _Symbol + ") / 매직(" +
                   IntegerToString(InpMagicNumber) +
                   ")으로 이미 실행 중인 EA가 있어 이 EA는 중지됩니다.";
      Print(msg);
      Alert(msg);
      return(INIT_FAILED);
   }

   g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade_trend.SetExpertMagicNumber(InpTrendMagicNumber);

   // 브로커가 허용하는 체결 방식 자동 설정
   m_trade.SetTypeFillingBySymbol(_Symbol);
   m_trade_trend.SetTypeFillingBySymbol(_Symbol);

   g_atr_handle = iATR(_Symbol, _Period, InpATRPeriod);
   if(g_atr_handle == INVALID_HANDLE)
   {
      Print("ATR 지표 생성 실패!");
      ReleaseInstanceLock();
      return(INIT_FAILED);
   }

   ObjectDelete(0, LABEL_NAME);
   ObjectDelete(0, CURRENT_PROFIT_LABEL);
   ObjectDelete(0, STATUS_LABEL);
   g_status_text = "";

   DestroyButtons();
   CreateButtons();

   SetStatus("초기화 완료");

   // 틱이 없어도 체결 확인/알림이 동작하도록 1초 타이머
   EventSetTimer(1);

   return(INIT_SUCCEEDED);
}


//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ReleaseInstanceLock();

   if(g_atr_handle != INVALID_HANDLE)
   {
      IndicatorRelease(g_atr_handle);
      g_atr_handle = INVALID_HANDLE;
   }

   ObjectDelete(0, LABEL_NAME);
   ObjectDelete(0, CURRENT_PROFIT_LABEL);
   ObjectDelete(0, STATUS_LABEL);

   DestroyButtons();
}


//+------------------------------------------------------------------+
//| UI 생성 헬퍼                                                      |
//+------------------------------------------------------------------+
void CreateButtonObj(string name, int x, int y, string text,
                     color bg, color border)
{
   if(ObjectFind(0, name) >= 0) return;

   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER,       CORNER_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,    x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,    y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE,        110);
   ObjectSetInteger(0, name, OBJPROP_YSIZE,        40);
   ObjectSetString (0, name, OBJPROP_TEXT,         text);
   ObjectSetString (0, name, OBJPROP_FONT,         "맑은 고딕");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,     11);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR,      bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR,        clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, border);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,   false);
}

void CreateTextLabelObj(string name, int x, int y, string text)
{
   if(ObjectFind(0, name) >= 0) return;

   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  y);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   9);
   ObjectSetString (0, name, OBJPROP_FONT,       "맑은 고딕");
   ObjectSetString (0, name, OBJPROP_TEXT,       text);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      clrWhite);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void CreateEditObj(string name, int x, int y, color border)
{
   if(ObjectFind(0, name) >= 0) return;

   ObjectCreate(0, name, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER,       CORNER_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,    x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,    y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE,        110);
   ObjectSetInteger(0, name, OBJPROP_YSIZE,        30);
   ObjectSetString (0, name, OBJPROP_TEXT,         "");
   ObjectSetString (0, name, OBJPROP_FONT,         "Arial");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,     10);
   ObjectSetInteger(0, name, OBJPROP_COLOR,        clrBlack);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR,      clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, border);
}


//+------------------------------------------------------------------+
//| 버튼 및 가격 입력창 생성                                          |
//+------------------------------------------------------------------+
void CreateButtons()
{
   CreateButtonObj(BTN_BUY_NAME,   20,  85, "매수 시작", clrRoyalBlue,   clrLightBlue);
   CreateButtonObj(BTN_SELL_NAME,  140, 85, "매도 시작", clrCrimson,     clrPink);
   CreateButtonObj(BTN_CLOSE_NAME, 260, 85, "전체 청산", clrForestGreen, clrLightGreen);

   CreateTextLabelObj(LABEL_BUY_PRICE,  20,  55, "매수 예약가");
   CreateTextLabelObj(LABEL_SELL_PRICE, 140, 55, "매도 예약가");

   CreateEditObj(EDIT_BUY_PRICE,  20,  55, clrRoyalBlue);
   CreateEditObj(EDIT_SELL_PRICE, 140, 55, clrCrimson);

   UpdateButtonState(true);
   ChartRedraw(0);
}


//+------------------------------------------------------------------+
//| 버튼 삭제                                                         |
//+------------------------------------------------------------------+
void DestroyButtons()
{
   ObjectDelete(0, BTN_BUY_NAME);
   ObjectDelete(0, BTN_SELL_NAME);
   ObjectDelete(0, BTN_CLOSE_NAME);
   ObjectDelete(0, BTN_RELEASE_NAME);

   ObjectDelete(0, EDIT_BUY_PRICE);
   ObjectDelete(0, EDIT_SELL_PRICE);

   ObjectDelete(0, LABEL_BUY_PRICE);
   ObjectDelete(0, LABEL_SELL_PRICE);
}


//+------------------------------------------------------------------+
//| 버튼 상태 업데이트 (상태가 바뀔 때만 다시 그림)                   |
//+------------------------------------------------------------------+
void UpdateButtonState(bool force = false)
{
   static int last_state = -1;

   bool locked = (g_cycle_active || g_confirm_expect > 0 ||
                  GetTotalPositionsCount() > 0);
   int  state  = locked ? 1 : 0;

   if(!force && state == last_state)
      return;

   last_state = state;

   if(locked)
   {
      ObjectSetInteger(0, BTN_BUY_NAME,    OBJPROP_BGCOLOR, clrDimGray);
      ObjectSetInteger(0, BTN_SELL_NAME,   OBJPROP_BGCOLOR, clrDimGray);
      ObjectSetString (0, BTN_BUY_NAME,    OBJPROP_TEXT,    "매수 진행중");
      ObjectSetString (0, BTN_SELL_NAME,   OBJPROP_TEXT,    "매도 진행중");
      ObjectSetInteger(0, EDIT_BUY_PRICE,  OBJPROP_BGCOLOR, clrSilver);
      ObjectSetInteger(0, EDIT_SELL_PRICE, OBJPROP_BGCOLOR, clrSilver);
   }
   else
   {
      ObjectSetInteger(0, BTN_BUY_NAME,    OBJPROP_BGCOLOR, clrRoyalBlue);
      ObjectSetInteger(0, BTN_SELL_NAME,   OBJPROP_BGCOLOR, clrCrimson);
      ObjectSetString (0, BTN_BUY_NAME,    OBJPROP_TEXT,    "매수 시작");
      ObjectSetString (0, BTN_SELL_NAME,   OBJPROP_TEXT,    "매도 시작");
      ObjectSetInteger(0, EDIT_BUY_PRICE,  OBJPROP_BGCOLOR, clrWhite);
      ObjectSetInteger(0, EDIT_SELL_PRICE, OBJPROP_BGCOLOR, clrWhite);
   }

   ChartRedraw(0);
}


//+------------------------------------------------------------------+
//| 숫자 표시: + / - 부호, 0은 0.00                                    |
//+------------------------------------------------------------------+
string FormatSigned(double value)
{
   value = NormalizeDouble(value, 2);

   if(MathAbs(value) < 0.005)
      return "0.00";

   if(value > 0.0)
      return "+" + DoubleToString(value, 2);

   return DoubleToString(value, 2);
}


//+------------------------------------------------------------------+
//| 상태 라벨 (내용이 바뀔 때만 갱신)                                  |
//+------------------------------------------------------------------+
void SetStatus(string text, color clr = clrWhite)
{
   static color last_clr = clrNONE;

   bool exists = (ObjectFind(0, STATUS_LABEL) >= 0);

   if(exists && text == g_status_text && clr == last_clr)
      return;

   g_status_text = text;
   last_clr      = clr;

   if(!exists)
   {
      ObjectCreate(0, STATUS_LABEL, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, STATUS_LABEL, OBJPROP_CORNER,     CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, STATUS_LABEL, OBJPROP_ANCHOR,     ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0, STATUS_LABEL, OBJPROP_XDISTANCE,  15);
      ObjectSetInteger(0, STATUS_LABEL, OBJPROP_YDISTANCE,  75);
      ObjectSetInteger(0, STATUS_LABEL, OBJPROP_FONTSIZE,   10);
      ObjectSetString (0, STATUS_LABEL, OBJPROP_FONT,       "맑은 고딕");
      ObjectSetInteger(0, STATUS_LABEL, OBJPROP_BACK,       false);
      ObjectSetInteger(0, STATUS_LABEL, OBJPROP_SELECTABLE, false);
   }

   ObjectSetString (0, STATUS_LABEL, OBJPROP_TEXT,  "상태: " + text);
   ObjectSetInteger(0, STATUS_LABEL, OBJPROP_COLOR, clr);
}


//+------------------------------------------------------------------+
//| 최근 주문 실패 메시지 (60초간 상태에 유지)                         |
//+------------------------------------------------------------------+
bool HasRecentFailure()
{
   return (g_last_fail_ms > 0 &&
           GetTickCount64() - g_last_fail_ms < 60000);
}


//+------------------------------------------------------------------+
//| 랏 보정 (브로커 최소/최대/스텝 규격)                              |
//+------------------------------------------------------------------+
int LotDigits()
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) return 2;

   int d = 0;
   while(d < 8)
   {
      double scaled = step * MathPow(10.0, d);
      if(MathAbs(scaled - MathRound(scaled)) < 1e-8) break;
      d++;
   }
   return d;
}

double LotStep()
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return (step > 0.0) ? step : 0.01;
}

double NormalizeLot(double lot)
{
   double step = LotStep();
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lot = MathRound(lot / step) * step;

   if(lot < vmin) lot = vmin;
   if(vmax > 0.0 && lot > vmax) lot = vmax;

   return NormalizeDouble(lot, LotDigits());
}


//+------------------------------------------------------------------+
//| 증거금 확인                                                       |
//+------------------------------------------------------------------+
bool HasEnoughMargin(ENUM_ORDER_TYPE type, double lot)
{
   double price = (type == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double margin = 0.0;

   // 계산 자체가 실패하면 서버 판단에 맡긴다
   if(!OrderCalcMargin(type, _Symbol, lot, price, margin))
      return true;

   return (margin <= AccountInfoDouble(ACCOUNT_MARGIN_FREE));
}


//+------------------------------------------------------------------+
//| 체결 확인 대기                                                    |
//| 주문 후 포지션 목록 반영이 늦어도 같은 단계를 다시 보내지 않도록   |
//| 포지션 수가 expect에 도달할 때까지 신규 진입을 막는다.             |
//| 자동 해제: 포지션 확인 / 서버 거절·취소 기록 확인                  |
//| 그 외에는 CONFIRM_WAIT_SEC 후 "수동 확인 필요" → [확인 해제] 버튼  |
//+------------------------------------------------------------------+
void BeginConfirmWait(int expect, ulong order, long magic, string comment)
{
   g_confirm_expect    = expect;
   g_confirm_start_ms  = GetTickCount64();
   g_confirm_order     = order;
   g_confirm_magic     = magic;
   g_confirm_comment   = comment;
   // 서버 시각 오차를 감안해 2초 여유
   g_confirm_send_time = TimeTradeServer() - 2;
   g_confirm_state     = SENT_UNKNOWN;
   g_confirm_check_ms  = 0;
   g_manual_check      = false;
   g_last_alert_ms     = 0;
}

void ClearConfirmWait()
{
   g_confirm_expect   = 0;
   g_confirm_start_ms = 0;
   g_confirm_order    = 0;
   g_confirm_comment  = "";
   g_confirm_state    = SENT_UNKNOWN;
   g_manual_check     = false;
   g_last_alert_ms    = 0;

   HideReleaseButton();
}

int ConfirmWaitElapsedSec()
{
   return (int)((GetTickCount64() - g_confirm_start_ms) / 1000);
}

string SentStateText(ENUM_SENT_STATE st)
{
   switch(st)
   {
      case SENT_ACTIVE:   return "서버 처리 중";
      case SENT_FILLED:   return "체결 기록 있음";
      case SENT_REJECTED: return "거절/취소됨";
   }
   return "서버 기록 없음";
}


//+------------------------------------------------------------------+
//| 보낸 주문을 서버 주문/체결 기록에서 찾는다                         |
//| 주문번호가 없으면(타임아웃) 매직+심볼+코멘트+보낸 시각으로 찾는다  |
//+------------------------------------------------------------------+
bool IsSentOrderMatch(ulong ticket, long magic, string symbol,
                      string comment, datetime time)
{
   if(g_confirm_order > 0)
      return (ticket == g_confirm_order);

   return (magic   == g_confirm_magic &&
           symbol  == _Symbol &&
           comment == g_confirm_comment &&
           time    >= g_confirm_send_time);
}

ENUM_SENT_STATE FindSentOrderState()
{
   //==== 처리 중인 주문 ====
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;

      if(IsSentOrderMatch(t,
                          OrderGetInteger(ORDER_MAGIC),
                          OrderGetString(ORDER_SYMBOL),
                          OrderGetString(ORDER_COMMENT),
                          (datetime)OrderGetInteger(ORDER_TIME_SETUP)))
         return SENT_ACTIVE;
   }

   if(!HistorySelect(g_confirm_send_time, TimeTradeServer() + 3600))
      return SENT_UNKNOWN;

   //==== 체결 기록 (진입 체결) ====
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;

      if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;

      if(IsSentOrderMatch((ulong)HistoryDealGetInteger(d, DEAL_ORDER),
                          HistoryDealGetInteger(d, DEAL_MAGIC),
                          HistoryDealGetString(d, DEAL_SYMBOL),
                          HistoryDealGetString(d, DEAL_COMMENT),
                          (datetime)HistoryDealGetInteger(d, DEAL_TIME)))
         return SENT_FILLED;
   }

   //==== 주문 기록 (가장 최근 것 기준) ====
   for(int i = HistoryOrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = HistoryOrderGetTicket(i);
      if(t == 0) continue;

      if(!IsSentOrderMatch(t,
                           HistoryOrderGetInteger(t, ORDER_MAGIC),
                           HistoryOrderGetString(t, ORDER_SYMBOL),
                           HistoryOrderGetString(t, ORDER_COMMENT),
                           (datetime)HistoryOrderGetInteger(t, ORDER_TIME_SETUP)))
         continue;

      long state = HistoryOrderGetInteger(t, ORDER_STATE);

      if(state == ORDER_STATE_FILLED || state == ORDER_STATE_PARTIAL)
         return SENT_FILLED;

      if(state == ORDER_STATE_REJECTED ||
         state == ORDER_STATE_CANCELED ||
         state == ORDER_STATE_EXPIRED)
         return SENT_REJECTED;

      return SENT_ACTIVE;
   }

   return SENT_UNKNOWN;
}


//+------------------------------------------------------------------+
//| 대기 중이면 true. 포지션 확인 또는 거절 기록이면 대기를 풀고 false |
//+------------------------------------------------------------------+
bool IsInConfirmWait()
{
   if(g_confirm_expect <= 0)
      return false;

   int count = GetTotalPositionsCount();

   if(count >= g_confirm_expect)
   {
      if(g_manual_check)
         Print("포지션 확인됨 - 수동 확인 알림 자동 해제 (", g_confirm_comment, ")");

      ClearConfirmWait();
      return false;
   }

   // 서버 기록 조회는 1초에 한 번
   if(GetTickCount64() - g_confirm_check_ms >= 1000)
   {
      g_confirm_check_ms = GetTickCount64();
      g_confirm_state    = FindSentOrderState();

      if(g_confirm_state == SENT_REJECTED)
      {
         Print(g_confirm_comment, " 서버에서 거절/취소 확인 - 대기 해제");
         ClearConfirmWait();
         return false;
      }
   }

   if(!g_manual_check &&
      GetTickCount64() - g_confirm_start_ms >= (ulong)(CONFIRM_WAIT_SEC * 1000))
   {
      g_manual_check  = true;
      g_last_alert_ms = 0;

      Print("체결 확인 ", CONFIRM_WAIT_SEC, "초 초과 - 마틴 정지, 수동 확인 필요. ",
            g_confirm_comment, " / ", SentStateText(g_confirm_state),
            " / 포지션 ", count, "개 (기대 ", g_confirm_expect, "개)");

      ShowReleaseButton();
   }

   return true;
}


//+------------------------------------------------------------------+
//| [확인 해제] 버튼 표시 / 숨김                                       |
//+------------------------------------------------------------------+
void ShowReleaseButton()
{
   CreateButtonObj(BTN_RELEASE_NAME, 380, 85, "확인 해제",
                   clrDarkOrange, clrOrange);
   ChartRedraw(0);
}

void HideReleaseButton()
{
   if(ObjectFind(0, BTN_RELEASE_NAME) >= 0)
   {
      ObjectDelete(0, BTN_RELEASE_NAME);
      ChartRedraw(0);
   }
}


//+------------------------------------------------------------------+
//| 수동 확인 필요 알림 (경고창 + 소리 + 푸시, 10초 간격)              |
//+------------------------------------------------------------------+
void ProcessManualCheckAlert()
{
   if(!g_manual_check)
      return;

   string msg = "수동 확인 필요: " + g_confirm_comment + " (" +
                IntegerToString(ConfirmWaitElapsedSec()) + "초 경과, " +
                SentStateText(g_confirm_state) + ")";

   SetStatus(msg + " - 확인 후 [확인 해제]", clrRed);

   if(g_last_alert_ms != 0 &&
      GetTickCount64() - g_last_alert_ms < (ulong)(ALERT_INTERVAL_SEC * 1000))
      return;

   g_last_alert_ms = GetTickCount64();

   string full = _Symbol + " " + msg;

   Alert(full);
   PlaySound(ALERT_SOUND_FILE);

   if(USE_PUSH_ALERT &&
      !MQLInfoInteger(MQL_TESTER) &&
      TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
      SendNotification(full);
}


//+------------------------------------------------------------------+
//| 체결 확인 대기 상태 표시                                          |
//+------------------------------------------------------------------+
void ShowConfirmWaitStatus(string prefix)
{
   if(g_manual_check)
   {
      ProcessManualCheckAlert();
      return;
   }

   SetStatus(prefix + " (" + IntegerToString(ConfirmWaitElapsedSec()) + "초, " +
             SentStateText(g_confirm_state) + ")", clrOrange);
}


//+------------------------------------------------------------------+
//| OnTimer: 틱이 없어도 체결 확인과 알림이 동작하도록                 |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(g_confirm_expect <= 0)
      return;

   if(IsInConfirmWait())
      ShowConfirmWaitStatus("체결 확인 대기 중");
   else
      UpdateButtonState();
}


//+------------------------------------------------------------------+
//| 결과가 불확실한 응답 (서버에서는 체결됐을 수 있음)                 |
//+------------------------------------------------------------------+
bool IsUncertainRetcode(uint rc)
{
   return (rc == 0 ||
           rc == TRADE_RETCODE_TIMEOUT ||
           rc == TRADE_RETCODE_ERROR);
}


//+------------------------------------------------------------------+
//| 시장가 주문 공통 처리 (Retcode 확인 포함)                          |
//| 반환값 true: 체결됨 또는 체결됐을 수 있음(확인 대기 진입)          |
//+------------------------------------------------------------------+
bool SendMarketOrder(CTrade &trade, ENUM_ORDER_TYPE type,
                     double lot, string comment)
{
   int count_before = GetTotalPositionsCount();

   g_last_order_tick_ms = GetTickCount64();

   bool sent;

   if(type == ORDER_TYPE_BUY)
      sent = trade.Buy(lot, _Symbol,
                       SymbolInfoDouble(_Symbol, SYMBOL_ASK),
                       0, 0, comment);
   else
      sent = trade.Sell(lot, _Symbol,
                        SymbolInfoDouble(_Symbol, SYMBOL_BID),
                        0, 0, comment);

   // 응답이 늦게 와도 쿨다운은 응답을 받은 시각부터 계산
   g_last_order_tick_ms = GetTickCount64();

   uint rc = trade.ResultRetcode();

   if(sent &&
      (rc == TRADE_RETCODE_DONE ||
       rc == TRADE_RETCODE_DONE_PARTIAL ||
       rc == TRADE_RETCODE_PLACED))
   {
      BeginConfirmWait(count_before + 1, trade.ResultOrder(),
                       (long)trade.RequestMagic(), comment);
      g_last_fail_ms = 0;

      Print(comment, " 체결 (",
            DoubleToString(lot, LotDigits()), " lot)");

      return true;
   }

   if(IsUncertainRetcode(rc))
   {
      // 실패로 보고 재전송하면 중복 진입이 되므로 확인 대기로 처리
      BeginConfirmWait(count_before + 1, trade.ResultOrder(),
                       (long)trade.RequestMagic(), comment);

      g_last_fail_msg = comment + " 결과 미확정 (" +
                        IntegerToString((int)rc) + " " +
                        trade.ResultRetcodeDescription() + ") - 체결 확인 대기";
      g_last_fail_ms  = GetTickCount64();

      Print(g_last_fail_msg);
      SetStatus(g_last_fail_msg, clrOrange);
      return true;
   }

   g_last_fail_msg = comment + " 실패 (" +
                     IntegerToString((int)rc) + " " +
                     trade.ResultRetcodeDescription() + ")";
   g_last_fail_ms  = GetTickCount64();

   Print(g_last_fail_msg);
   SetStatus(g_last_fail_msg, clrRed);
   return false;
}


//+------------------------------------------------------------------+
//| 예약가격 읽기                                                     |
//+------------------------------------------------------------------+
void ReadReservationPrices()
{
   if(g_cycle_active)
      return;

   string buy_text  = ObjectGetString(0, EDIT_BUY_PRICE,  OBJPROP_TEXT);
   string sell_text = ObjectGetString(0, EDIT_SELL_PRICE, OBJPROP_TEXT);

   // MQL5의 StringTrim 계열은 원본을 직접 수정한다
   StringTrimLeft(buy_text);
   StringTrimRight(buy_text);
   StringTrimLeft(sell_text);
   StringTrimRight(sell_text);

   g_buy_reserve_price  = (buy_text  == "") ? 0.0 : StringToDouble(buy_text);
   g_sell_reserve_price = (sell_text == "") ? 0.0 : StringToDouble(sell_text);

   if(g_buy_reserve_price  < 0.0) g_buy_reserve_price  = 0.0;
   if(g_sell_reserve_price < 0.0) g_sell_reserve_price = 0.0;
}


//+------------------------------------------------------------------+
//| 예약가격 모두 삭제                                                |
//+------------------------------------------------------------------+
void ClearReservationPrices()
{
   g_buy_reserve_price  = 0.0;
   g_sell_reserve_price = 0.0;

   if(ObjectFind(0, EDIT_BUY_PRICE) >= 0)
      ObjectSetString(0, EDIT_BUY_PRICE, OBJPROP_TEXT, "");

   if(ObjectFind(0, EDIT_SELL_PRICE) >= 0)
      ObjectSetString(0, EDIT_SELL_PRICE, OBJPROP_TEXT, "");

   ChartRedraw(0);

   Print("매수/매도 예약가격을 모두 삭제했습니다.");
}


//+------------------------------------------------------------------+
//| 손절 후 대기 중인지                                               |
//+------------------------------------------------------------------+
bool IsInLossWait()
{
   return (InpUseStopAfterLoss &&
           g_last_loss_time > 0 &&
           TimeCurrent() < g_last_loss_time + InpStopWaitMinutes * 60);
}

int LossWaitRemainMinutes()
{
   long remain_sec = (long)(g_last_loss_time + InpStopWaitMinutes * 60 - TimeCurrent());
   if(remain_sec < 0) remain_sec = 0;
   return (int)(remain_sec / 60) + 1;
}


//+------------------------------------------------------------------+
//| 첫 진입(수동/예약) 가능 여부. 불가하면 reason에 사유               |
//+------------------------------------------------------------------+
bool CanStartEntry(string &reason)
{
   reason = "";

   if(g_close_pending)
   {
      reason = "청산 처리 중";
      return false;
   }

   if(IsInConfirmWait())
   {
      reason = g_manual_check ? "수동 확인 필요" : "체결 확인 대기";
      return false;
   }

   if(InpUseTimeFilter && !IsTradingTime())
   {
      reason = "시간필터 (서버시간 " +
               TimeToString(TimeCurrent(), TIME_MINUTES) + ")";
      return false;
   }

   if(IsInNewsTime())
   {
      reason = "뉴스필터 (해제 " +
               TimeToString(g_news_block_until, TIME_DATE | TIME_MINUTES) +
               " 서버시간)";
      return false;
   }

   if(InpBlockEntryAfterLoss && IsInLossWait())
   {
      reason = "손절 후 대기 (남은 " +
               IntegerToString(LossWaitRemainMinutes()) + "분)";
      return false;
   }

   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpread)
   {
      reason = "스프레드 초과 (현재 " + DoubleToString(spread, 0) +
               " / 한도 " + DoubleToString(InpMaxSpread, 0) + ")";
      return false;
   }

   return true;
}


//+------------------------------------------------------------------+
//| 차트 이벤트                                                       |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      //==== 매수 / 매도 시작 버튼 ====
      if(sparam == BTN_BUY_NAME || sparam == BTN_SELL_NAME)
      {
         bool is_buy = (sparam == BTN_BUY_NAME);

         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);

         if(g_cycle_active || IsInConfirmWait() || GetTotalPositionsCount() > 0)
         {
            Print("현재 진행 중인 거래가 있어 ",
                  (is_buy ? "매수" : "매도"),
                  " 시작 버튼을 사용할 수 없습니다.");
            return;
         }

         // 수동 시작하면 예약가격 모두 삭제
         ClearReservationPrices();

         g_trade_mode = is_buy ? MODE_BUY : MODE_SELL;

         if(StartNewCycle())
         {
            g_cycle_active = true;
         }
         else
         {
            g_trade_mode   = MODE_NONE;
            g_cycle_active = false;
         }

         UpdateButtonState(true);
         return;
      }

      //==== 확인 해제 버튼 (수동 확인 필요 상태에서만 표시) ====
      if(sparam == BTN_RELEASE_NAME)
      {
         ObjectSetInteger(0, BTN_RELEASE_NAME, OBJPROP_STATE, false);

         Print("[확인 해제] 버튼 클릭 - 수동 확인 완료, 체결 확인 대기 해제 (",
               g_confirm_comment, ")");

         ClearConfirmWait();
         g_last_order_tick_ms = GetTickCount64();   // 해제 직후 바로 주문하지 않도록

         UpdateButtonState(true);
         SetStatus("수동 확인 해제됨");
         return;
      }

      //==== 전체 청산 버튼 ====
      if(sparam == BTN_CLOSE_NAME)
      {
         ObjectSetInteger(0, BTN_CLOSE_NAME, OBJPROP_STATE, false);

         Print("수동 [전체 청산] 버튼 클릭 - 모든 포지션 즉시 청산 진행");

         CloseAll(true, false);
         return;
      }

      //==== 예약가격 입력창 클릭 ====
      if(sparam == EDIT_BUY_PRICE || sparam == EDIT_SELL_PRICE)
      {
         if(!g_cycle_active && GetTotalPositionsCount() == 0)
            ReadReservationPrices();
         return;
      }
   }

   //==== 입력 완료 / 키 입력 ====
   if(id == CHARTEVENT_OBJECT_ENDEDIT || id == CHARTEVENT_KEYDOWN)
   {
      if(!g_cycle_active && GetTotalPositionsCount() == 0)
         ReadReservationPrices();
   }
}


//+------------------------------------------------------------------+
//| 첫 진입 (수동 버튼)                                               |
//+------------------------------------------------------------------+
bool StartNewCycle()
{
   string reason;

   if(!CanStartEntry(reason))
   {
      Print("첫 진입 차단: ", reason);
      SetStatus("진입 차단: " + reason, clrOrange);
      return false;
   }

   if(GetTickCount64() - g_last_order_tick_ms <
      (ulong)(InpOrderCoolDownSec * 1000))
   {
      Print("첫 진입 차단: 주문 쿨다운");
      SetStatus("진입 차단: 주문 쿨다운", clrOrange);
      return false;
   }

   ENUM_ORDER_TYPE type = (g_trade_mode == MODE_BUY)
                          ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   double lot = NormalizeLot(InpInitLot);

   if(!HasEnoughMargin(type, lot))
   {
      string msg = "증거금 부족 (랏 " + DoubleToString(lot, LotDigits()) + ")";
      Print("첫 진입 차단: ", msg);
      SetStatus("진입 차단: " + msg, clrRed);
      return false;
   }

   string comment = (type == ORDER_TYPE_BUY) ? "Init Buy" : "Init Sell";

   if(!SendMarketOrder(m_trade, type, lot, comment))
   {
      g_trade_mode   = MODE_NONE;
      g_cycle_active = false;
      return false;
   }

   Print("첫 진입 주문 완료. 거래 모드 = ",
         (g_trade_mode == MODE_BUY ? "BUY" : "SELL"));

   return true;
}


//+------------------------------------------------------------------+
//| 예약진입 체크 (포지션 없을 때 매 틱)                               |
//+------------------------------------------------------------------+
void CheckReservationEntry()
{
   if(g_cycle_active || GetTotalPositionsCount() > 0)
      return;

   ReadReservationPrices();

   string reason;
   bool   can_enter = CanStartEntry(reason);

   //==== 예약가격 없음 → 대기 상태만 표시 ====
   if(g_buy_reserve_price <= 0.0 && g_sell_reserve_price <= 0.0)
   {
      if(HasRecentFailure())
         SetStatus(g_last_fail_msg, clrRed);
      else if(!can_enter)
         SetStatus("대기 중 | 현재 진입 불가: " + reason, clrOrange);
      else
         SetStatus("대기 중 (포지션 없음)");
      return;
   }

   //==== 진입 차단 ====
   if(!can_enter)
   {
      SetStatus("예약 보류: " + reason, clrOrange);
      return;
   }

   //==== 주문 쿨다운 ====
   if(GetTickCount64() - g_last_order_tick_ms <
      (ulong)(InpOrderCoolDownSec * 1000))
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // 매수: ASK가 예약가격 이하 / 매도: BID가 예약가격 이상
   bool buy_trigger  = (g_buy_reserve_price  > 0.0 && ask <= g_buy_reserve_price);
   bool sell_trigger = (g_sell_reserve_price > 0.0 && bid >= g_sell_reserve_price);

   if(buy_trigger && sell_trigger)
   {
      Print("매수/매도 예약 조건이 동시에 성립하여 안전상 진입을 보류합니다.");
      SetStatus("예약 보류: 매수/매도 조건 동시 성립", clrOrange);
      return;
   }

   //==== 예약가 미도달 → 대기 표시 ====
   if(!buy_trigger && !sell_trigger)
   {
      if(HasRecentFailure())
      {
         SetStatus(g_last_fail_msg, clrRed);
         return;
      }

      string s = "예약 대기";
      if(g_buy_reserve_price > 0.0)
         s += " | 매수 ≤ " + DoubleToString(g_buy_reserve_price, _Digits);
      if(g_sell_reserve_price > 0.0)
         s += " | 매도 ≥ " + DoubleToString(g_sell_reserve_price, _Digits);

      SetStatus(s);
      return;
   }

   //==== 예약 진입 실행 ====
   ENUM_TRADE_MODE mode    = buy_trigger ? MODE_BUY : MODE_SELL;
   ENUM_ORDER_TYPE type    = buy_trigger ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double          reserve = buy_trigger ? g_buy_reserve_price : g_sell_reserve_price;
   double          now_px  = buy_trigger ? ask : bid;

   Print("★ ", (buy_trigger ? "매수" : "매도"), " 예약가격 도달: ",
         DoubleToString(reserve, _Digits),
         " / 현재 ", (buy_trigger ? "ASK: " : "BID: "),
         DoubleToString(now_px, _Digits));

   double lot = NormalizeLot(InpInitLot);

   if(!HasEnoughMargin(type, lot))
   {
      string msg = "증거금 부족 (랏 " + DoubleToString(lot, LotDigits()) + ")";
      Print("예약 진입 보류: ", msg);
      SetStatus("예약 보류: " + msg, clrRed);
      g_last_order_tick_ms = GetTickCount64();   // 매 틱 반복 방지
      return;
   }

   g_trade_mode = mode;

   if(SendMarketOrder(m_trade, type, lot,
                      buy_trigger ? "Reserve Buy" : "Reserve Sell"))
   {
      Print("★ 예약 ", (buy_trigger ? "매수" : "매도"), " 주문 완료");

      // 예약진입 성공 → 예약가격 모두 삭제, 수동 시작과 같은 상태
      ClearReservationPrices();

      g_trade_mode   = mode;
      g_cycle_active = true;

      UpdateButtonState(true);
   }
   else
   {
      g_trade_mode   = MODE_NONE;
      g_cycle_active = false;
   }
}


//+------------------------------------------------------------------+
//| 내 포지션 여부 (선택된 포지션 기준)                                |
//+------------------------------------------------------------------+
bool IsMySelectedPosition()
{
   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;

   long magic = PositionGetInteger(POSITION_MAGIC);

   return (magic == InpMagicNumber || magic == InpTrendMagicNumber);
}


//+------------------------------------------------------------------+
//| 전체 포지션 개수                                                  |
//+------------------------------------------------------------------+
int GetTotalPositionsCount()
{
   int count = 0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket > 0 && PositionSelectByTicket(ticket) && IsMySelectedPosition())
         count++;
   }

   return count;
}


//+------------------------------------------------------------------+
//| ATR 비율                                                          |
//+------------------------------------------------------------------+
double GetClampedATRRatio()
{
   double current_atr = GetCurrentATR();
   double avg_atr     = GetAverageATR(50);

   if(avg_atr <= 0.0 || current_atr <= 0.0)
      return 1.0;

   double ratio = current_atr / avg_atr;

   if(ratio < 0.7) ratio = 0.7;
   if(ratio > 3.0) ratio = 3.0;

   return ratio;
}


//+------------------------------------------------------------------+
//| 기본 마틴 랏                                                     |
//+------------------------------------------------------------------+
double GetCustomMartinLot(int step)
{
   static double base_lots[] =
   {
      0.02, 0.03, 0.05, 0.08, 0.12, 0.18, 0.27, 0.38, 0.52
   };

   if(step >= 1 && step <= 9)
   {
      double scale_factor = InpInitLot / 0.01;
      return base_lots[step - 1] * scale_factor;
   }

   return InpInitLot;
}


//+------------------------------------------------------------------+
//| 현재 ATR                                                          |
//+------------------------------------------------------------------+
double GetCurrentATR()
{
   double atr_buff[];
   ArraySetAsSeries(atr_buff, true);

   if(CopyBuffer(g_atr_handle, 0, 0, 1, atr_buff) <= 0)
      return 0.0;

   return atr_buff[0];
}


//+------------------------------------------------------------------+
//| 평균 ATR                                                          |
//| ★ v6.6: 실제로 복사된 개수만큼만 평균 (array out of range 방지)   |
//+------------------------------------------------------------------+
double GetAverageATR(int periods)
{
   double atr_buff[];
   ArraySetAsSeries(atr_buff, true);

   int copied = CopyBuffer(g_atr_handle, 0, 0, periods, atr_buff);

   if(copied <= 0)
      return 0.0;

   double sum = 0.0;

   for(int i = 0; i < copied; i++)
      sum += atr_buff[i];

   return sum / copied;
}


//+------------------------------------------------------------------+
//| 동적 그리드 간격                                                  |
//+------------------------------------------------------------------+
int GetDynamicGridDistance()
{
   double base_dist = (double)InpBaseDistance;

   if(!InpUseATRScale)
      return (int)base_dist;

   return (int)(base_dist * GetClampedATRRatio());
}


//+------------------------------------------------------------------+
//| 동적 마틴 랏                                                     |
//+------------------------------------------------------------------+
double GetDynamicMartinLot(int step)
{
   double base_lot = GetCustomMartinLot(step);

   if(!InpUseATRLotScale && !InpUseLowVolLotExpand)
      return NormalizeLot(base_lot);

   double ratio     = GetClampedATRRatio();
   double lot_scale = 1.0;

   if(ratio > 1.0 && InpUseATRLotScale)
      lot_scale = 1.0 / ratio;
   else if(ratio < 1.0 && InpUseLowVolLotExpand)
      lot_scale = 1.0 / ratio;

   return NormalizeLot(base_lot * lot_scale);
}


//+------------------------------------------------------------------+
//| 뉴스 필터 (첫 진입에만 사용)                                      |
//+------------------------------------------------------------------+
bool IsInNewsTime()
{
   if(!InpUseNewsFilter)
      return false;

   static bool     cached_result   = false;
   static datetime last_check_time = 0;

   datetime now = TimeTradeServer();

   if(now - last_check_time < 60)
      return cached_result;

   last_check_time    = now;
   cached_result      = false;
   g_news_block_until = 0;

   datetime from = now - (InpNewsPostHours * 3600) - 3600;
   datetime to   = now + (InpNewsPreHours  * 3600) + 3600;

   MqlCalendarValue values[];

   int count = CalendarValueHistory(values, from, to, NULL, InpNewsCurrency);

   for(int i = 0; i < count; i++)
   {
      MqlCalendarEvent event;

      if(!CalendarEventById(values[i].event_id, event))
         continue;

      if(event.importance != CALENDAR_IMPORTANCE_HIGH)
         continue;

      datetime event_time  = values[i].time;
      datetime block_start = event_time - (InpNewsPreHours  * 3600);
      datetime block_end   = event_time + (InpNewsPostHours * 3600);

      if(now >= block_start && now <= block_end)
      {
         cached_result = true;

         // 겹치는 뉴스 중 가장 늦은 해제 시각 기록
         if(block_end > g_news_block_until)
            g_news_block_until = block_end;
      }
   }

   return cached_result;
}


//+------------------------------------------------------------------+
//| 거래 시간 필터 (서버시간 기준)                                    |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
   MqlDateTime dt;
   TimeCurrent(dt);

   int hm = dt.hour * 100 + dt.min;

   bool session1 = (hm >= InpTime1Start && hm <= InpTime1End);
   bool session2 = (hm >= InpTime2Start && hm <= InpTime2End);

   return (session1 || session2);
}


//+------------------------------------------------------------------+
//| 오늘 실현손익                                                     |
//+------------------------------------------------------------------+
double GetTodayRealizedProfit()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;

   datetime start = StructToTime(dt);

   if(!HistorySelect(start, TimeCurrent() + 60))
      return 0.0;

   double profit = 0.0;

   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;

      long magic = HistoryDealGetInteger(t, DEAL_MAGIC);

      if(magic == InpMagicNumber || magic == InpTrendMagicNumber)
      {
         profit += HistoryDealGetDouble(t, DEAL_PROFIT);
         profit += HistoryDealGetDouble(t, DEAL_COMMISSION);
         profit += HistoryDealGetDouble(t, DEAL_SWAP);
      }
   }

   return profit;
}


//+------------------------------------------------------------------+
//| 오늘 익절 레이블                                                  |
//+------------------------------------------------------------------+
void UpdateProfitLabel(double profit)
{
   if(ObjectFind(0, LABEL_NAME) < 0)
   {
      ObjectCreate(0, LABEL_NAME, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, LABEL_NAME, OBJPROP_CORNER,     CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, LABEL_NAME, OBJPROP_ANCHOR,     ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0, LABEL_NAME, OBJPROP_XDISTANCE,  15);
      ObjectSetInteger(0, LABEL_NAME, OBJPROP_YDISTANCE,  45);
      ObjectSetInteger(0, LABEL_NAME, OBJPROP_FONTSIZE,   12);
      ObjectSetString (0, LABEL_NAME, OBJPROP_FONT,       "Arial Black");
      ObjectSetInteger(0, LABEL_NAME, OBJPROP_BACK,       false);
      ObjectSetInteger(0, LABEL_NAME, OBJPROP_SELECTABLE, false);
   }

   ObjectSetString (0, LABEL_NAME, OBJPROP_TEXT,  "오늘 익절: " + FormatSigned(profit));
   ObjectSetInteger(0, LABEL_NAME, OBJPROP_COLOR, clrYellow);
}


//+------------------------------------------------------------------+
//| 현재 손익 레이블                                                  |
//+------------------------------------------------------------------+
void UpdateCurrentProfitLabel(double profit)
{
   if(ObjectFind(0, CURRENT_PROFIT_LABEL) < 0)
   {
      ObjectCreate(0, CURRENT_PROFIT_LABEL, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, CURRENT_PROFIT_LABEL, OBJPROP_CORNER,     CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, CURRENT_PROFIT_LABEL, OBJPROP_ANCHOR,     ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0, CURRENT_PROFIT_LABEL, OBJPROP_XDISTANCE,  15);
      ObjectSetInteger(0, CURRENT_PROFIT_LABEL, OBJPROP_YDISTANCE,  15);
      ObjectSetInteger(0, CURRENT_PROFIT_LABEL, OBJPROP_FONTSIZE,   12);
      ObjectSetString (0, CURRENT_PROFIT_LABEL, OBJPROP_FONT,       "Arial Black");
      ObjectSetInteger(0, CURRENT_PROFIT_LABEL, OBJPROP_BACK,       false);
      ObjectSetInteger(0, CURRENT_PROFIT_LABEL, OBJPROP_SELECTABLE, false);
   }

   ObjectSetString (0, CURRENT_PROFIT_LABEL, OBJPROP_TEXT,  "현재 손익: " + FormatSigned(profit));
   ObjectSetInteger(0, CURRENT_PROFIT_LABEL, OBJPROP_COLOR, clrLime);
}


//+------------------------------------------------------------------+
//| 전체 청산 요청                                                    |
//+------------------------------------------------------------------+
void CloseAll(bool record_time, bool is_loss)
{
   // 포지션이 없으면 상태만 초기화 (예약가격은 유지)
   if(GetTotalPositionsCount() == 0 && !g_close_pending)
   {
      if(record_time)
      {
         g_last_close_time = TimeCurrent();
         if(is_loss) g_last_loss_time = g_last_close_time;
      }

      g_trade_mode     = MODE_NONE;
      g_cycle_active   = false;
      g_highest_profit = 0.0;
      ClearConfirmWait();

      UpdateButtonState(true);
      return;
   }

   g_close_pending = true;
   if(record_time) g_close_record_time = true;
   if(is_loss)     g_close_is_loss     = true;

   ProcessCloseAll();
}


//+------------------------------------------------------------------+
//| 내 포지션 전부 청산 시도 → 남은 개수 반환                          |
//+------------------------------------------------------------------+
int CloseMatchingPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(!IsMySelectedPosition())
         continue;

      bool sent = m_trade.PositionClose(ticket);
      uint rc   = m_trade.ResultRetcode();

      if(!sent || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_DONE_PARTIAL))
      {
         Print("포지션 청산 실패. Ticket=", ticket,
               " Retcode=", rc, " / ", m_trade.ResultRetcodeDescription());
      }
   }

   return GetTotalPositionsCount();
}


//+------------------------------------------------------------------+
//| 청산 처리 (최대 3회 시도, 남으면 다음 틱에 재시도)                 |
//+------------------------------------------------------------------+
void ProcessCloseAll()
{
   int remain = GetTotalPositionsCount();

   for(int attempt = 0; attempt < 3 && remain > 0; attempt++)
   {
      if(attempt > 0)
         Sleep(300);

      remain = CloseMatchingPositions();
   }

   if(remain > 0)
   {
      string msg = "청산 재시도 중 (잔여 " + IntegerToString(remain) + "개)";
      Print(msg);
      SetStatus(msg, clrRed);
      return;   // 상태 유지 → OnTick에서 재시도
   }

   FinishCloseAll();
}


//+------------------------------------------------------------------+
//| 청산 완료 처리                                                    |
//+------------------------------------------------------------------+
void FinishCloseAll()
{
   if(g_close_record_time)
   {
      datetime now = TimeCurrent();
      g_last_close_time = now;
      if(g_close_is_loss) g_last_loss_time = now;
   }

   bool was_loss = g_close_is_loss;

   g_close_pending     = false;
   g_close_record_time = false;
   g_close_is_loss     = false;

   ClearConfirmWait();
   ClearReservationPrices();

   g_trade_mode     = MODE_NONE;
   g_cycle_active   = false;
   g_highest_profit = 0.0;

   UpdateButtonState(true);

   Print("전체 청산 완료 - 예약 매수/매도 가격 자동 삭제");
   SetStatus(was_loss ? "손절 청산 완료" : "전체 청산 완료",
             was_loss ? clrOrange : clrWhite);
}


//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   //================================================================
   // 오늘 실현손익 (1초마다 갱신)
   //================================================================
   static ulong last_pl_ms = 0;

   if(last_pl_ms == 0 || GetTickCount64() - last_pl_ms >= 1000)
   {
      last_pl_ms = GetTickCount64();
      UpdateProfitLabel(GetTodayRealizedProfit());
   }

   //================================================================
   // 청산 재시도 처리
   //================================================================
   if(g_close_pending)
   {
      if(GetTotalPositionsCount() == 0)
      {
         FinishCloseAll();
      }
      else
      {
         static ulong last_retry_ms = 0;

         if(GetTickCount64() - last_retry_ms >= 1000)
         {
            last_retry_ms = GetTickCount64();
            ProcessCloseAll();
         }
         return;
      }
   }

   //================================================================
   // 체결 확인 대기 여부 (직전 주문이 포지션 목록에 반영됐는지)
   //================================================================
   bool confirm_wait = IsInConfirmWait();

   //================================================================
   // 포지션 스캔
   //================================================================
   int    buy_cnt   = 0;
   int    sell_cnt  = 0;
   int    trend_cnt = 0;

   double buy_lots  = 0.0;
   double sell_lots = 0.0;

   double my_total_profit = 0.0;

   double last_buy  = DBL_MAX;   // 가장 낮은 매수가
   double last_sell = 0.0;       // 가장 높은 매도가

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0 || !PositionSelectByTicket(ticket) || !IsMySelectedPosition())
         continue;

      long magic = PositionGetInteger(POSITION_MAGIC);

      my_total_profit += PositionGetDouble(POSITION_PROFIT) +
                         PositionGetDouble(POSITION_SWAP);

      if(magic == InpMagicNumber)
      {
         long   type  = PositionGetInteger(POSITION_TYPE);
         double price = PositionGetDouble(POSITION_PRICE_OPEN);
         double vol   = PositionGetDouble(POSITION_VOLUME);

         if(type == POSITION_TYPE_BUY)
         {
            buy_cnt++;
            buy_lots += vol;
            if(price < last_buy) last_buy = price;
         }
         else
         {
            sell_cnt++;
            sell_lots += vol;
            if(price > last_sell) last_sell = price;
         }
      }
      else if(magic == InpTrendMagicNumber)
      {
         trend_cnt++;
      }
   }

   UpdateCurrentProfitLabel(my_total_profit);

   //================================================================
   // 거래 상태 동기화
   //================================================================
   if(buy_cnt > 0)
   {
      g_trade_mode   = MODE_BUY;
      g_cycle_active = true;
   }
   else if(sell_cnt > 0)
   {
      g_trade_mode   = MODE_SELL;
      g_cycle_active = true;
   }

   //================================================================
   // 포지션이 하나도 없는 경우
   //================================================================
   if(buy_cnt == 0 && sell_cnt == 0 && trend_cnt == 0)
   {
      // 방금 보낸 첫 진입이 아직 목록에 안 보이는 경우 → 사이클 유지
      if(confirm_wait)
      {
         UpdateButtonState();
         ShowConfirmWaitStatus("체결 확인 대기 중");
         return;
      }

      // 외부(수동/서버)에서 청산된 경우 사이클 종료
      if(g_cycle_active)
      {
         ClearReservationPrices();

         g_cycle_active   = false;
         g_trade_mode     = MODE_NONE;
         g_highest_profit = 0.0;
      }

      UpdateButtonState();
      CheckReservationEntry();
      return;
   }

   UpdateButtonState();

   //================================================================
   // 1. 청산 / 손절 / 트레일링
   //    ★ v6.6: 스프레드와 무관하게 항상 먼저 검사
   //================================================================

   // 최대손실
   if(InpUseMaxLoss && my_total_profit <= -InpMaxLossDollar)
   {
      Print("최대손실 도달 (", FormatSigned(my_total_profit), ") - 전체 청산");
      CloseAll(true, true);
      return;
   }

   // 최고 수익 갱신
   if(my_total_profit > g_highest_profit)
      g_highest_profit = my_total_profit;

   bool   trailing_active = (InpUseTrailingClose &&
                             g_highest_profit >= InpTrailStartDollar);
   double trail_limit     = 0.0;

   if(trailing_active)
   {
      double retracement_limit = g_highest_profit *
                                 (1.0 - (InpTrailRetratePct / 100.0));

      trail_limit = (retracement_limit > InpTrailMinLockDollar)
                    ? retracement_limit : InpTrailMinLockDollar;

      if(my_total_profit <= trail_limit)
      {
         Print("트레일링 청산 (최고 ", FormatSigned(g_highest_profit),
               " / 현재 ", FormatSigned(my_total_profit), ")");
         CloseAll(true, false);
         return;
      }
   }
   else if(InpUseTotalTP && my_total_profit >= InpTotalTPDollar)
   {
      Print("전체 익절 (", FormatSigned(my_total_profit), ")");
      CloseAll(true, false);
      return;
   }

   //================================================================
   // ★ v6.7: 직전 주문이 확인되기 전에는 추가 진입 금지
   //         (같은 마틴 단계가 두 번 들어가는 것 방지)
   // ★ v6.8: 5초 넘게 미확인이면 수동 확인 알림 (10초 간격 반복)
   //================================================================
   if(confirm_wait)
   {
      ShowConfirmWaitStatus("체결 확인 대기 중 - 추가 진입 보류");
      return;
   }

   //================================================================
   // 스프레드 필터 (추가 진입만 보류)
   //================================================================
   double current_spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   if(current_spread > InpMaxSpread)
   {
      SetStatus("스프레드 초과 - 추가 진입 보류 (현재 " +
                DoubleToString(current_spread, 0) + ")", clrOrange);
      return;
   }

   //================================================================
   // MODE_NONE이면 추가 진입 금지 (헤지만 남은 경우 포함)
   //================================================================
   if(g_trade_mode == MODE_NONE || (buy_cnt == 0 && sell_cnt == 0))
   {
      SetStatus("경고: 헤지 포지션만 남음 (익절/손절 조건으로만 청산)", clrOrange);
      return;
   }

   //================================================================
   // 주문 쿨다운 (상태 표시는 유지)
   //================================================================
   if(GetTickCount64() - g_last_order_tick_ms <
      (ulong)(InpOrderCoolDownSec * 1000))
      return;

   //================================================================
   // 손절 후 대기
   //================================================================
   if(IsInLossWait())
   {
      SetStatus("손절 후 대기 - 마틴 보류 (남은 " +
                IntegerToString(LossWaitRemainMinutes()) + "분)", clrOrange);
      return;
   }

   //================================================================
   // 전체청산 후 대기
   //================================================================
   if(InpUseWaitAfterClose &&
      TimeCurrent() < g_last_close_time + InpWaitAfterCloseSec)
   {
      SetStatus("청산 후 대기 중", clrOrange);
      return;
   }

   // ★ v6.6: 뉴스 필터는 첫 진입에만 적용 → 진행 중 마틴은 차단하지 않음

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   int required_dist = GetDynamicGridDistance();

   //================================================================
   // 2. 매수 마틴
   //================================================================
   if(g_trade_mode == MODE_BUY && buy_cnt > 0 && buy_cnt < InpMaxMartinStep)
   {
      if(last_buy - ask >= required_dist * g_point)
      {
         double next_lot = GetDynamicMartinLot(buy_cnt);

         if(!HasEnoughMargin(ORDER_TYPE_BUY, next_lot))
         {
            g_last_fail_msg = "증거금 부족 - 마틴 매수 보류 (랏 " +
                              DoubleToString(next_lot, LotDigits()) + ")";
            g_last_fail_ms  = GetTickCount64();
            g_last_order_tick_ms = GetTickCount64();
            Print(g_last_fail_msg);
            SetStatus(g_last_fail_msg, clrRed);
            return;
         }

         SendMarketOrder(m_trade, ORDER_TYPE_BUY, next_lot,
                         "Martin Buy " + IntegerToString(buy_cnt + 1));
         return;
      }
   }

   //================================================================
   // 3. 매도 마틴
   //================================================================
   if(g_trade_mode == MODE_SELL && sell_cnt > 0 && sell_cnt < InpMaxMartinStep)
   {
      if(bid - last_sell >= required_dist * g_point)
      {
         double next_lot = GetDynamicMartinLot(sell_cnt);

         if(!HasEnoughMargin(ORDER_TYPE_SELL, next_lot))
         {
            g_last_fail_msg = "증거금 부족 - 마틴 매도 보류 (랏 " +
                              DoubleToString(next_lot, LotDigits()) + ")";
            g_last_fail_ms  = GetTickCount64();
            g_last_order_tick_ms = GetTickCount64();
            Print(g_last_fail_msg);
            SetStatus(g_last_fail_msg, clrRed);
            return;
         }

         SendMarketOrder(m_trade, ORDER_TYPE_SELL, next_lot,
                         "Martin Sell " + IntegerToString(sell_cnt + 1));
         return;
      }
   }

   //================================================================
   // 4. 추세 트리거 헤지
   //================================================================
   if(InpUseTrendTrigger && trend_cnt == 0)
   {
      bool   need_hedge = false;
      double raw_lot    = 0.0;
      ENUM_ORDER_TYPE hedge_type = ORDER_TYPE_SELL;

      if(g_trade_mode == MODE_BUY && buy_cnt >= InpTrendTriggerStep)
      {
         need_hedge = true;
         raw_lot    = buy_lots * (InpTrendLotPct / 100.0);
         hedge_type = ORDER_TYPE_SELL;
      }
      else if(g_trade_mode == MODE_SELL && sell_cnt >= InpTrendTriggerStep)
      {
         need_hedge = true;
         raw_lot    = sell_lots * (InpTrendLotPct / 100.0);
         hedge_type = ORDER_TYPE_BUY;
      }

      if(need_hedge)
      {
         double step    = LotStep();
         double vmin    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         double rounded = MathRound(raw_lot / step) * step;

         // 최소 랏 미만이면 헤지 생략 (기존 0.01 미만 생략과 동일)
         if(rounded >= vmin - 1e-9)
         {
            SendMarketOrder(m_trade_trend, hedge_type,
                            NormalizeLot(raw_lot), "Trend Hedge");
            return;
         }
      }
   }

   //================================================================
   // 5. 상태 표시
   //================================================================
   if(HasRecentFailure())
   {
      SetStatus(g_last_fail_msg, clrRed);
      return;
   }

   int    cnt = (g_trade_mode == MODE_BUY) ? buy_cnt : sell_cnt;
   string s;

   if(cnt >= InpMaxMartinStep)
   {
      s = "최대 단계 도달 (" + IntegerToString(cnt) + "/" +
          IntegerToString(InpMaxMartinStep) + ") - 익절/손절 대기";
   }
   else
   {
      double next_px = (g_trade_mode == MODE_BUY)
                       ? last_buy  - required_dist * g_point
                       : last_sell + required_dist * g_point;

      s = "마틴 대기 " + IntegerToString(cnt) + "/" +
          IntegerToString(InpMaxMartinStep) +
          " | 다음 진입가 " + DoubleToString(next_px, _Digits) +
          " (간격 " + IntegerToString(required_dist) + "pt)";
   }

   if(trend_cnt > 0)
      s += " | 헤지 보유";

   if(trailing_active)
      s += " | 트레일링 청산선 " + FormatSigned(trail_limit);

   SetStatus(s);
}
//+------------------------------------------------------------------+
