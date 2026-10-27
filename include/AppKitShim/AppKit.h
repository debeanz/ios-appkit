// AppKit.h — umbrella header. The Steam client's sources do `#import <AppKit/AppKit.h>`;
// building against this shim's include path makes that resolve here instead.
#ifndef APPKITSHIM_APPKIT_H
#define APPKITSHIM_APPKIT_H

#import "NSGeometry.h"
#import "CoreGraphicsMac.h"
#import "CoreVideoMac.h"
#import "CarbonMac.h"
#import "CoreServicesMac.h"
#import "NSResponder.h"
#import "NSView.h"
#import "NSWindow.h"
#import "NSApplication.h"
#import "NSEvent.h"
#import "NSScreen.h"
#import "NSColor.h"
#import "NSTextInputContext.h"
#import "NSTrackingArea.h"
#import "NSPasteboard.h"
#import "NSCursor.h"
#import "NSMenu.h"
#import "NSWorkspace.h"
#import "NSRunningApplication.h"
#import "AppKitConstants.h"
#import "AppKitFunctions.h"
#import "AKShimInput.h"

// Convenience alias used across AppKit code.
#ifndef NSAppKitVersionNumber
extern double NSAppKitVersionNumber;
#endif

void NSBeep(void);

#endif
