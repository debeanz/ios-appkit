// Hooks the shim's classes use to talk to each other. Not part of the public API.
#import "AppKitShim/AppKit.h"
#import <UIKit/UIKit.h>

// The UIView behind every NSView. Drawing lives in NSView.m; touch, keyboard and
// pointer input are added by a category in InputBridge.m.
@interface _AKShimBackingView : UIView
@property (nonatomic, weak) NSView *owner;
@end

@interface _AKShimBackingView (AKShimInput) <UIKeyInput>
- (void)_ak_installInputSupport;
@end

@interface NSColor (AKShimPrivate)
- (instancetype)initWithUIColor:(UIColor *)color;
@end

@interface NSView (AKShimPrivate)
- (void)_setOwningWindow:(NSWindow *)window;
- (void)_ak_backingDidLayout;
- (void)_ak_deliverEvent:(NSEvent *)event; // send via NSApp on the thread that owns this view
@end

// NSAlert.m: the view controller to present UIKit modals from, and a nested run loop that
// returns once `finished` reports YES (AppKit's -runModal works the same way).
UIViewController *AKTopViewController(void);
void AKRunModalUntil(BOOL (^finished)(void));

// CGEvents.m: records every event NSApp delivers (per-type times and counts, keys and
// buttons held, last mouse movement) for the CGEventSource state queries.
void AKNoteInputEvent(NSEvent *event);
uint32_t AKMouseButtonsDown(void);  // bit n set while mouse button n is held

// paramErr lives in the Mac-only MacErrors.h; the Carbon shims return the same value.
enum { AKParamErr = -50 };

// Carbon.m: fires a registered hotkey for this key event; YES if one matched (and so the
// key should not also go to the app, as on the Mac).
BOOL AKCarbonDispatchHotKey(unsigned short keyCode, NSEventModifierFlags flags, BOOL down);

// KeyLayout.m: the US layout in 'uchr' format (kTISPropertyUnicodeKeyLayoutData).
NSData *AKUSKeyboardLayoutData(void);

// CGDisplay.m: display IDs are 1-based positions in UIScreen's list.
CGDirectDisplayID AKDisplayIDForScreen(UIScreen *screen);
UIScreen *AKScreenForDisplayID(CGDirectDisplayID display);

@interface NSApplication (AKShimPrivate)
- (void)_registerWindow:(NSWindow *)window;
- (void)_unregisterWindow:(NSWindow *)window;
@end

@interface NSEvent (AKShimPrivate)
// The view the input bridge hit-tested for a mouse event; nil for synthetic events.
@property (nonatomic, readonly, weak) NSView *_targetView;
- (void)_setWindow:(NSWindow *)window targetView:(NSView *)view;
- (void)_setDeltaX:(CGFloat)dx deltaY:(CGFloat)dy;
+ (void)_setMouseLocation:(NSPoint)location;
+ (void)_setModifierFlags:(NSEventModifierFlags)flags;
@end

// AKForwarding.m: a shim class that is missing a method logs it (once per class+selector,
// to stderr -> steam-console.log) and returns zero instead of raising "unrecognized
// selector". This keeps the client running so one launch surfaces every method the shim
// still needs, the way a real AppKit object would already respond. A class opts in by
// putting AK_UNIMPLEMENTED_FORWARDER in its @implementation. respondsToSelector: is
// unaffected (it checks the real method list), so feature detection still sees the truth.
void AKLogUnimplemented(id obj, SEL sel);
NSMethodSignature *AKGenericSignatureForSelector(SEL sel);

#define AK_UNIMPLEMENTED_FORWARDER \
  - (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector { \
    NSMethodSignature *sig = [super methodSignatureForSelector:aSelector]; \
    return sig ?: AKGenericSignatureForSelector(aSelector); \
  } \
  - (void)forwardInvocation:(NSInvocation *)anInvocation { \
    AKLogUnimplemented(self, anInvocation.selector); \
    NSUInteger len = anInvocation.methodSignature.methodReturnLength; \
    if (len) { void *zero = calloc(1, len); [anInvocation setReturnValue:zero]; free(zero); } \
  }

// The same for class methods (+[NSEvent ...], +[NSMenu ...]).
#define AK_UNIMPLEMENTED_CLASS_FORWARDER \
  + (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector { \
    NSMethodSignature *sig = [super methodSignatureForSelector:aSelector]; \
    return sig ?: AKGenericSignatureForSelector(aSelector); \
  } \
  + (void)forwardInvocation:(NSInvocation *)anInvocation { \
    AKLogUnimplemented(self, anInvocation.selector); \
    NSUInteger len = anInvocation.methodSignature.methodReturnLength; \
    if (len) { void *zero = calloc(1, len); [anInvocation setReturnValue:zero]; free(zero); } \
  }

// NSApplication.m: run a UIKit step on the main thread and wait for it. AppKit code runs off
// the main thread here (the in-process web helper's Chromium UI thread), and UIKit throws
// when a view in the live hierarchy is changed from another thread. Only the UIKit step
// moves; the client's own callbacks stay on the thread that made the call.
void AKOnMainSync(dispatch_block_t block);

// NSEvent.m: local event monitors (+addLocalMonitorForEventsMatchingMask:handler:). NSApp's
// -sendEvent: passes each event through them first; a handler returning nil swallows it.
NSEvent *AKRunLocalEventMonitors(NSEvent *event);

// KeyCodes.m
unsigned short AKMacKeyCodeForHIDUsage(long usage);       // 0xFF when unknown
unsigned short AKMacKeyCodeForCharacter(unichar c);        // 0xFF when unknown
NSString *AKCharactersForMacKeyCode(unsigned short code);  // AppKit's characters for non-text keys, or nil
NSEventModifierFlags AKModifierFlagForHIDUsage(long usage); // 0 unless a modifier key
SEL AKCommandSelectorForKeyEvent(NSEvent *event);          // NULL when the key types text
