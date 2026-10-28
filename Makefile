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
  -framework VideoToolbox -framework UniformTypeIdentifiers -framework WebKit
# Name of the framework 'make framework' builds. The IPA build names the code
# AppKitShimCore and puts the AppKitShim umbrella (below) in front of it.
SHIM_NAME ?= AppKitShim
FRAMEWORK := $(BUILD)/$(SHIM_NAME).framework

# iOS libraries the umbrella re-exports, as .tbd paths relative to the SDK (lib-routes.js
# writes them to routes.json as reexportTbds). Steam's load commands for a library that is
# missing macOS-only symbols are pointed at the umbrella; re-exporting the real iOS library
# keeps every other symbol reachable through it, the way Cocoa re-exports AppKit on a Mac.
REEXPORT_TBDS ?=
REEXPORT_FLAGS := $(foreach t,$(REEXPORT_TBDS),-Wl,-reexport_library,$(SYSROOT)/$(t))
CORE_NAME := AppKitShimCore
UMBRELLA := $(BUILD)/AppKitShim.framework

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
	  -framework AudioToolbox -framework QuartzCore -framework CoreVideo -framework Metal -framework ImageIO -framework WebKit \
	  -framework GameController \
	  -o $(BUILD)/smoke
	@echo "linked $(BUILD)/smoke"

# The dynamic shim the retagged Steam binaries load in place of macOS AppKit/Carbon/etc.
# Install name is @rpath/... so dyld finds it via the LC_RPATH the packager adds to each
# binary. Exports every global the objects define, including the macOS symbol names the
# src tags with asm labels; that export set is exactly what package-ipa.sh repoints to.
# The shim's font class runs as AKShimFont (iOS has an unrelated internal class named NSFont)
# but is exported under the NSFont class symbols, so a client linking AppKit's NSFont gets it.
# NSColor likewise runs as AKShim_NSColor (AK_SHIM_RUNTIME_NAME; UIKitCore has a private
# NSColor) and is exported as NSColor too — otherwise CEF's [NSColor colorWithCatalogName:...]
# went to UIKit's class and threw.
# Single quotes keep the $ in the Objective-C symbol names away from the shell.
CLASS_ALIASES := '-Wl,-alias,_OBJC_CLASS_$$_AKShimFont,_OBJC_CLASS_$$_NSFont' \
  '-Wl,-alias,_OBJC_METACLASS_$$_AKShimFont,_OBJC_METACLASS_$$_NSFont' \
  '-Wl,-alias,_OBJC_CLASS_$$_AKShim_NSColor,_OBJC_CLASS_$$_NSColor' \
  '-Wl,-alias,_OBJC_METACLASS_$$_AKShim_NSColor,_OBJC_METACLASS_$$_NSColor'

framework: $(OBJS)
	mkdir -p $(FRAMEWORK)
	$(CC) $(CFLAGS) -dynamiclib -install_name @rpath/$(SHIM_NAME).framework/$(SHIM_NAME) \
	  -compatibility_version 1.0 -current_version 1.0 \
	  $(OBJS) $(SHIM_FRAMEWORKS) $(CLASS_ALIASES) -undefined dynamic_lookup \
	  -o $(FRAMEWORK)/$(SHIM_NAME)
	sed 's/AppKitShim/$(SHIM_NAME)/g' framework/Info.plist > $(FRAMEWORK)/Info.plist
	@echo "built $(FRAMEWORK)/$(SHIM_NAME)"

# The IPA's routing target: AppKitShim.framework with no code of its own, only re-exports —
# the shim's code (built as AppKitShimCore) plus the real iOS libraries in REEXPORT_TBDS.
# It is kept apart from the code because a library the linker also links plainly (the
# code's -framework list, autolinked modules, the driver's implicit -lSystem) ends up a
# plain dependency instead of a re-export; -nostdlib on an empty source leaves nothing but
# the re-exports. @loader_path/.. is the app's Frameworks dir, where AppKitShimCore sits.
umbrella:
	$(MAKE) framework SHIM_NAME=$(CORE_NAME)
	mkdir -p $(UMBRELLA)
	$(CC) -isysroot $(SYSROOT) -target $(TARGET) -dynamiclib -nostdlib \
	  -install_name @rpath/AppKitShim.framework/AppKitShim \
	  -compatibility_version 1.0 -current_version 1.0 -Wl,-rpath,@loader_path/.. \
	  -x c /dev/null \
	  -Wl,-reexport_library,$(BUILD)/$(CORE_NAME).framework/$(CORE_NAME) $(REEXPORT_FLAGS) \
	  -o $(UMBRELLA)/AppKitShim
	cp framework/Info.plist $(UMBRELLA)/Info.plist
	@echo "built $(UMBRELLA)/AppKitShim (re-exports $(CORE_NAME) + $(words $(REEXPORT_TBDS)) iOS libraries)"

coverage:
	node tools/gen-coverage.js data/ios-gap.json src/implemented.json COVERAGE.md coverage.json

clean:
	rm -rf build

.PHONY: all test framework umbrella coverage clean
