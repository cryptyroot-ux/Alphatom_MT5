//+------------------------------------------------------------------+
//| AlphatomHistoryDepth.mq5                                         |
//| Asks the broker for deep history and reports what it really has.  |
//+------------------------------------------------------------------+
#property version "1.00"
input int InpDays = 365;
int OnInit()
  {
   const ENUM_TIMEFRAMES tfs[6] = {PERIOD_M1, PERIOD_M2, PERIOD_M3, PERIOD_M15, PERIOD_M30, PERIOD_H1};
   const datetime from = TimeCurrent() - InpDays * 86400;
   for(int i = 0; i < 6; ++i)
     {
      MqlRates rates[];
      ArraySetAsSeries(rates, false);
      const int got = CopyRates(_Symbol, tfs[i], from, 1000000, rates);
      datetime oldest = 0;
      if(got > 0)
         oldest = rates[0].time;
      PrintFormat("AT_DEEP tf=%s days=%d copied=%d oldest=%s err=%d",
                  EnumToString(tfs[i]), InpDays, got,
                  oldest > 0 ? TimeToString(oldest, TIME_DATE | TIME_MINUTES) : "-",
                  GetLastError());
     }
   return INIT_SUCCEEDED;
  }
void OnTick() {}
