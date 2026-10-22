//+------------------------------------------------------------------+
//| Compile-only harness for the shared execution kernel.           |
//| No orders, no indicators: it only forces MetaEditor to type-check |
//| every kernel function under the MQL5 compiler.                    |
//+------------------------------------------------------------------+
#property strict
#include <Alphatom/ExecKernel.mqh>

int OnInit()
  {
   ExecConfig cfg;
   cfg.tickSize = 0.01;
   cfg.slBufferTicks = 2;
   cfg.slCapDistance = 5.0;
   cfg.cisdMinRun = 2;
   cfg.cisdMinWidth = 0.20;
   cfg.cisdMaxWidth = 2.0;
   cfg.minZoneWidthTicks = 2;
   cfg.lotsPerLayer = 0.15;
   cfg.moneyPerPipPerLot = 10.0;
   cfg.riskCap = 0.0;
   cfg.tpPips[0] = 30;
   cfg.tpPips[1] = 50;
   cfg.tpPips[2] = 100;
   cfg.slPlusPips = 10;

   ExecSetup setup;
   ExecEvent ev;
   Exec_ClearSetup(setup);
   Exec_ClearEvent(ev);
   Exec_InitSetup(setup, true, MSNR_ROLE_SUPPORT, 4119.0, 4120.0, 15);

   MSNRBar bars[1];
   bars[0].open = 4121.0;
   bars[0].high = 4122.0;
   bars[0].low = 4119.5;
   bars[0].close = 4121.0;
   bars[0].time = 1;
   Exec_Advance(bars, 1, MSNR_STATE_FRESH, MSNR_ROLE_SUPPORT, cfg, setup, ev);
   Exec_RecordFill(setup, 0, 4120.0, cfg, ev);
   Exec_RecordClose(setup, 0, true, ev);
   Exec_IsActive(setup);
   Exec_CountPending(setup);
   Exec_CountFilled(setup);
   return INIT_SUCCEEDED;
  }

void OnTick()
  {
  }
