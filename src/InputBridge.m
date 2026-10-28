// UIKit → AppKit input. Every NSView's backing UIView turns touches, hardware key presses,
// on-screen keyboard text, pointer hover and trackpad scrolling into NSEvents, and hands
// them to [NSApp sendEvent:] so they flow app → window → view exactly as on the Mac.
#import "AKShimPrivate.h"
#import "AppKitShim/AKShimInput.h"
#import <objc/runtime.h>

#pragma mark Software keyboard policy

static AKShimSoftwareKeyboardPolicy gKeyboardPolicy = AKShimSoftwareKeyboardAutomatic;
static BOOL gKeyboardWanted;

static NSView *AKFocusedView(void) {
  NSWindow *w = NSApp.keyWindow;
  NSResponder *r = w.firstResponder;
  return [r isKindOfClass:NSView.class] ? (NSView *)r : w.contentView;
}

static BOOL AKKeyboardShouldShow(void) {
  if (gKeyboardPolicy == AKShimSoftwareKeyboardNever || !NSApp.keyWindow) return NO;
  if (gKeyboardPolicy == AKShimSoftwareKeyboardAlways) return YES;
  // Chromium's view returns nil from -inputContext unless a text field is focused.
  NSResponder *r = NSApp.keyWindow.firstResponder;
  return [r isKindOfClass:NSView.class] && ((NSView *)r).inputContext != nil;
}

void AKShimSetSoftwareKeyboardPolicy(AKShimSoftwareKeyboardPolicy policy) {
  gKeyboardPolicy = policy;
  AKShimUpdateSoftwareKeyboard();
}

AKShimSoftwareKeyboardPolicy AKShimGetSoftwareKeyboardPolicy(void) { return gKeyboardPolicy; }

void AKShimUpdateSoftwareKeyboard(void) {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{ AKShimUpdateSoftwareKeyboard(); });
    return;
  }
  // Focus can move after the click that caused it (Chromium learns about a focused field
  // from its renderer a moment later), so also poll a few times a second.
  static NSTimer *poll;
  if (!poll) {
    poll = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) { AKShimUpdateSoftwareKeyboard(); }];
    [NSRunLoop.mainRunLoop addTimer:poll forMode:NSRunLoopCommonModes];
  }
  // Act only once the answer has held for a moment: while a page loads, focus hops between
  // fields and elements, and following every hop opened and closed the keyboard repeatedly.
  static BOOL pendingWant;
  static CFAbsoluteTime pendingSince;
  BOOL want = AKKeyboardShouldShow();
  if (want == gKeyboardWanted) { pendingWant = want; return; }
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (want != pendingWant) { pendingWant = want; pendingSince = now; return; }
  if (now - pendingSince < 0.4) return;
  gKeyboardWanted = want;
  [AKFocusedView().backingView reloadInputViews];
}

#pragma mark Per-view input state

static char kActiveTouchKey, kRightButtonKey, kRepeatTimerKey, kLastPanKey;

@implementation _AKShimBackingView (AKShimInput)

- (void)_ak_installInputSupport {
  // Pointer hover (iPad trackpad/mouse) and indirect scrolling. The handlers act only on a
  // window's content view and hit-test from there, so nested views don't double-report.
  UIHoverGestureRecognizer *hover = [[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(_ak_hover:)];
  [self addGestureRecognizer:hover];

  UIPanGestureRecognizer *scroll = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_ak_scroll:)];
  scroll.allowedScrollTypesMask = UIScrollTypeMaskAll;
  scroll.allowedTouchTypes = @[]; // trackpad/mouse wheel only; finger drags stay mouse drags
  [self addGestureRecognizer:scroll];
}

- (BOOL)_ak_isWindowRoot {
  NSWindow *w = self.owner.window;
  return w && w.contentView == self.owner;
}

// The NSView under a point in this (root) view: UIKit hit-test, then up to the nearest shim view.
- (NSView *)_ak_viewAtPoint:(CGPoint)p {
  UIView *hit = [self hitTest:p withEvent:nil];
  while (hit && ![hit isKindOfClass:_AKShimBackingView.class]) hit = hit.superview;
  return ((_AKShimBackingView *)hit).owner ?: self.owner;
}

#pragma mark Mouse

- (void)_ak_sendMouse:(NSEventType)type touch:(UITouch *)touch target:(NSView *)target {
  NSWindow *w = target.window;
  if (!w) return;
  NSPoint p = [touch locationInView:w.contentView.backingView];
  [NSEvent _setMouseLocation:p];
  NSEvent *e = [NSEvent mouseEventWithType:type location:p modifierFlags:[NSEvent modifierFlags]
                                 timestamp:touch.timestamp windowNumber:w.windowNumber context:nil
                               eventNumber:0 clickCount:MAX(touch.tapCount, 1) pressure:1];
  [e _setWindow:w targetView:target];
  [target _ak_deliverEvent:e];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  if (objc_getAssociatedObject(self, &kActiveTouchKey)) return; // one pointer at a time
  UITouch *t = touches.anyObject;
  BOOL right = (event.buttonMask & UIEventButtonMaskSecondary) != 0;
  objc_setAssociatedObject(self, &kActiveTouchKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(self, &kRightButtonKey, @(right), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [self _ak_sendMouse:right ? NSEventTypeRightMouseDown : NSEventTypeLeftMouseDown touch:t target:self.owner];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  UITouch *t = objc_getAssociatedObject(self, &kActiveTouchKey);
  if (![touches containsObject:t]) return;
  BOOL right = [objc_getAssociatedObject(self, &kRightButtonKey) boolValue];
  [self _ak_sendMouse:right ? NSEventTypeRightMouseDragged : NSEventTypeLeftMouseDragged touch:t target:self.owner];
}

- (void)_ak_endTouches:(NSSet<UITouch *> *)touches {
  UITouch *t = objc_getAssociatedObject(self, &kActiveTouchKey);
  if (![touches containsObject:t]) return;
  BOOL right = [objc_getAssociatedObject(self, &kRightButtonKey) boolValue];
  [self _ak_sendMouse:right ? NSEventTypeRightMouseUp : NSEventTypeLeftMouseUp touch:t target:self.owner];
  objc_setAssociatedObject(self, &kActiveTouchKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self _ak_endTouches:touches]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self _ak_endTouches:touches]; }

- (void)_ak_hover:(UIHoverGestureRecognizer *)g {
  if (![self _ak_isWindowRoot]) return;
  NSWindow *w = self.owner.window;
  CGPoint p = [g locationInView:self];
  [NSEvent _setMouseLocation:p];
  NSView *target = [self _ak_viewAtPoint:p];
  NSEvent *e = [NSEvent mouseEventWithType:NSEventTypeMouseMoved location:p modifierFlags:[NSEvent modifierFlags]
                                 timestamp:0 windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:0 pressure:0];
  [e _setWindow:w targetView:target];
  [target _ak_deliverEvent:e];
}

- (void)_ak_scroll:(UIPanGestureRecognizer *)g {
  if (![self _ak_isWindowRoot]) return;
  if (g.state == UIGestureRecognizerStateBegan) {
    objc_setAssociatedObject(self, &kLastPanKey, [NSValue valueWithCGPoint:CGPointZero], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  if (g.state != UIGestureRecognizerStateChanged) return;
  // Natural scrolling: fingers moving down scroll content down, which AppKit reports as a
  // positive scrollingDeltaY — the same sign as UIKit's pan translation.
  CGPoint now = [g translationInView:self];
  CGPoint last = [objc_getAssociatedObject(self, &kLastPanKey) CGPointValue];
  objc_setAssociatedObject(self, &kLastPanKey, [NSValue valueWithCGPoint:now], OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  NSWindow *w = self.owner.window;
  CGPoint p = [g locationInView:self];
  NSView *target = [self _ak_viewAtPoint:p];
  NSEvent *e = [NSEvent mouseEventWithType:NSEventTypeScrollWheel location:p modifierFlags:[NSEvent modifierFlags]
                                 timestamp:0 windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:0 pressure:0];
  [e _setWindow:w targetView:target];
  [e _setDeltaX:now.x - last.x deltaY:now.y - last.y];
  [target _ak_deliverEvent:e];
}

#pragma mark Keyboard

- (BOOL)canBecomeFirstResponder { return YES; }

// An empty input view hides the system keyboard while keeping hardware keys flowing.
- (UIView *)inputView {
  if (gKeyboardWanted) return nil;
  static UIView *none;
  if (!none) none = [[UIView alloc] initWithFrame:CGRectZero];
  return none;
}

- (void)_ak_sendKey:(NSEventType)type code:(unsigned short)code characters:(NSString *)chars
         unmodified:(NSString *)raw flags:(NSEventModifierFlags)flags repeat:(BOOL)repeat {
  NSWindow *w = self.owner.window;
  if (!w) return;
  NSEvent *e = [NSEvent keyEventWithType:type location:[NSEvent mouseLocation] modifierFlags:flags
                               timestamp:0 windowNumber:w.windowNumber context:nil
                              characters:chars ?: @"" charactersIgnoringModifiers:raw ?: @""
                               isARepeat:repeat keyCode:code];
  [self.owner _ak_deliverEvent:e];
}

// Hardware keyboard. Handling the press here (without calling super) also stops UIKit from
// delivering the same key again through -insertText:.
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  BOOL handled = NO;
  for (UIPress *press in presses) {
    UIKey *key = press.key;
    if (!key) continue;
    handled = YES;
    [self _ak_keyChanged:key down:YES];
  }
  if (!handled) [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  BOOL handled = NO;
  for (UIPress *press in presses) {
    if (!press.key) continue;
    handled = YES;
    [self _ak_keyChanged:press.key down:NO];
  }
  if (!handled) [super pressesEnded:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  [self pressesEnded:presses withEvent:event];
}

- (void)_ak_keyChanged:(UIKey *)key down:(BOOL)down {
  long usage = key.keyCode;
  unsigned short code = AKMacKeyCodeForHIDUsage(usage);
  NSEventModifierFlags modifier = AKModifierFlagForHIDUsage(usage);

  if (modifier) {
    NSEventModifierFlags flags = [NSEvent modifierFlags];
    if (modifier == NSEventModifierFlagCapsLock) {
      flags = (flags & ~modifier) | ((NSEventModifierFlags)key.modifierFlags & NSEventModifierFlagCapsLock);
    } else {
      flags = down ? (flags | modifier) : (flags & ~modifier);
    }
    [NSEvent _setModifierFlags:flags];
    [self _ak_sendKey:NSEventTypeFlagsChanged code:code characters:@"" unmodified:@"" flags:flags repeat:NO];
    return;
  }

  // UIKit's modifier bits use the same values as AppKit's.
  NSEventModifierFlags flags = (NSEventModifierFlags)key.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  NSString *special = AKCharactersForMacKeyCode(code);
  NSString *chars = special ?: key.characters;
  NSString *raw = special ?: key.charactersIgnoringModifiers;

  [self _ak_stopRepeat];
  // A combination registered with RegisterEventHotKey goes to its Carbon handler instead.
  if (AKCarbonDispatchHotKey(code, flags, down)) return;
  if (!down) {
    [self _ak_sendKey:NSEventTypeKeyUp code:code characters:chars unmodified:raw flags:flags repeat:NO];
    return;
  }
  [self _ak_sendKey:NSEventTypeKeyDown code:code characters:chars unmodified:raw flags:flags repeat:NO];

  // UIKit doesn't auto-repeat raw presses; do it ourselves with the usual Mac timing.
  __weak typeof(self) weakSelf = self;
  NSTimer *delay = [NSTimer timerWithTimeInterval:0.4 repeats:NO block:^(NSTimer *t) {
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf) return;
    NSTimer *repeat = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *rt) {
      [weakSelf _ak_sendKey:NSEventTypeKeyDown code:code characters:chars unmodified:raw flags:flags repeat:YES];
    }];
    [NSRunLoop.mainRunLoop addTimer:repeat forMode:NSRunLoopCommonModes];
    objc_setAssociatedObject(strongSelf, &kRepeatTimerKey, repeat, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }];
  [NSRunLoop.mainRunLoop addTimer:delay forMode:NSRunLoopCommonModes];
  objc_setAssociatedObject(self, &kRepeatTimerKey, delay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)_ak_stopRepeat {
  NSTimer *t = objc_getAssociatedObject(self, &kRepeatTimerKey);
  [t invalidate];
  objc_setAssociatedObject(self, &kRepeatTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// On-screen keyboard (UIKeyInput). It reports text, not keys, so each character becomes a
// key down/up pair with the key code a US layout would produce.
- (BOOL)hasText { return YES; }

- (void)insertText:(NSString *)text {
  [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                           options:NSStringEnumerationByComposedCharacterSequences
                        usingBlock:^(NSString *s, NSRange r, NSRange er, BOOL *stop) {
    unichar c = [s characterAtIndex:0];
    NSString *chars = (c == '\n') ? @"\r" : s;
    unsigned short code = AKMacKeyCodeForCharacter(c);
    NSEventModifierFlags flags = (c >= 'A' && c <= 'Z') ? NSEventModifierFlagShift : 0;
    NSString *raw = chars.lowercaseString;
    [self _ak_sendKey:NSEventTypeKeyDown code:code characters:chars unmodified:raw flags:flags repeat:NO];
    [self _ak_sendKey:NSEventTypeKeyUp code:code characters:chars unmodified:raw flags:flags repeat:NO];
  }];
}

- (void)deleteBackward {
  NSString *del = AKCharactersForMacKeyCode(0x33);
  [self _ak_sendKey:NSEventTypeKeyDown code:0x33 characters:del unmodified:del flags:0 repeat:NO];
  [self _ak_sendKey:NSEventTypeKeyUp code:0x33 characters:del unmodified:del flags:0 repeat:NO];
}

@end
