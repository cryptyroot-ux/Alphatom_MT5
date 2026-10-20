CXX ?= g++
CXXFLAGS ?= -std=c++17 -Wall -Wextra -Werror -pedantic
BUILD_DIR := build
KERNEL_TEST := $(BUILD_DIR)/msnr_kernel_tests

.PHONY: test test-kernel test-python clean

test: test-kernel test-python

test-kernel: $(KERNEL_TEST)
	./$(KERNEL_TEST)

$(KERNEL_TEST): tests/msnr_kernel_tests.cpp MQL5/Include/Alphatom/MSNRKernel.mqh
	mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -o $@ tests/msnr_kernel_tests.cpp

test-python:
	@if find tests -maxdepth 1 -type f -name 'test_*.py' -print -quit | grep -q .; then \
		python3 -m unittest discover -s tests -p 'test_*.py' -v; \
	else \
		echo 'No Python contract tests added yet'; \
	fi

clean:
	rm -rf $(BUILD_DIR)
