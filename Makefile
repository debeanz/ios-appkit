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

# Frameworks the shim's own code calls into on iOS. A dynamiclib of ALL objects
# references more than the smoke test pulls from the static lib, so link a superset;
# -undefined dynamic_lookup defers any straggler (and the macOS-only names the shim
# exports) to flat runtime lookup inside the Steam process, which has them all loaded.
SHIM_FRAMEWORKS := -framework UIKit -framework Foundation -framework CoreFoundation \
  -framework CoreGraphics -framework CoreText -framework QuartzCore -framework CoreVideo \
  -framework Metal -framework MetalKit -framework AudioToolbox -framework AVFoundation \
  -framework ImageIO -framework Security -framework LocalAuthentication \
  -framework AuthenticationServices -framework SafariServices -framework GameController \
  -framework SystemConfiguration -framework Network -framework Accelerate \
  -framework VideoToolbox -framework UniformTypeIdentifiers
FRAMEWORK := $(BUILD)/AppKitShim.framework

# iOS libraries the shim re-exports, as .tbd paths relative to the SDK (lib-routes.js
# writes them to routes.json as reexportTbds). Steam's load commands for a library that is
# missing macOS-only symbols are pointed at the shim; re-exporting the real iOS library
# keeps every other symbol reachable through it, the way Cocoa re-exports AppKit on a Mac.
# Empty (the per-push build) gives the plain shim.
REEXPORT_TBDS ?=
REEXPORT_FLAGS := $(foreach t,$(REEXPORT_TBDS),-Wl,-reexport_library,$(SYSROOT)/$(t))

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
	  -framework AudioToolbox -framework QuartzCore -framework CoreVideo -framework Metal -framework ImageIO \
	  -o $(BUILD)/smoke
	@echo "linked $(BUILD)/smoke"

# The dynamic shim the retagged Steam binaries load in place of macOS AppKit/Carbon/etc.
# Install name is @rpath/... so dyld finds it via the LC_RPATH the packager adds to each
# binary. Exports every global the objects define, including the macOS symbol names the
# src tags with asm labels; that export set is exactly what package-ipa.sh repoints to.
framework: $(OBJS)
	mkdir -p $(FRAMEWORK)
	$(CC) $(CFLAGS) -dynamiclib -install_name @rpath/AppKitShim.framework/AppKitShim \
	  -compatibility_version 1.0 -current_version 1.0 \
	  $(OBJS) $(SHIM_FRAMEWORKS) $(REEXPORT_FLAGS) -undefined dynamic_lookup \
	  -o $(FRAMEWORK)/AppKitShim
	cp framework/Info.plist $(FRAMEWORK)/Info.plist
	@echo "built $(FRAMEWORK)/AppKitShim"

coverage:
	node tools/gen-coverage.js data/ios-gap.json src/implemented.json COVERAGE.md coverage.json

clean:
	rm -rf build

.PHONY: all test framework coverage clean
