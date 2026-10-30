// Per-game performance settings, as Steam Deck has them. Steam's interface already carries the
// Deck's Performance tab (Quick Access): its overlay level, "Use per-game profile" and frame rate
// limit read and change the state SteamClient.System.Perf reports (SystemPerfStore in Steam's
// code). Steam's Mac client has no System.Perf, so here the app is that system: the page's
// System.Perf (WebHelperDeck.js) asks this file for the state and sends it each change, and this
// file applies them to the game Steam started:
//  - the overlay level shows Apple's Metal Performance HUD on the game's picture (more of it at
//    each level, as the Deck's overlay grows), on every Metal layer in the game's windows and on
//    AKOpenGL's picture (which goes through a Metal layer while the HUD is up);
//  - the frame rate limit paces the game's frames (each Metal drawable it takes, each OpenGL
//    flush);
//  - the resolution (the app's own row on that tab) is the share of the screen's pixels the game
//    draws at, from its next start (games measure their screen once).
// Profiles are keyed by game id, as Steam keys them: "769" (Steam's own id) is the default one,
// used by every game that has no profile of its own switched on. Kept in the app's defaults.
#import "AKShimPrivate.h"
#import "WebHelper.h"
#import <QuartzCore/QuartzCore.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>

NSString *const AKDefaultProfileID = @"769";
static NSString *const kDefaultsKey = @"AKPerfSettings";

// Steam's EGraphicsPerfOverlayLevel values (the slider's notches 1-4 are Minimal, Basic, Medium, Full).
enum { kOverlayHidden = 0, kOverlayBasic = 1, kOverlayMedium = 2, kOverlayFull = 3, kOverlayMinimal = 4 };

static NSMutableDictionary *gSettings;   // { global: {}, profiles: { id: {} }, perGame: [id] }
static NSString *gGameID;                // the running game's, or nil
static NSString *gGameDraws;             // "metal", "opengl", or nil (not known yet)

// What the running game is held to, read on its threads.
static int gFrameLimit;          // frames per second, 0: none (atomic)
static int gOverlayLevel;        // atomic
static double gRenderFraction = 1;   // of the screen's pixels per point, fixed at each launch

static NSLock *lock(void) {
  static NSLock *l;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ l = [NSLock new]; });
  return l;
}

static NSDictionary *defaultPerApp(void) { return @{ @"fps_limit": @0, @"render_scale": @1.0 }; }

static void load(void) {
  if (gSettings) return;
  NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kDefaultsKey];
  gSettings = [NSMutableDictionary dictionary];
  gSettings[@"global"] = [([saved[@"global"] isKindOfClass:NSDictionary.class] ? saved[@"global"] : @{}) mutableCopy];
  NSMutableDictionary *profiles = [NSMutableDictionary dictionary];
  if ([saved[@"profiles"] isKindOfClass:NSDictionary.class])
    [saved[@"profiles"] enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
      if ([key isKindOfClass:NSString.class] && [value isKindOfClass:NSDictionary.class]) profiles[key] = [value mutableCopy];
    }];
  if (!profiles[AKDefaultProfileID]) profiles[AKDefaultProfileID] = [defaultPerApp() mutableCopy];
  gSettings[@"profiles"] = profiles;
  gSettings[@"perGame"] = [NSMutableOrderedSet orderedSetWithArray:[saved[@"perGame"] isKindOfClass:NSArray.class] ? saved[@"perGame"] : @[]];
}

static void save(void) {
  NSDictionary *out = @{
    @"global": gSettings[@"global"],
    @"profiles": gSettings[@"profiles"],
    @"perGame": [gSettings[@"perGame"] array],
  };
  [NSUserDefaults.standardUserDefaults setObject:out forKey:kDefaultsKey];
}

// The profile the running game uses (or would: the default one when no game runs).
static NSString *activeProfileID(void) {
  return gGameID && [gSettings[@"perGame"] containsObject:gGameID] ? gGameID : AKDefaultProfileID;
}

static NSMutableDictionary *profile(NSString *gameID) {
  NSMutableDictionary *profiles = gSettings[@"profiles"];
  NSMutableDictionary *p = profiles[gameID];
  if (!p) profiles[gameID] = p = [defaultPerApp() mutableCopy];
  return p;
}

static int intValue(id v, int fallback) { return [v isKindOfClass:NSNumber.class] ? [v intValue] : fallback; }
static double fraction(id v) {
  double f = [v isKindOfClass:NSNumber.class] ? [v doubleValue] : 1;
  return f >= 0.25 && f <= 1 ? f : 1;
}

// The frame rate limits offered: whole divisions of the 60 Hz the app's frames are shown at, and
// none (0, "Off" on the slider, last as on the Deck).
static NSArray<NSNumber *> *frameLimitOptions(void) { return @[ @15, @20, @30, @60, @0 ]; }

#pragma mark Metal HUD

// The HUD's metrics at each overlay level (MTL_HUD_ELEMENTS names), from the frame rate alone to
// everything it measures, as the Deck's overlay grows from level 1 to 4.
static NSString *hudElements(int level) {
  switch (level) {
    case kOverlayMinimal: return @"fps";
    case kOverlayBasic: return @"fps,frameinterval,gputime";
    case kOverlayMedium: return @"device,layersize,fps,frameinterval,gputime,memory,thermal,frameintervalgraph";
    case kOverlayFull:
      return @"device,layersize,layerscale,memory,fps,frameinterval,gputime,thermal,frameintervalgraph,"
              "presentdelay,frameintervalhistogram,metalcpu,gputimeline,shaders,framenumber,disk,fpsgraph";
    default: return nil;
  }
}

// CAMetalLayer.developerHUDProperties for the current level: "mode" default shows the HUD on that
// layer, disabled hides it; the HUD's other settings go in the same dictionary under their
// environment variable names.
NSDictionary *AKGameHUDProperties(void) {
  NSString *elements = hudElements(__atomic_load_n(&gOverlayLevel, __ATOMIC_RELAXED));
  if (!elements) return @{ @"mode": @"disabled", @"logging": @"disabled" };
  return @{ @"mode": @"default", @"logging": @"disabled", @"MTL_HUD_ELEMENTS": elements, @"MTL_HUD_ALIGNMENT": @"topright" };
}

static BOOL hudShown(void) { return hudElements(__atomic_load_n(&gOverlayLevel, __ATOMIC_RELAXED)) != nil; }

// What the app keeps per Metal layer: whether it is the game's, whether its HUD setting was made,
// and when its next frame may come (the frame rate limit).
@interface AKLayerState : NSObject {
 @public
  BOOL game, configured;
  uint64_t next;
}
@end
@implementation AKLayerState
@end

static const void *kLayerStateKey = &kLayerStateKey;

static AKLayerState *layerState(CALayer *layer) {
  AKLayerState *state = objc_getAssociatedObject(layer, kLayerStateKey);
  if (!state) {
    state = [AKLayerState new];
    objc_setAssociatedObject(layer, kLayerStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return state;
}

static void applyHUD(CAMetalLayer *layer, NSDictionary *props) {
  if (@available(iOS 16.0, *)) {
    if ([layer.developerHUDProperties isEqualToDictionary:props]) return;
    layer.developerHUDProperties = props;
  } else {
    return;
  }
  static unsigned logged;
  if (++logged <= 6)
    fprintf(stderr, "[AppKitShim] game: Metal HUD %s on its %.0fx%.0f layer\n", [props[@"mode"] isEqual:@"default"] ? "shown" : "hidden",
            layer.drawableSize.width, layer.drawableSize.height);
}

static void eachLayer(CALayer *layer, void (^fn)(CALayer *)) {
  fn(layer);
  for (CALayer *sub in [layer.sublayers copy]) eachLayer(sub, fn);
}

// Every Metal layer in the game's windows gets the HUD's current setting, and is marked as the
// game's (for the frame limit). Main thread.
static void applyToGameLayers(void) {
  if (!AKGameIsRunning()) return;
  NSDictionary *props = AKGameHUDProperties();
  for (NSWindow *w in NSApp.windows) {
    if (!w._ak_gameWindow) continue;
    CALayer *root = w.contentView.backingView.layer;
    if (!root) continue;
    eachLayer(root, ^(CALayer *l) {
      // AKOpenGL's (the game's OpenGL frames while the HUD is up) has its settings from AKOpenGL.
      if (![l isKindOfClass:CAMetalLayer.class] || [l.name isEqualToString:@"AKOpenGL"]) return;
      AKLayerState *state = layerState(l);
      state->game = state->configured = YES;
      applyHUD((CAMetalLayer *)l, props);
    });
  }
}

#pragma mark Frame rate limit

// A game taking its next drawable sooner than its limit allows waits (asleep) until its time.
// Pacing the drawable is how the game's whole loop slows, as gamescope's limit does on the Deck.
static void pace(AKLayerState *pacer, int fps) {
  static mach_timebase_info_data_t tb;
  if (!tb.denom) mach_timebase_info(&tb);
  uint64_t period = (uint64_t)(1e9 / fps) * tb.denom / tb.numer;
  uint64_t now = mach_absolute_time();
  if (pacer->next > now && pacer->next - now <= period) mach_wait_until(pacer->next);
  // On cadence from the last frame's slot, unless the game fell behind (then from now).
  uint64_t base = pacer->next > now ? pacer->next : now;
  pacer->next = base + period;
}

// Every Metal layer's drawables come through here. Before its first frame a layer gets its HUD
// setting: the HUD is enabled for the whole app (host/main.m), so a layer nobody set would show it.
// A game's gets the overlay level's; any other (Steam's, the system's) has it hidden, unless its
// owner set one already (AKOpenGL does for the game's OpenGL frames).
static id (*realNextDrawable)(id, SEL);
static id pacedNextDrawable(CAMetalLayer *self, SEL _cmd) {
  AKLayerState *state = layerState(self);
  if (!state->game && AKGameIsRunning() && AKAddressIsInGame(__builtin_return_address(0))) state->game = YES;
  if (!state->configured) {
    state->configured = YES;
    if (@available(iOS 16.0, *)) {
      if (state->game) applyHUD(self, AKGameHUDProperties());
      else if (!self.developerHUDProperties.count) self.developerHUDProperties = @{ @"mode": @"disabled", @"logging": @"disabled" };
    }
  }
  int fps = __atomic_load_n(&gFrameLimit, __ATOMIC_RELAXED);
  if (fps > 0 && state->game && AKGameIsRunning()) pace(state, fps);
  return realNextDrawable(self, _cmd);
}

int AKGameFrameLimit(void) { return __atomic_load_n(&gFrameLimit, __ATOMIC_RELAXED); }

#pragma mark Applying

void AKGameGLOptionsChanged(void);   // NSOpenGL.m: AKOpenGL picks up the limit, scale and HUD

static void applyRunning(void) {
  [lock() lock];
  load();
  NSDictionary *p = profile(activeProfileID());
  int level = intValue(gSettings[@"global"][@"perf_overlay_level"], kOverlayHidden);
  int fps = MAX(0, intValue(p[@"fps_limit"], 0));
  BOOL running = gGameID != nil;
  [lock() unlock];
  __atomic_store_n(&gOverlayLevel, level, __ATOMIC_RELAXED);
  __atomic_store_n(&gFrameLimit, running ? fps : 0, __ATOMIC_RELAXED);
  dispatch_async(dispatch_get_main_queue(), ^{
    applyToGameLayers();
    AKGameGLOptionsChanged();
  });
}

void AKWHPerfStateChanged(void);   // WebHelperDeck.m: Steam's page gets the new state

static void changed(void) {
  applyRunning();
  dispatch_async(dispatch_get_main_queue(), ^{ AKWHPerfStateChanged(); });
}

// The class's own method replaced, or one added that calls its superclass's (CAMetalLayer
// inherits -init from CALayer, whose own must stay as it is for every other layer).
static IMP replaceOwnMethod(Class cls, SEL sel, IMP imp) {
  Method m = class_getInstanceMethod(cls, sel);
  if (!m) return NULL;
  IMP original = method_getImplementation(m);
  if (!class_addMethod(cls, sel, imp, method_getTypeEncoding(m))) method_setImplementation(m, imp);
  return original;
}

__attribute__((constructor)) static void installHooks(void) {
  realNextDrawable = (id (*)(id, SEL))replaceOwnMethod(CAMetalLayer.class, @selector(nextDrawable), (IMP)pacedNextDrawable);
}

#pragma mark The running game

// A game starts (before its program loads): its profile sets the resolution it will measure.
void AKGameProfileBegin(NSString *gameID) {
  [lock() lock];
  load();
  gGameID = gameID.length && ![gameID isEqualToString:@"0"] ? [gameID copy] : nil;
  gGameDraws = nil;
  NSDictionary *p = profile(activeProfileID());
  gRenderFraction = fraction(p[@"render_scale"]);
  BOOL own = ![activeProfileID() isEqualToString:AKDefaultProfileID];
  int fps = intValue(p[@"fps_limit"], 0), level = intValue(gSettings[@"global"][@"perf_overlay_level"], 0);
  [lock() unlock];
  fprintf(stderr, "[AppKitShim] game: its settings are %s profile's: frame limit %d, resolution %.0f%%, overlay level %d\n",
          own ? "its own" : "the default", fps, gRenderFraction * 100, level);
  changed();
  // Layers a game makes later (a window, a resize) get the HUD as they come.
  static dispatch_source_t timer;
  if (!timer) {
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(timer, ^{ if (hudShown() || __atomic_load_n(&gFrameLimit, __ATOMIC_RELAXED)) applyToGameLayers(); });
    dispatch_resume(timer);
  }
}

void AKGameProfileEnd(void) {
  [lock() lock];
  gGameID = nil;
  gGameDraws = nil;
  gRenderFraction = 1;
  [lock() unlock];
  changed();
}

void AKGameProfileNoteDraws(NSString *how) {
  [lock() lock];
  BOOL news = gGameID && ![gGameDraws isEqualToString:how];
  if (news) gGameDraws = [how copy];
  [lock() unlock];
  if (news) dispatch_async(dispatch_get_main_queue(), ^{ AKWHPerfStateChanged(); });
}

double AKGameRenderFraction(void) { return gRenderFraction; }
BOOL AKGameHUDShown(void) { return hudShown(); }

#pragma mark Steam's Performance tab

// The state as CMsgSystemPerfState (field names as Steam's code has them; WebHelperDeck.js
// encodes it), with the app's own settings for the active profile beside it.
NSDictionary *AKPerfState(void) {
  [lock() lock];
  load();
  NSString *active = activeProfileID();
  NSDictionary *p = profile(active);
  NSDictionary *global = gSettings[@"global"];
  int fps = MAX(0, intValue(p[@"fps_limit"], 0));
  NSDictionary *message = @{
    @"current_game_id": gGameID ?: AKDefaultProfileID,
    @"active_profile_game_id": active,
    @"limits": @{
      @"fps_limit_options": frameLimitOptions(),
      @"fps_limit_options_external": frameLimitOptions(),
      @"perf_overlay_is_standalone": @NO,
      @"disable_refresh_rate_management": @NO,
      @"is_manual_display_refresh_rate_available": @NO,
      @"is_vrr_supported": @NO,
      @"is_dynamic_refresh_rate_in_steam_supported": @NO,
      @"fsr_sharpness_min": @0,
      @"fsr_sharpness_max": @20,
    },
    @"settings": @{
      @"global": @{
        @"perf_overlay_service_state": @2,   // running
        @"perf_overlay_level": @(intValue(global[@"perf_overlay_level"], kOverlayHidden)),
        @"is_advanced_settings_enabled": @([global[@"is_advanced_settings_enabled"] boolValue]),
        @"is_show_perf_overlay_over_steam_enabled": @NO,
      },
      @"per_app": @{
        @"fps_limit": @(fps),
        @"fps_limit_external": @(fps),
        @"is_fps_limit_enabled": @(fps > 0),
        @"is_game_perf_profile_enabled": @(![active isEqualToString:AKDefaultProfileID]),
      },
    },
  };
  NSDictionary *state = @{
    @"message": message,
    @"app": @{
      @"render_scale": @(fraction(p[@"render_scale"])),
      @"game_draws": gGameDraws ?: @"",
      @"game_running": @(gGameID != nil),
      @"launch_render_scale": @(gRenderFraction),
    },
  };
  [lock() unlock];
  return state;
}

// CMsgSystemPerfUpdateSettings, decoded by WebHelperDeck.js: { gameid, reset_to_default,
// settings_delta: { global: {...}, per_app: {...} } }.
NSDictionary *AKPerfUpdate(NSDictionary *update) {
  [lock() lock];
  load();
  NSString *gameID = [update[@"gameid"] isKindOfClass:NSString.class] && [update[@"gameid"] length] ? update[@"gameid"] : activeProfileID();
  NSDictionary *delta = [update[@"settings_delta"] isKindOfClass:NSDictionary.class] ? update[@"settings_delta"] : @{};
  NSDictionary *global = [delta[@"global"] isKindOfClass:NSDictionary.class] ? delta[@"global"] : nil;
  NSDictionary *perApp = [delta[@"per_app"] isKindOfClass:NSDictionary.class] ? delta[@"per_app"] : nil;
  NSMutableOrderedSet *perGame = gSettings[@"perGame"];
  if ([update[@"reset_to_default"] boolValue]) {
    NSMutableDictionary *p = profile(gameID);
    [p removeAllObjects];
    [p addEntriesFromDictionary:defaultPerApp()];
  }
  for (NSString *key in @[ @"perf_overlay_level", @"is_advanced_settings_enabled" ])
    if (global[key]) gSettings[@"global"][key] = global[key];
  if (perApp[@"is_game_perf_profile_enabled"] && ![gameID isEqualToString:AKDefaultProfileID]) {
    if ([perApp[@"is_game_perf_profile_enabled"] boolValue]) {
      // A game's own profile starts as a copy of the settings it was using, as on the Deck.
      if (!gSettings[@"profiles"][gameID]) gSettings[@"profiles"][gameID] = [profile(AKDefaultProfileID) mutableCopy];
      [perGame addObject:gameID];
    } else {
      [perGame removeObject:gameID];
    }
  }
  id fps = perApp[@"fps_limit"] ?: perApp[@"fps_limit_external"];
  if ([fps isKindOfClass:NSNumber.class]) profile(gameID)[@"fps_limit"] = @(MAX(0, [fps intValue]));
  save();
  [lock() unlock];
  fprintf(stderr, "[AppKitShim] performance settings changed (%s profile)\n",
          [gameID isEqualToString:AKDefaultProfileID] ? "default" : gameID.UTF8String);
  changed();
  return AKPerfState();
}

// The app's own rows on the tab: a setting of the active profile.
NSDictionary *AKPerfSetAppSetting(NSString *key, id value) {
  [lock() lock];
  load();
  if ([key isEqualToString:@"render_scale"] && [value isKindOfClass:NSNumber.class]) {
    profile(activeProfileID())[@"render_scale"] = @(fraction(value));
    save();
  }
  [lock() unlock];
  changed();
  return AKPerfState();
}
