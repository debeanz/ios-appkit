# Builds libAppKitShim.a for iOS (device, arm64) or the arm64 Simulator.
# Needs a Mac with Xcode. On the simulator the shim can be exercised without a device.
#
#   make                # device: arm64, iphoneos SDK
#   make SDK=sim        # simulator: arm64, iphonesimulator SDK
#   make test SDK=sim   # build + link the smoke test for the simulator

SDK ?= device
ifeq ($(SDK),sim)
  SYSROOT := $(shell xcrun --sdk iphonesimulator --show-sdk-path)
  TARGET  := arm64-apple-ios15.0-simulator
else
  SYSROOT := $(shell xcrun --sdk iphoneos --show-sdk-path)
  TARGET  := arm64-apple-ios15.0
endif

CC      := $(shell xcrun --find clang)
AR      := $(shell xcrun --find ar)
BUILD   := build/$(SDK)
CFLAGS  := -isysroot $(SYSROOT) -target $(TARGET) -Iinclude -fobjc-arc -Wall -Wno-unused-parameter -O2 -fmodules
SRCS    := $(wildcard src/*.m)
OBJS    := $(patsubst src/%.m,$(BUILD)/%.o,$(SRCS))
LIB     := $(BUILD)/libAppKitShim.a

all: $(LIB)

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/%.o: src/%.m | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(LIB): $(OBJS)
	$(AR) rcs $@ $(OBJS)
	@echo "built $@"

# Smoke test: links against the shim and the real UIKit/Foundation. Proves the
# headers and library compile and link into an iOS binary.
test: $(LIB)
	$(CC) $(CFLAGS) tests/smoke.m -Lbuild/$(SDK) -lAppKitShim \
	  -framework UIKit -framework Foundation -framework CoreGraphics \
	  -framework AudioToolbox -o $(BUILD)/smoke
	@echo "linked $(BUILD)/smoke"

coverage:
	node tools/gen-coverage.js ../steam-mac/report src/implemented.json COVERAGE.md coverage.json

clean:
	rm -rf build

.PHONY: all test coverage clean
