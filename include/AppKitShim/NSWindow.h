// NSWindow — on the Mac this owns an OS window; on iOS there is only one UIWindow and
// everything lives in it. So an NSWindow here is a full-screen container view inside the
// shared UIWindow, and `contentView` is what the client draws into. Multiple NSWindows
// stack as sibling container views, z-ordered by orderFront/orderOut.
#import "NSResponder.h"
#import "NSGeometry.h"

@class NSView, NSScreen, NSEvent;

typedef NS_OPTIONS(NSUInteger, NSWindowStyleMask) {
  NSWindowStyleMaskBorderless     = 0,
  NSWindowStyleMaskTitled         = 1 << 0,
  NSWindowStyleMaskClosable       = 1 << 1,
  NSWindowStyleMaskMiniaturizable = 1 << 2,
  NSWindowStyleMaskResizable      = 1 << 3,
  NSWindowStyleMaskFullScreen     = 1 << 14,
};

typedef NS_ENUM(NSInteger, NSBackingStoreType) { NSBackingStoreBuffered = 2 };

extern NSNotificationName const NSWindowDidBecomeKeyNotification;
extern NSNotificationName const NSWindowDidResignKeyNotification;
extern NSNotificationName const NSWindowDidChangeBackingPropertiesNotification;
extern NSNotificationName const NSWindowDidChangeScreenNotification;
extern NSNotificationName const NSWindowDidChangeScreenProfileNotification;
extern NSNotificationName const NSWindowWillEnterFullScreenNotification;
extern NSNotificationName const NSWindowDidEnterFullScreenNotification;
extern NSNotificationName const NSWindowWillExitFullScreenNotification;
extern NSNotificationName const NSWindowDidExitFullScreenNotification;
extern NSString *const NSBackingPropertyOldScaleFactorKey;

@interface NSWindow : NSResponder
- (instancetype)initWithContentRect:(NSRect)rect
                          styleMask:(NSWindowStyleMask)style
                            backing:(NSBackingStoreType)backing
                              defer:(BOOL)defer;
- (instancetype)initWithContentRect:(NSRect)rect
                          styleMask:(NSWindowStyleMask)style
                            backing:(NSBackingStoreType)backing
                              defer:(BOOL)defer
                             screen:(NSScreen *)screen;

@property (nonatomic, strong) NSView *contentView;
@property (nonatomic, weak) id delegate;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) NSRect frame;
@property (nonatomic, readonly) NSInteger windowNumber;
@property (nonatomic, readonly, getter=isVisible) BOOL visible;
@property (nonatomic, readonly, getter=isKeyWindow) BOOL keyWindow;
@property (nonatomic, readonly) NSScreen *screen;
@property (nonatomic, assign) CGFloat alphaValue;
@property (nonatomic, assign) BOOL acceptsMouseMovedEvents;

// Points to pixels for this window's screen (2 or 3 on iPhone).
@property (nonatomic, readonly) CGFloat backingScaleFactor;

// Every window on iOS is full screen, so the style mask always includes
// NSWindowStyleMaskFullScreen and -toggleFullScreen: has nothing to toggle.
@property (nonatomic, assign) NSWindowStyleMask styleMask;
- (void)toggleFullScreen:(id)sender;

// Per-window keyboard focus, as in AppKit. Key events go here; mouse events go to the
// view under the pointer.
@property (nonatomic, readonly, weak) NSResponder *firstResponder;
- (BOOL)makeFirstResponder:(NSResponder *)responder;

- (void)makeKeyAndOrderFront:(id)sender;
- (void)makeKeyWindow;
- (void)orderFront:(id)sender;
- (void)orderOut:(id)sender;
- (void)close;
- (void)sendEvent:(NSEvent *)event;
- (NSPoint)mouseLocationOutsideOfEventStream;
- (NSRect)contentRectForFrameRect:(NSRect)frameRect;
- (NSRect)frameRectForContentRect:(NSRect)contentRect;
@end
