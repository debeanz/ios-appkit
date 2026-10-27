#import "AKShimPrivate.h"
#import "AppKitShim/NSViewController.h"
#import "AppKitShim/NSWindow.h"

@implementation NSViewController {
  NSView *_view;
  NSMutableArray<NSViewController *> *_children;
}

- (instancetype)init { return [self initWithNibName:nil bundle:nil]; }

- (instancetype)initWithNibName:(NSString *)nibName bundle:(NSBundle *)bundle {
  if ((self = [super init])) {
    _nibName = [nibName copy];
    _nibBundle = bundle;
    _children = [NSMutableArray array];
  }
  return self;
}

- (BOOL)isViewLoaded { return _view != nil; }

// First access loads the view, then -viewDidLoad, exactly once — like AppKit.
- (NSView *)view {
  if (!_view) {
    [self loadView];
    if (!_view) _view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 240)];
    [self viewDidLoad];
  }
  return _view;
}

- (void)setView:(NSView *)view { _view = view; }

// No nib loading on iOS; subclasses build their view by overriding -loadView.
- (void)loadView {}
- (void)viewDidLoad {}
- (void)viewWillAppear {}
- (void)viewDidAppear {}
- (void)viewWillDisappear {}
- (void)viewDidDisappear {}

- (NSArray<NSViewController *> *)childViewControllers { return [_children copy]; }

- (void)addChildViewController:(NSViewController *)child {
  if (!child) return;
  [child removeFromParentViewController];
  child.parentViewController = self;
  [_children addObject:child];
}

- (void)removeFromParentViewController {
  [self.parentViewController->_children removeObjectIdenticalTo:self];
  self.parentViewController = nil;
}

@end

@implementation NSWindowController {
  NSWindow *_window;
  BOOL _loaded;
}

- (instancetype)init { return [self initWithWindow:nil]; }

- (instancetype)initWithWindow:(NSWindow *)window {
  if ((self = [super init])) { _window = window; _loaded = window != nil; }
  return self;
}

- (instancetype)initWithWindowNibName:(NSString *)windowNibName { return [self initWithWindow:nil]; }

- (BOOL)isWindowLoaded { return _loaded; }

- (NSWindow *)window {
  if (!_window && !_loaded) {
    _loaded = YES;
    [self loadWindow];
    if (!_window && _contentViewController) {
      _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 480)
                                            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
      _window.contentView = _contentViewController.view;
    }
    [self windowDidLoad];
  }
  return _window;
}

- (void)setWindow:(NSWindow *)window { _window = window; _loaded = YES; }

- (void)setContentViewController:(NSViewController *)contentViewController {
  _contentViewController = contentViewController;
  self.window.contentView = contentViewController.view;
}

- (void)loadWindow {}
- (void)windowDidLoad {}

- (void)showWindow:(id)sender {
  [_contentViewController viewWillAppear];
  [self.window makeKeyAndOrderFront:sender];
  [_contentViewController viewDidAppear];
}

- (void)close { [_window close]; }
- (void)performClose:(id)sender { [_window close]; }

@end
