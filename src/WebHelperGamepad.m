// Controllers for Steam's interface. Big Picture navigates with the buttons it gets through
// SteamClient.Input.RegisterForControllerInputMessages, one of Steam Helper's own functions,
// which Steam Helper feeds from the Steam client through the Steamworks API it links. That
// connection can't be made with the client in the same process (SteamAPI_Init fails:
// "ipcserver init failed"), so here the buttons come from the GameController framework, as
// the EGamepadButton codes the interface expects (callback: controller index, button,
// pressed, x, y). Its navigation listens to the left stick's four directions - the D-pad
// sends those too - the face buttons, bumpers, triggers, View/Menu and the stick clicks.
// The Xbox/Home button opens Steam's menu and Home + A the Quick Access menu, through Steam's
// system-key event (only while Steam sends none of its own). View + Menu pressed together is the
// Steam button too (iOS may keep Home for itself): in Steam it opens the menu, in a game Steam's
// overlay over the game with the menu open, as on Steam Deck (the game's overlay window, or Big
// Picture's when there is none) - Resume, closing the menu with B, or View + Menu again goes back
// to the game.
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
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
// View and Menu: each held back kChordWindow before it counts, to tell it from the chord.
@property(nonatomic) BOOL menuRaw, viewRaw, aRaw, chord, chordUsed, recheck;
@property(nonatomic) CFTimeInterval menuSince, viewSince;
@property(atomic) BOOL menuOut, viewOut;                       // as delivered (to Steam, or the game)
@property(atomic) CFTimeInterval menuTapUntil, viewTapUntil;   // a short press, shown to the game this long
@end

@implementation AKWHPad
@end

static NSMutableArray<AKWHPad *> *gPads;
static unsigned gLogged;

static const CFTimeInterval kChordWindow = 0.12;
static BOOL gOverlay;                       // Big Picture shown over a running game
static BOOL gOverlayComposed;               // its overlay window has said it is up since
static int gLastButton = -1;                // the last button pressed in Steam's interface
static CFTimeInterval gLastButtonTime;

static uint64_t bit(int code) { return 1ull << code; }

static void send(AKWHPad *pad, int code, BOOL pressed) {
  if (++gLogged <= 40) AKWHLog(NO, @"controller %u: button %d %@", pad.index, code, pressed ? @"down" : @"up");
  if (pressed) { gLastButton = code; gLastButtonTime = CACurrentMediaTime(); }
  AKWHSendControllerButton(pad.index, code, pressed);
}

BOOL AKGameIsRunning(void);
UIView *AKWHStageView(void);
void AKGameControllersHoldBack(void);   // GameHID.m
BOOL AKBlockIsDeadGameCode(id block);   // GameTeardown.m

static void releaseHeld(AKWHPad *pad) {
  for (int code = 0; pad.down; code++)
    if (pad.down & bit(code)) { send(pad, code, NO); pad.down &= ~bit(code); }
}

#pragma mark Steam's overlay over a game

BOOL AKGameOverlayShown(void) { return gOverlay; }

// Over the game: the game's overlay window when Steam's interface made one (Steam Deck's menu
// over the game), else Big Picture's own window; the Steam key then opens the menu in it.
static void setOverlay(BOOL shown, uint32_t controller, uint32_t key) {
  UIView *stage = AKWHStageView();
  if (!stage || shown == gOverlay || (shown && !AKGameIsRunning())) return;
  gOverlay = shown;
  if (shown) {
    gOverlayComposed = NO;
    stage.hidden = NO;
    [stage.superview bringSubviewToFront:stage];
    BOOL own = AKWHShowGameOverlay(YES);
    AKWHLog(YES, own ? @"Steam overlay over the game" : @"Steam overlay over the game (Big Picture's window: the game has no overlay window)");
    // The overlay window's document takes the focus a moment after its view does; the key goes
    // to the focused window.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((own ? 0.15 : 0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      if (gOverlay) AKWHSendSystemKey(key, controller);
    });
    // The overlay window says it is up (its composition) when its menu opens. One that stays
    // hidden gives way to Big Picture's own window, with the key sent again there.
    if (own) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      if (!gOverlay || gOverlayComposed) return;
      AKWHLog(YES, @"the game's overlay window didn't open its menu: Big Picture's window instead");
      AKWHShowGameOverlay(NO);
      AKWHFocusSteamWindow();
      AKWHSendSystemKey(key, controller);
    });
  } else {
    AKWHShowGameOverlay(NO);
    AKGameControllersHoldBack();   // the A that chose Resume isn't the game's
    stage.hidden = YES;   // the game's window is under it
    for (AKWHPad *pad in gPads) releaseHeld(pad);
    AKWHLog(YES, @"Steam overlay closed: back to the game");
  }
}

void AKGameOverlayHide(void) { setOverlay(NO, 0, 0); }
void AKGameOverlayReset(void) {
  gOverlay = NO;
  AKWHShowGameOverlay(NO);
}

// The game's overlay window is done (hidden, or a notification only) after having been up:
// Resume, B out of its menu, or anything else that closes it. Back to the game.
void AKWHGameOverlayComposed(int mode) {
  if (mode >= 2) gOverlayComposed = YES;
  else if (gOverlay && gOverlayComposed) setOverlay(NO, 0, 0);
}

// One of Big Picture's menus hidden while it is over a game: closed with B, nothing was chosen
// from it, so back to the game (a choice - the library, a setting - keeps Steam up).
void AKWHGameOverlayMenu(NSString *name, BOOL visible) {
  if (!gOverlay || visible || !([name hasPrefix:@"MainMenu"] || [name hasPrefix:@"QuickAccess"])) return;
  if (gLastButton == kButtonB && CACurrentMediaTime() - gLastButtonTime < 1.5) setOverlay(NO, 0, 0);
}

// The Steam button (Home, or View + Menu): Steam's menu, over the game when one runs; pressed
// again over a game, back to it.
static void steamButton(AKWHPad *pad, uint32_t key) {
  if (!AKGameIsRunning()) AKWHSendSystemKey(key, pad.index);
  else if (gOverlay) setOverlay(NO, 0, 0);
  else setOverlay(YES, pad.index, key);
}

#pragma mark View and Menu

static void update(AKWHPad *pad, GCExtendedGamepad *g);

// Each on its own counts once held kChordWindow (Steam gets it pressed, the game sees it held),
// or as a short press when let go sooner; with the other inside that time, they're the chord.
static void menuView(AKWHPad *pad, GCExtendedGamepad *g) {
  CFTimeInterval t = CACurrentMediaTime();
  BOOL menu = g.buttonMenu.pressed, view = g.buttonOptions.pressed, a = g.buttonA.pressed;
  if (menu && !pad.menuRaw) pad.menuSince = t;
  if (view && !pad.viewRaw) pad.viewSince = t;
  if (menu && view && !pad.chord && fabs(pad.menuSince - pad.viewSince) <= kChordWindow) {
    pad.chord = YES;
    pad.chordUsed = NO;
    pad.menuOut = pad.viewOut = NO;
  }
  if (pad.chord && a && !pad.aRaw) {   // View + Menu + A: Quick Access (that A isn't passed on)
    pad.chordUsed = YES;
    pad.swallowed |= bit(kButtonA);
    steamButton(pad, kSystemKeyQuickAccess);
  }
  if (pad.chord && !menu && !view) {
    pad.chord = NO;
    if (!pad.chordUsed) steamButton(pad, kSystemKeySteam);
  } else if (!pad.chord) {
    BOOL toSteam = !AKGameIsRunning() || gOverlay;
    BOOL raw[2] = { menu, view }, was[2] = { pad.menuRaw, pad.viewRaw }, out[2] = { pad.menuOut, pad.viewOut };
    CFTimeInterval since[2] = { pad.menuSince, pad.viewSince };
    int code[2] = { kStart, kSelect };
    for (int i = 0; i < 2; i++) {
      if (raw[i] && !out[i] && t - since[i] >= kChordWindow) out[i] = YES;
      else if (!raw[i] && out[i]) out[i] = NO;
      else if (!raw[i] && was[i]) {   // let go within the hold-back: a short press
        if (toSteam) { send(pad, code[i], YES); send(pad, code[i], NO); }
        else if (i == 0) pad.menuTapUntil = t + 0.1;
        else pad.viewTapUntil = t + 0.1;
      }
    }
    pad.menuOut = out[0];
    pad.viewOut = out[1];
  }
  pad.menuRaw = menu;
  pad.viewRaw = view;
  pad.aRaw = a;
  // Still deciding: look again once the hold-back is over.
  if (((menu && !pad.menuOut) || (view && !pad.viewOut)) && !pad.chord && !pad.recheck) {
    pad.recheck = YES;
    __weak AKWHPad *weak = pad;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kChordWindow + 0.01) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      AKWHPad *p = weak;
      if (!p) return;
      p.recheck = NO;
      if (p.controller.extendedGamepad) update(p, p.controller.extendedGamepad);
    });
  }
}

// Menu or View as a game should see it (GameHID.m), for controller `c`.
BOOL AKControllerMenuViewPressed(GCController *c, BOOL menu) {
  CFTimeInterval t = CACurrentMediaTime();
  @synchronized (gPads) {
    for (AKWHPad *pad in gPads) {
      if (pad.controller != c) continue;
      return menu ? (pad.menuOut || t < pad.menuTapUntil) : (pad.viewOut || t < pad.viewTapUntil);
    }
  }
  return menu ? c.extendedGamepad.buttonMenu.pressed : c.extendedGamepad.buttonOptions.pressed;
}

static void update(AKWHPad *pad, GCExtendedGamepad *g) {
  BOOL aWas = pad.aRaw, aNow = g.buttonA.pressed;
  menuView(pad, g);

  // Home: a tap is the Steam button; Home held while A goes down is Quick Access (that A isn't
  // passed on, nor its release).
  BOOL home = g.buttonHome.pressed;
  if (home && !pad.homeDown) { pad.homeDown = YES; pad.homeUsed = NO; }
  if (pad.homeDown && aNow && !aWas && !(pad.swallowed & bit(kButtonA))) {
    pad.homeUsed = YES;
    pad.swallowed |= bit(kButtonA);
    steamButton(pad, kSystemKeyQuickAccess);
  }
  if (!home && pad.homeDown) {
    pad.homeDown = NO;
    if (!pad.homeUsed) steamButton(pad, kSystemKeySteam);
  }

  // While a game runs (MacPrograms.m) with Steam not over it, the controller is the game's: Big
  // Picture, hidden under it, mustn't move or open menus too. Held buttons are let go first.
  if (AKGameIsRunning() && !gOverlay) {
    releaseHeld(pad);
    pad.swallowed &= aNow ? bit(kButtonA) : 0;
    return;
  }
  uint64_t held = pad.down, now = 0;
  if (g.buttonA.pressed) now |= bit(kButtonA);
  if (g.buttonB.pressed) now |= bit(kButtonB);
  if (g.buttonX.pressed) now |= bit(kButtonX);
  if (g.buttonY.pressed) now |= bit(kButtonY);
  if (g.leftShoulder.pressed) now |= bit(kLeftShoulder);
  if (g.rightShoulder.pressed) now |= bit(kRightShoulder);
  if (g.leftTrigger.pressed) now |= bit(kLeftTrigger);
  if (g.rightTrigger.pressed) now |= bit(kRightTrigger);
  if (pad.viewOut) now |= bit(kSelect);    // held back to tell them from View + Menu (menuView)
  if (pad.menuOut) now |= bit(kStart);
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

  pad.swallowed &= now;   // released buttons are no longer swallowed

  uint64_t changed = (now ^ held) & ~pad.swallowed;
  for (int code = 0; changed; code++, changed >>= 1)
    if (changed & 1) send(pad, code, (now & bit(code)) != 0);
  pad.down = now & ~pad.swallowed;
}

// Our handler goes in front of whatever the controller had (SDL, for Steam's own input, or a
// game reading GameController itself), and back in if something replaces it. A game's handler
// is passed nothing once the game has ended (its code is gone with it).
static void watch(AKWHPad *pad) {
  GCExtendedGamepad *g = pad.controller.extendedGamepad;
  if (!g || (pad.handler && g.valueChangedHandler == pad.handler)) return;
  GCExtendedGamepadValueChangedHandler previous = g.valueChangedHandler;
  __weak AKWHPad *weakPad = pad;
  pad.handler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
    if (previous && !AKBlockIsDeadGameCode(previous)) previous(gamepad, element);
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
  @synchronized (gPads) { [gPads addObject:pad]; }
  // The Home button is the Steam button here, not iOS's game overlay.
  if (@available(iOS 14.5, *)) c.extendedGamepad.buttonHome.preferredSystemGestureState = GCSystemGestureStateDisabled;
  watch(pad);
  AKWHLog(YES, @"controller %u: %@ drives Steam's interface", index, c.vendorName ?: @"a controller");
}

static void disconnected(GCController *c) {
  for (AKWHPad *pad in [gPads copy]) {
    if (pad.controller != c) continue;
    for (int code = 0; code < 64; code++) if (pad.down & bit(code)) send(pad, code, NO);
    @synchronized (gPads) { [gPads removeObject:pad]; }
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
