#import "AppKitShim/NSCursor.h"
#import "AKShimPrivate.h"

NSNotificationName const AKShimCursorDidChangeNotification = @"AKShimCursorDidChangeNotification";

static NSCursor *gCurrent;
static NSMutableArray<NSCursor *> *gStack;
static BOOL gHidden;

@interface NSCursor ()
- (instancetype)initWithSystemName:(NSString *)name;
@end

@implementation NSCursor

- (instancetype)initWithImage:(id)image hotSpot:(NSPoint)hotSpot {
  if ((self = [super init])) { _image = image; _hotSpot = hotSpot; }
  return self;
}

- (instancetype)initWithSystemName:(NSString *)name {
  if ((self = [super init])) _systemName = [name copy];
  return self;
}

// One shared instance per system cursor, so callers can compare cursors by identity.
static NSCursor *AKSystemCursor(NSString *name) {
  static NSMutableDictionary<NSString *, NSCursor *> *cursors;
  @synchronized (NSCursor.class) {
    if (!cursors) cursors = [NSMutableDictionary dictionary];
    return cursors[name] ?: (cursors[name] = [[NSCursor alloc] initWithSystemName:name]);
  }
}

+ (NSCursor *)arrowCursor                  { return AKSystemCursor(@"arrow"); }
+ (NSCursor *)IBeamCursor                  { return AKSystemCursor(@"IBeam"); }
+ (NSCursor *)IBeamCursorForVerticalLayout { return AKSystemCursor(@"IBeamVertical"); }
+ (NSCursor *)pointingHandCursor           { return AKSystemCursor(@"pointingHand"); }
+ (NSCursor *)closedHandCursor             { return AKSystemCursor(@"closedHand"); }
+ (NSCursor *)openHandCursor               { return AKSystemCursor(@"openHand"); }
+ (NSCursor *)crosshairCursor              { return AKSystemCursor(@"crosshair"); }
+ (NSCursor *)resizeLeftCursor             { return AKSystemCursor(@"resizeLeft"); }
+ (NSCursor *)resizeRightCursor            { return AKSystemCursor(@"resizeRight"); }
+ (NSCursor *)resizeLeftRightCursor        { return AKSystemCursor(@"resizeLeftRight"); }
+ (NSCursor *)resizeUpCursor               { return AKSystemCursor(@"resizeUp"); }
+ (NSCursor *)resizeDownCursor             { return AKSystemCursor(@"resizeDown"); }
+ (NSCursor *)resizeUpDownCursor           { return AKSystemCursor(@"resizeUpDown"); }
+ (NSCursor *)operationNotAllowedCursor    { return AKSystemCursor(@"operationNotAllowed"); }
+ (NSCursor *)dragLinkCursor               { return AKSystemCursor(@"dragLink"); }
+ (NSCursor *)dragCopyCursor               { return AKSystemCursor(@"dragCopy"); }
+ (NSCursor *)contextualMenuCursor         { return AKSystemCursor(@"contextualMenu"); }
+ (NSCursor *)disappearingItemCursor       { return AKSystemCursor(@"disappearingItem"); }

+ (NSCursor *)currentCursor       { return gCurrent ?: self.arrowCursor; }
+ (NSCursor *)currentSystemCursor { return self.currentCursor; }

+ (void)hide { gHidden = YES; }
+ (void)unhide { gHidden = NO; }
+ (void)setHiddenUntilMouseMoves:(BOOL)flag { /* no persistent cursor to hide */ }

- (void)set {
  if (gCurrent == self) return;
  gCurrent = self;
  [NSNotificationCenter.defaultCenter postNotificationName:AKShimCursorDidChangeNotification object:self];
}

- (void)push {
  if (!gStack) gStack = [NSMutableArray array];
  [gStack addObject:NSCursor.currentCursor];
  [self set];
}

- (void)pop { [NSCursor pop]; }

+ (void)pop {
  NSCursor *previous = gStack.lastObject;
  if (!previous) return;
  [gStack removeLastObject];
  [previous set];
}

AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER

@end
