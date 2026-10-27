#import "AppKitShim/NSWindow.h"
#import "AppKitShim/NSView.h"
#import "AppKitShim/NSScreen.h"
#import "AppKitShim/NSApplication.h"
#import "AppKitShim/NSEvent.h"
#import <UIKit/UIKit.h>

// Private hook in NSView.m that tells a content view which window owns it.
@interface NSView (AKShimWindowOwner)
- (void)_setOwningWindow:(NSWindow *)window;
@end

// The single UIWindow every NSWindow mounts its content into. Created lazily so the
// shim works whether the host app sets up its own scene or lets us make one.
static UIWindow *AKSharedUIWindow(void) {
  static UIWindow *w;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
      if ([scene isKindOfClass:UIWindowScene.class]) {
        UIWindowScene *ws = (UIWindowScene *)scene;
        w = ws.windows.firstObject ?: [[UIWindow alloc] initWithWindowScene:ws];
        break;
      }
    }
    if (!w) w = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    if (!w.rootViewController) w.rootViewController = [UIViewController new];
    [w makeKeyAndVisible];
  });
  return w;
}

@interface NSWindow ()
@property (nonatomic, assign, getter=isVisible, readwrite) BOOL visible;
@property (nonatomic, assign, getter=isKeyWindow, readwrite) BOOL keyWindow;
@end

@implementation NSWindow {
  NSRect _frame;
}

- (instancetype)initWithContentRect:(NSRect)rect
                          styleMask:(NSWindowStyleMask)style
                            backing:(NSBackingStoreType)backing
                              defer:(BOOL)defer {
  if ((self = [super init])) {
    _frame = rect;
    _alphaValue = 1.0;
    _contentView = [[NSView alloc] initWithFrame:(NSRect){{0, 0}, rect.size}];
    [_contentView _setOwningWindow:self];
  }
  return self;
}

- (void)setContentView:(NSView *)contentView {
  [_contentView removeFromSuperview];
  [_contentView _setOwningWindow:nil];
  _contentView = contentView;
  [contentView _setOwningWindow:self];
  contentView.frame = (NSRect){{0, 0}, _frame.size};
}

- (NSRect)frame { return _frame; }
- (void)setFrame:(NSRect)frame {
  _frame = frame;
  _contentView.backingView.frame = (NSRect){{0, 0}, frame.size};
}

- (NSScreen *)screen { return NSScreen.mainScreen; }

- (void)makeKeyAndOrderFront:(id)sender {
  [self orderFront:sender];
  self.keyWindow = YES;
  [NSApp makeFirstResponder:_contentView];
}

- (void)orderFront:(id)sender {
  UIView *host = AKSharedUIWindow().rootViewController.view;
  UIView *bv = _contentView.backingView;
  // iOS has no menu bar; a window fills the host. Full screen is the norm for Big Picture.
  bv.frame = host.bounds;
  bv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  bv.alpha = _alphaValue;
  [host addSubview:bv];        // last added is frontmost, i.e. ordered front
  self.visible = YES;
}

- (void)orderOut:(id)sender {
  [_contentView.backingView removeFromSuperview];
  self.visible = NO;
  self.keyWindow = NO;
}

- (void)close { [self orderOut:nil]; }

- (void)makeFirstResponder:(NSResponder *)responder { [NSApp makeFirstResponder:responder]; }

- (void)setAlphaValue:(CGFloat)a { _alphaValue = a; _contentView.backingView.alpha = a; }

- (NSPoint)mouseLocationOutsideOfEventStream { return [NSEvent mouseLocation]; }

// Borderless on iOS: the content rect and frame rect are the same.
- (NSRect)contentRectForFrameRect:(NSRect)frameRect { return frameRect; }
- (NSRect)frameRectForContentRect:(NSRect)contentRect { return contentRect; }

@end
