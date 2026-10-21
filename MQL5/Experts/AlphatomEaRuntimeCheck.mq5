//+------------------------------------------------------------------+
//| AlphatomEaRuntimeCheck.mq5                                       |
//| Diagnostic probe for the HFM CENT runtime: account, symbol,      |
//| timeframe availability, filling modes and money-per-pip.         |
//| Read-only: this expert never sends an order.                     |
//+------------------------------------------------------------------+
#property copyright "Alphatom"
#property version   "1.00"
#property description "Alphatom runtime probe (read-only, no trading)"

input string InpReportFile  = "Alphatom_runtime_report.csv";
input string InpInstanceTag = "RC";

//+------------------------------------------------------------------+
//| Money per pip for one lot, from the live contract specification  |
//| (pip = 0.10 price, same constant as ExecKernel's EXEC_PIP_SIZE). |
//+------------------------------------------------------------------+
double ProbeMoneyPerPipPerLot()
  {
   const double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return 0.0;
   return tickValue * (0.10 / tickSize);
  }

void ProbeRow(const int handle, const string key, const string value)
  {
   FileWrite(handle, key, value);
  }

int OnInit()
  {
   const int handle = FileOpen(InpReportFile,
                               FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(handle == INVALID_HANDLE)
     {
      PrintFormat("ALPHA %s runtime check: cannot open %s (error %d)",
                  InpInstanceTag, InpReportFile, GetLastError());
      return INIT_FAILED;
     }

   FileWrite(handle, "key", "value");
   // The open positions of the account, so a lost or foreign position can be
   // identified by its magic number and comment.
   for(int i = 0; i < PositionsTotal(); ++i)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      ProbeRow(handle, StringFormat("position_%I64d_symbol", ticket),
               PositionGetString(POSITION_SYMBOL));
      ProbeRow(handle, StringFormat("position_%I64d_magic", ticket),
               IntegerToString((int)PositionGetInteger(POSITION_MAGIC)));
      ProbeRow(handle, StringFormat("position_%I64d_comment", ticket),
               PositionGetString(POSITION_COMMENT));
      ProbeRow(handle, StringFormat("position_%I64d_type", ticket),
               IntegerToString((int)PositionGetInteger(POSITION_TYPE)));
      ProbeRow(handle, StringFormat("position_%I64d_volume", ticket),
               DoubleToString(PositionGetDouble(POSITION_VOLUME), 2));
      ProbeRow(handle, StringFormat("position_%I64d_price", ticket),
               DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), 2));
      ProbeRow(handle, StringFormat("position_%I64d_sl", ticket),
               DoubleToString(PositionGetDouble(POSITION_SL), 2));
      ProbeRow(handle, StringFormat("position_%I64d_tp", ticket),
               DoubleToString(PositionGetDouble(POSITION_TP), 2));
      ProbeRow(handle, StringFormat("position_%I64d_profit", ticket),
               DoubleToString(PositionGetDouble(POSITION_PROFIT), 2));
      ProbeRow(handle, StringFormat("position_%I64d_time", ticket),
               TimeToString((datetime)PositionGetInteger(POSITION_TIME),
                            TIME_DATE | TIME_MINUTES));
     }
   ProbeRow(handle, "time", TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
   ProbeRow(handle, "account_login",
            IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)));
   ProbeRow(handle, "account_server", AccountInfoString(ACCOUNT_SERVER));
   ProbeRow(handle, "account_currency", AccountInfoString(ACCOUNT_CURRENCY));
   ProbeRow(handle, "account_margin_mode",
            EnumToString((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)));
   ProbeRow(handle, "account_leverage",
            IntegerToString(AccountInfoInteger(ACCOUNT_LEVERAGE)));
   ProbeRow(handle, "account_balance",
            DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   ProbeRow(handle, "account_equity",
            DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   ProbeRow(handle, "terminal_trade_allowed",
            (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0 ? "true" : "false"));
   ProbeRow(handle, "mql_trade_allowed",
            (MQLInfoInteger(MQL_TRADE_ALLOWED) != 0 ? "true" : "false"));

   ProbeRow(handle, "symbol", _Symbol);
   ProbeRow(handle, "digits",
            IntegerToString(SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
   ProbeRow(handle, "point", DoubleToString(_Point, 5));
   ProbeRow(handle, "tick_size",
            DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), 5));
   ProbeRow(handle, "tick_value_loss",
            DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS), 4));
   ProbeRow(handle, "tick_value_profit",
            DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_PROFIT), 4));
   ProbeRow(handle, "tick_value",
            DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), 4));
   ProbeRow(handle, "contract_size",
            DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE), 2));
   ProbeRow(handle, "volume_min",
            DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), 2));
   ProbeRow(handle, "volume_step",
            DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP), 2));
   ProbeRow(handle, "stops_level_points",
            IntegerToString(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL)));
   ProbeRow(handle, "freeze_level_points",
            IntegerToString(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)));
   ProbeRow(handle, "spread_points",
            IntegerToString(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)));
   ProbeRow(handle, "filling_mask",
            IntegerToString(SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE)));
   ProbeRow(handle, "trade_mode",
            EnumToString((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE)));
   ProbeRow(handle, "money_per_pip_per_lot",
            DoubleToString(ProbeMoneyPerPipPerLot(), 4));

   const ENUM_TIMEFRAMES timeframes[6] =
     {PERIOD_M1, PERIOD_M2, PERIOD_M3, PERIOD_M15, PERIOD_M30, PERIOD_H1};
   for(int i = 0; i < 6; ++i)
     {
      const ENUM_TIMEFRAMES tf = timeframes[i];
      const string name = EnumToString(tf);
      const int bars = Bars(_Symbol, tf);
      const datetime newest = iTime(_Symbol, tf, 0);
      const datetime bar300 = (bars > 300 ? iTime(_Symbol, tf, 299) : 0);
      ProbeRow(handle, "series_" + name + "_bars", IntegerToString(bars));
      ProbeRow(handle, "series_" + name + "_newest",
               TimeToString(newest, TIME_DATE | TIME_MINUTES));
      ProbeRow(handle, "series_" + name + "_bar300",
               TimeToString(bar300, TIME_DATE | TIME_MINUTES));
     }

   FileClose(handle);
   PrintFormat("ALPHA %s runtime check written to MQL5/Files/%s",
               InpInstanceTag, InpReportFile);
   return INIT_SUCCEEDED;
  }

void OnTick()
  {
   // Diagnostic only: no trading, no state.
  }
//+------------------------------------------------------------------+
