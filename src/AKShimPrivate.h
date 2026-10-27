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

@interface NSView (AKShimPrivate)
- (void)_setOwningWindow:(NSWindow *)window;
@end

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
