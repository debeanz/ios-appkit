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
@end

// NSAlert.m: the view controller to present UIKit modals from, and a nested run loop that
// returns once `finished` reports YES (AppKit's -runModal works the same way).
UIViewController *AKTopViewController(void);
void AKRunModalUntil(BOOL (^finished)(void));

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

// KeyCodes.m
unsigned short AKMacKeyCodeForHIDUsage(long usage);       // 0xFF when unknown
unsigned short AKMacKeyCodeForCharacter(unichar c);        // 0xFF when unknown
NSString *AKCharactersForMacKeyCode(unsigned short code);  // AppKit's characters for non-text keys, or nil
NSEventModifierFlags AKModifierFlagForHIDUsage(long usage); // 0 unless a modifier key
SEL AKCommandSelectorForKeyEvent(NSEvent *event);          // NULL when the key types text
