CXX ?= g++
CXXFLAGS ?= -std=c++17 -Wall -Wextra -Werror -pedantic
BUILD_DIR := build
KERNEL_TEST := $(BUILD_DIR)/msnr_kernel_tests
EXEC_TEST := $(BUILD_DIR)/exec_kernel_tests
LEVEL_TEST := $(BUILD_DIR)/level_replay_tests
LIVE_REPLAY := $(BUILD_DIR)/live_replay
BACKTEST := $(BUILD_DIR)/backtest

.PHONY: test test-kernel test-exec test-levels test-python test-replay backtest clean

test: test-kernel test-exec test-levels test-python

test-kernel: $(KERNEL_TEST)
	./$(KERNEL_TEST)

test-exec: $(EXEC_TEST)
	./$(EXEC_TEST)

test-levels: $(LEVEL_TEST)
	./$(LEVEL_TEST)

$(LEVEL_TEST): tests/level_replay_tests.cpp MQL5/Include/Alphatom/MSNRLevels.mqh MQL5/Include/Alphatom/MSNRKernel.mqh tests/golden/hfm_bars_20261021.csv tests/golden/hfm_objects_20261021.csv
	mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -o $@ tests/level_replay_tests.cpp

$(KERNEL_TEST): tests/msnr_kernel_tests.cpp MQL5/Include/Alphatom/MSNRKernel.mqh
	mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -o $@ tests/msnr_kernel_tests.cpp

$(EXEC_TEST): tests/exec_kernel_tests.cpp MQL5/Include/Alphatom/ExecKernel.mqh MQL5/Include/Alphatom/MSNRKernel.mqh
	mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -o $@ tests/exec_kernel_tests.cpp

# Offline replay of the live expert loop on exported HFM bars. The dataset is
# the live export of 2026-10-21 (4000 M1 bars + 1500 bars per POI timeframe);
# re-export it with MQL5/Experts/AlphatomBarsExport.mq5.
test-replay: $(LIVE_REPLAY)
	./$(LIVE_REPLAY) tests/data/live_replay_m1_20261021.csv tests/data/live_replay_poi_20261021.csv

# Long backtest over the recorded bars (needs data/BEX_m1.csv, data/BEX_poi.csv).
backtest: $(BACKTEST)
	./$(BACKTEST) --m1 data/BEX_m1.csv --poi data/BEX_poi.csv --report data/backtest_trades.csv

$(BACKTEST): tests/backtest.cpp MQL5/Include/Alphatom/ExecKernel.mqh MQL5/Include/Alphatom/MSNRLevels.mqh MQL5/Include/Alphatom/MSNRKernel.mqh
	mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -o $@ tests/backtest.cpp

$(LIVE_REPLAY): tests/live_replay.cpp MQL5/Include/Alphatom/ExecKernel.mqh MQL5/Include/Alphatom/MSNRLevels.mqh MQL5/Include/Alphatom/MSNRKernel.mqh
	mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -o $@ tests/live_replay.cpp

test-python:
	@if find tests -maxdepth 1 -type f -name 'test_*.py' -print -quit | grep -q .; then \
		python3 -m unittest discover -s tests -p 'test_*.py' -v; \
	else \
		echo 'No Python contract tests added yet'; \
	fi

clean:
	rm -rf $(BUILD_DIR)
