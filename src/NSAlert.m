#import "AKShimPrivate.h"
#import "AppKitShim/NSAlert.h"

UIViewController *AKTopViewController(void) {
  UIViewController *root = nil;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    for (UIWindow *w in ((UIWindowScene *)scene).windows) {
      if (w.isKeyWindow || !root) root = w.rootViewController;
    }
  }
  while (root.presentedViewController) root = root.presentedViewController;
  return root;
}

void AKRunModalUntil(BOOL (^finished)(void)) {
  while (!finished()) {
    @autoreleasepool {
      [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
  }
}

@implementation NSAlert {
  NSMutableArray<NSButton *> *_buttons;
}

- (instancetype)init {
  if ((self = [super init])) { _messageText = @"Alert"; _informativeText = @""; _buttons = [NSMutableArray array]; }
  return self;
}

- (NSArray<NSButton *> *)buttons { return [_buttons copy]; }

- (NSButton *)addButtonWithTitle:(NSString *)title {
  NSButton *b = [NSButton buttonWithTitle:title target:nil action:NULL];
  b.tag = NSAlertFirstButtonReturn + (NSInteger)_buttons.count;
  [_buttons addObject:b];
  return b;
}

// The first button is the default, as on the Mac; one titled "Cancel" gets the cancel style.
- (void)_present:(void (^)(NSModalResponse))done {
  UIViewController *top = AKTopViewController();
  if (!top) { done(_buttons.count ? NSAlertFirstButtonReturn : NSModalResponseOK); return; }
  UIAlertController *ui = [UIAlertController alertControllerWithTitle:_messageText message:_informativeText
                                                       preferredStyle:UIAlertControllerStyleAlert];
  NSArray<NSButton *> *buttons = _buttons.count ? _buttons : @[ [self addButtonWithTitle:@"OK"] ];
  for (NSButton *b in buttons) {
    BOOL cancel = [b.title caseInsensitiveCompare:@"Cancel"] == NSOrderedSame;
    UIAlertActionStyle style = cancel ? UIAlertActionStyleCancel
        : (_alertStyle == NSAlertStyleCritical && b == buttons.firstObject ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault);
    NSModalResponse code = b.tag;
    UIAlertAction *action = [UIAlertAction actionWithTitle:b.title style:style handler:^(UIAlertAction *a) { done(code); }];
    [ui addAction:action];
    if (b == buttons.firstObject && !cancel) ui.preferredAction = action;
  }
  [top presentViewController:ui animated:YES completion:nil];
}

- (NSModalResponse)runModal {
  __block NSModalResponse result = NSModalResponseAbort;
  __block BOOL answered = NO;
  [self _present:^(NSModalResponse r) { result = r; answered = YES; }];
  AKRunModalUntil(^BOOL { return answered; });
  return result;
}

- (void)beginSheetModalForWindow:(NSWindow *)window completionHandler:(void (^)(NSModalResponse))handler {
  [self _present:^(NSModalResponse r) { if (handler) handler(r); }];
}

@end
