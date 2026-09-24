# Linux build of WinUAE's cputestgen.  Normally driven by build.sh, which
# copies the WinUAE sources into $(SRC) first.
HERE   := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SRC    ?= $(HERE)/build/src
BUILD  ?= $(HERE)/build
OBJ    := $(BUILD)/obj

CXX      ?= g++
OPT      ?= -O2
CPPFLAGS := -I$(HERE)/shim -I$(SRC)/include -I$(SRC)
CXXFLAGS := $(OPT) -g -std=gnu++17 -fpermissive -fno-strict-aliasing -fwrapv -w
TESTDEFS := -DCPUEMU_90 -DCPUEMU_91 -DCPUEMU_92 -DCPUEMU_93 -DCPUEMU_94 -DCPUEMU_95 -DCPU_TESTER

GEN_OUT  := $(SRC)/cpuemu_90_test.cpp $(SRC)/cpuemu_91_test.cpp $(SRC)/cpuemu_92_test.cpp \
            $(SRC)/cpuemu_93_test.cpp $(SRC)/cpuemu_94_test.cpp $(SRC)/cpuemu_95_test.cpp \
            $(SRC)/cpustbl_test.cpp $(SRC)/cputbl_test.h

TESTER_SRCS := cpudefs.cpp cpuemu_90_test.cpp cpuemu_91_test.cpp cpuemu_92_test.cpp \
               cpuemu_93_test.cpp cpuemu_94_test.cpp cpuemu_95_test.cpp cpustbl_test.cpp \
               cputest.cpp cputest_support.cpp disasm.cpp fpp.cpp fpp_softfloat.cpp ini.cpp \
               newcpu_common.cpp readcpu.cpp softfloat/softfloat.cpp \
               softfloat/softfloat_decimal.cpp softfloat/softfloat_fpsp.cpp
TESTER_OBJS := $(addprefix $(OBJ)/t/,$(TESTER_SRCS:.cpp=.o)) $(OBJ)/t/linux_support.o

all: $(HERE)/cputestgen

# --- stage 1: build68k -> cpudefs.cpp ---------------------------------------
$(BUILD)/build68k: $(SRC)/build68k.cpp $(HERE)/linux_support.cpp
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -o $@ $^

$(SRC)/cpudefs.cpp: $(BUILD)/build68k $(SRC)/table68k
	$(BUILD)/build68k < $(SRC)/table68k > $@.tmp && mv $@.tmp $@

# --- stage 2: gencpu -> test cores ------------------------------------------
$(BUILD)/gencpu: $(SRC)/gencpu.cpp $(SRC)/readcpu.cpp $(SRC)/cpudefs.cpp $(SRC)/missing.cpp $(HERE)/linux_support.cpp
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -o $@ $^

$(BUILD)/gencpu.stamp: $(BUILD)/gencpu
	cd $(SRC) && $(BUILD)/gencpu > $(BUILD)/gencpu.log
	touch $@

$(GEN_OUT): $(BUILD)/gencpu.stamp

# --- stage 3: cputestgen ----------------------------------------------------
$(OBJ)/t/%.o: $(SRC)/%.cpp $(BUILD)/gencpu.stamp
	@mkdir -p $(dir $@)
	$(CXX) $(CPPFLAGS) $(TESTDEFS) $(CXXFLAGS) -c -o $@ $<

$(OBJ)/t/linux_support.o: $(HERE)/linux_support.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CPPFLAGS) $(TESTDEFS) $(CXXFLAGS) -c -o $@ $<

$(HERE)/cputestgen: $(TESTER_OBJS)
	$(CXX) -o $@ $^ -lz -lm

clean:
	rm -rf $(BUILD) $(HERE)/cputestgen

.PHONY: all clean
