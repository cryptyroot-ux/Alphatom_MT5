//+------------------------------------------------------------------+
//| AlphatomBarsExport.mq5                                           |
//| Exports closed bars for an offline replay of the execution       |
//| kernel. Read-only: this expert never sends an order.             |
//+------------------------------------------------------------------+
#property copyright "Alphatom"
#property version   "1.00"
#property description "Exports M1/M15/M30/H1 bars for kernel replay (read-only)"

input int    InpM1Bars   = 4000;
input int    InpPoiBars  = 1500;
input string InpTag      = "BEX";

int OnInit()
  {
   const int handleM1 = FileOpen(InpTag + "_m1.csv", FILE_WRITE | FILE_CSV |
                                  FILE_ANSI, ',');
   const int handlePoi = FileOpen(InpTag + "_poi.csv", FILE_WRITE | FILE_CSV |
                                  FILE_ANSI, ',');
   if(handleM1 == INVALID_HANDLE || handlePoi == INVALID_HANDLE)
     {
      PrintFormat("ALPHA %s export: cannot open files (error %d)", InpTag,
                  GetLastError());
      return INIT_FAILED;
     }

   FileWrite(handleM1, "time", "open", "high", "low", "close");
   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   const int copied = CopyRates(_Symbol, PERIOD_M1, 0, InpM1Bars, rates);
   const int closed = copied - 1;
   for(int i = 0; i < closed; ++i)
     {
      FileWrite(handleM1, IntegerToString((int)rates[i].time),
                DoubleToString(rates[i].open, 2),
                DoubleToString(rates[i].high, 2),
                DoubleToString(rates[i].low, 2),
                DoubleToString(rates[i].close, 2));
     }
   FileClose(handleM1);

   FileWrite(handlePoi, "tf", "time", "open", "high", "low", "close");
   const ENUM_TIMEFRAMES timeframes[3] = {PERIOD_M15, PERIOD_M30, PERIOD_H1};
   for(int t = 0; t < 3; ++t)
     {
      MqlRates poiRates[];
      ArraySetAsSeries(poiRates, false);
      const int poiCopied = CopyRates(_Symbol, timeframes[t], 0, InpPoiBars,
                                      poiRates);
      const int poiClosed = poiCopied - 1;
      for(int i = 0; i < poiClosed; ++i)
        {
         FileWrite(handlePoi, EnumToString(timeframes[t]),
                   IntegerToString((int)poiRates[i].time),
                   DoubleToString(poiRates[i].open, 2),
                   DoubleToString(poiRates[i].high, 2),
                   DoubleToString(poiRates[i].low, 2),
                   DoubleToString(poiRates[i].close, 2));
        }
     }
   FileClose(handlePoi);

   PrintFormat("ALPHA %s export done: m1=%d poi_bars written to MQL5/Files/%s_m1.csv and %s_poi.csv",
               InpTag, closed, InpTag, InpTag);
   return INIT_SUCCEEDED;
  }

void OnTick()
  {
   // Diagnostic only: no trading, no state.
  }
//+------------------------------------------------------------------+
