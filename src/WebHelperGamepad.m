// Controllers for Steam's interface. Big Picture navigates with the buttons it gets through
// SteamClient.Input.RegisterForControllerInputMessages, one of Steam Helper's own functions,
// which Steam Helper feeds from the Steam client through the Steamworks API it links. That
// connection can't be made with the client in the same process (SteamAPI_Init fails:
// "ipcserver init failed"), so here the buttons come from the GameController framework, as
// the EGamepadButton codes the interface expects (callback: controller index, button,
// pressed, x, y). Its navigation listens to the left stick's four directions - the D-pad
// sends those too - the face buttons, bumpers, triggers, View/Menu and the stick clicks.
// The Xbox/Home button opens Steam's menu and Home + A the Quick Access menu, through Steam's
// system-key event (only while Steam sends none of its own).
#import <GameController/GameController.h>
#import "WebHelper.h"

enum {   // EGamepadButton, the interface's numbering
  kButtonA = 0, kButtonB = 1, kButtonX = 2, kButtonY = 3,
  kStickUp = 20, kStickDown = 21, kStickLeft = 22, kStickRight = 23, kStickClick = 25,
  kLeftTrigger = 28, kRightTrigger = 29, kLeftShoulder = 30, kRightShoulder = 31,
  kSelect = 35, kStart = 36, kRightStickClick = 41,
};
enum { kSystemKeySteam = 0, kSystemKeyQuickAccess = 1 };   // ESystemKey

@interface AKWHPad : NSObject
@property(nonatomic) uint32_t index;
@property(nonatomic, strong) GCController *controller;
@property(nonatomic, copy) GCExtendedGamepadValueChangedHandler handler;   // ours, as installed
@property(nonatomic) uint64_t down;       // a bit per EGamepadButton code being held
@property(nonatomic) uint64_t swallowed;  // held since Home + it made a menu; its release isn't sent
@property(nonatomic) BOOL homeDown, homeUsed;
@end

@implementation AKWHPad
@end

static NSMutableArray<AKWHPad *> *gPads;
static unsigned gLogged;

static uint64_t bit(int code) { return 1ull << code; }

static void send(AKWHPad *pad, int code, BOOL pressed) {
  if (++gLogged <= 40) AKWHLog(NO, @"controller %u: button %d %@", pad.index, code, pressed ? @"down" : @"up");
  AKWHSendControllerButton(pad.index, code, pressed);
}

static void update(AKWHPad *pad, GCExtendedGamepad *g) {
  uint64_t held = pad.down, now = 0;
  if (g.buttonA.pressed) now |= bit(kButtonA);
  if (g.buttonB.pressed) now |= bit(kButtonB);
  if (g.buttonX.pressed) now |= bit(kButtonX);
  if (g.buttonY.pressed) now |= bit(kButtonY);
  if (g.leftShoulder.pressed) now |= bit(kLeftShoulder);
  if (g.rightShoulder.pressed) now |= bit(kRightShoulder);
  if (g.leftTrigger.pressed) now |= bit(kLeftTrigger);
  if (g.rightTrigger.pressed) now |= bit(kRightTrigger);
  if (g.buttonOptions.pressed) now |= bit(kSelect);
  if (g.buttonMenu.pressed) now |= bit(kStart);
  if (g.leftThumbstickButton.pressed) now |= bit(kStickClick);
  if (g.rightThumbstickButton.pressed) now |= bit(kRightStickClick);
  // Directions: the D-pad, or the stick past half way (held until it drops back under a third,
  // so a stick resting near the edge doesn't chatter).
  float x = g.leftThumbstick.xAxis.value, y = g.leftThumbstick.yAxis.value;
  float upAt = (held & bit(kStickUp)) ? 0.35f : 0.5f, downAt = (held & bit(kStickDown)) ? 0.35f : 0.5f;
  float leftAt = (held & bit(kStickLeft)) ? 0.35f : 0.5f, rightAt = (held & bit(kStickRight)) ? 0.35f : 0.5f;
  if (g.dpad.up.pressed || y > upAt) now |= bit(kStickUp);
  if (g.dpad.down.pressed || y < -downAt) now |= bit(kStickDown);
  if (g.dpad.left.pressed || x < -leftAt) now |= bit(kStickLeft);
  if (g.dpad.right.pressed || x > rightAt) now |= bit(kStickRight);

  // Home: a tap is Steam's menu; Home held while A goes down is Quick Access (that A isn't
  // passed on, nor its release).
  BOOL home = g.buttonHome.pressed;
  if (home && !pad.homeDown) { pad.homeDown = YES; pad.homeUsed = NO; }
  if (pad.homeDown && (now & bit(kButtonA)) && !(held & bit(kButtonA)) && !(pad.swallowed & bit(kButtonA))) {
    pad.homeUsed = YES;
    pad.swallowed |= bit(kButtonA);
    AKWHSendSystemKey(kSystemKeyQuickAccess, pad.index);
  }
  if (!home && pad.homeDown) {
    pad.homeDown = NO;
    if (!pad.homeUsed) AKWHSendSystemKey(kSystemKeySteam, pad.index);
  }
  pad.swallowed &= now;   // released buttons are no longer swallowed

  uint64_t changed = (now ^ held) & ~pad.swallowed;
  for (int code = 0; changed; code++, changed >>= 1)
    if (changed & 1) send(pad, code, (now & bit(code)) != 0);
  pad.down = now & ~pad.swallowed;
}

// Our handler goes in front of whatever the controller had (SDL, for Steam's own input), and
// back in if something replaces it.
static void watch(AKWHPad *pad) {
  GCExtendedGamepad *g = pad.controller.extendedGamepad;
  if (!g || (pad.handler && g.valueChangedHandler == pad.handler)) return;
  GCExtendedGamepadValueChangedHandler previous = g.valueChangedHandler;
  __weak AKWHPad *weakPad = pad;
  pad.handler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
    if (previous) previous(gamepad, element);
    AKWHPad *p = weakPad;
    if (p) update(p, gamepad);
  };
  g.valueChangedHandler = pad.handler;
}

static void connected(GCController *c) {
  for (AKWHPad *p in gPads) if (p.controller == c) return;
  if (!c.extendedGamepad) {
    AKWHLog(YES, @"controller \"%@\" has no gamepad layout Steam's interface can use", c.vendorName);
    return;
  }
  uint32_t index = 0;
  while ([[gPads valueForKey:@"index"] containsObject:@(index)]) index++;
  AKWHPad *pad = [AKWHPad new];
  pad.index = index;
  pad.controller = c;
  [gPads addObject:pad];
  // The Home button is the Steam button here, not iOS's game overlay.
  if (@available(iOS 14.5, *)) c.extendedGamepad.buttonHome.preferredSystemGestureState = GCSystemGestureStateDisabled;
  watch(pad);
  AKWHLog(YES, @"controller %u: %@ drives Steam's interface", index, c.vendorName ?: @"a controller");
}

static void disconnected(GCController *c) {
  for (AKWHPad *pad in [gPads copy]) {
    if (pad.controller != c) continue;
    for (int code = 0; code < 64; code++) if (pad.down & bit(code)) send(pad, code, NO);
    [gPads removeObject:pad];
    AKWHLog(YES, @"controller %u disconnected", pad.index);
  }
}

void AKWHGamepadStart(void) {
  if (gPads) return;
  gPads = [NSMutableArray array];
  NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
  [nc addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification *n) { connected(n.object); }];
  [nc addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification *n) { disconnected(n.object); }];
  for (GCController *c in GCController.controllers) connected(c);
  // Something else (SDL opening the controller for Steam) may set its own handler later.
  NSTimer *check = [NSTimer timerWithTimeInterval:5 repeats:YES block:^(NSTimer *t) {
    for (AKWHPad *pad in gPads) watch(pad);
  }];
  check.tolerance = 1;
  [NSRunLoop.mainRunLoop addTimer:check forMode:NSRunLoopCommonModes];
}
