// Smoke test: construct the core objects through the shim's public headers and link
// against libAppKitShim + real UIKit. If this compiles and links, the API surface is
// coherent and the library is usable from AppKit-style code. It does not run a UI;
// that needs a hosted simulator target (see README).
#import "AppKitShim/AppKit.h"

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSApplication *app = NSApplication.sharedApplication;
    NSCAssert(app == NSApp, @"NSApp should be the shared application");

    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 720)
                                                styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1280, 720)];
    win.contentView = content;

    NSView *child = [[NSView alloc] initWithFrame:NSMakeRect(10, 10, 100, 100)];
    [content addSubview:child];
    NSCAssert(content.subviews.count == 1, @"subview not registered");
    NSCAssert(child.window == win, @"window chain broken");

    NSEvent *e = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                    location:NSMakePoint(5, 5)
                               modifierFlags:0 timestamp:0 windowNumber:0
                                     context:nil subtype:0 data1:0 data2:0];
    [app postEvent:e atStart:NO];
    NSEvent *got = [app nextEventMatchingMask:NSAnyEventMask untilDate:nil inMode:@"" dequeue:YES];
    NSCAssert(got == e, @"event queue round-trip failed");

    NSColor *c = [NSColor colorWithRed:1 green:0 blue:0 alpha:1];
    NSCAssert(c.CGColor != NULL, @"color has no CGColor");

    (void)NSScreen.mainScreen.backingScaleFactor;
    NSBeep();

    fprintf(stderr, "smoke: ok (NSAppKitVersionNumber=%.1f)\n", NSAppKitVersionNumber);
    return 0;
  }
}
