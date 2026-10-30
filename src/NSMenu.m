#import "AppKitShim/AppKit.h"
#import "AppKitShim/NSMenu.h"
#import "AKShimPrivate.h"

NSNotificationName const NSMenuDidBeginTrackingNotification = @"NSMenuDidBeginTrackingNotification";
NSNotificationName const NSMenuDidEndTrackingNotification = @"NSMenuDidEndTrackingNotification";
NSNotificationName const NSMenuWillSendActionNotification = @"NSMenuWillSendActionNotification";

@interface NSMenuItem ()
@property (nonatomic, weak, readwrite) NSMenu *menu;
@property (nonatomic, assign) BOOL isSeparator;
@end

@interface NSMenu ()
@property (nonatomic, weak, readwrite) NSMenu *supermenu;
@end

@implementation NSMenuItem

+ (NSMenuItem *)separatorItem {
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:NULL keyEquivalent:@""];
  item.isSeparator = YES;
  item.enabled = NO;
  return item;
}

- (instancetype)init { return [self initWithTitle:@"" action:NULL keyEquivalent:@""]; }

- (instancetype)initWithTitle:(NSString *)title action:(SEL)action keyEquivalent:(NSString *)keyEquivalent {
  if ((self = [super init])) {
    _title = [title copy] ?: @"";
    _action = action;
    _keyEquivalent = [keyEquivalent copy] ?: @"";
    _keyEquivalentModifierMask = NSEventModifierFlagCommand;
    _enabled = YES;
  }
  return self;
}

- (BOOL)isSeparatorItem { return _isSeparator; }
- (BOOL)hasSubmenu { return _submenu != nil; }

- (void)setSubmenu:(NSMenu *)submenu {
  _submenu = submenu;
  submenu.supermenu = self.menu;
}

AK_UNIMPLEMENTED_FORWARDER

@end

@implementation NSMenu {
  NSMutableArray<NSMenuItem *> *_items;
}

- (instancetype)init { return [self initWithTitle:@""]; }

- (instancetype)initWithTitle:(NSString *)title {
  if ((self = [super init])) {
    _title = [title copy] ?: @"";
    _autoenablesItems = YES;
    _items = [NSMutableArray array];
  }
  return self;
}

- (NSArray<NSMenuItem *> *)itemArray { return [_items copy]; }
- (NSInteger)numberOfItems { return (NSInteger)_items.count; }

- (void)addItem:(NSMenuItem *)item { [self insertItem:item atIndex:self.numberOfItems]; }

- (NSMenuItem *)addItemWithTitle:(NSString *)title action:(SEL)action keyEquivalent:(NSString *)keyEquivalent {
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:keyEquivalent];
  [self addItem:item];
  return item;
}

- (void)insertItem:(NSMenuItem *)item atIndex:(NSInteger)index {
  if (!item || item.menu) return; // AppKit refuses items that already belong to a menu
  item.menu = self;
  item.submenu.supermenu = self;
  [_items insertObject:item atIndex:(NSUInteger)MAX(0, MIN(index, self.numberOfItems))];
}

- (void)removeItem:(NSMenuItem *)item {
  if (item.menu != self) return;
  item.menu = nil;
  [_items removeObject:item];
}

- (void)removeItemAtIndex:(NSInteger)index { [self removeItem:[self itemAtIndex:index]]; }

- (void)removeAllItems {
  for (NSMenuItem *item in _items) item.menu = nil;
  [_items removeAllObjects];
}

- (NSMenuItem *)itemAtIndex:(NSInteger)index {
  return (index >= 0 && index < self.numberOfItems) ? _items[(NSUInteger)index] : nil;
}

- (NSMenuItem *)itemWithTitle:(NSString *)title {
  for (NSMenuItem *item in _items) if ([item.title isEqualToString:title]) return item;
  return nil;
}

- (NSMenuItem *)itemWithTag:(NSInteger)tag {
  for (NSMenuItem *item in _items) if (item.tag == tag) return item;
  return nil;
}

- (NSInteger)indexOfItem:(NSMenuItem *)item {
  NSUInteger i = [_items indexOfObjectIdenticalTo:item];
  return i == NSNotFound ? -1 : (NSInteger)i;
}

- (void)setSubmenu:(NSMenu *)menu forItem:(NSMenuItem *)item { item.submenu = menu; }

static const NSEventModifierFlags AKShortcutModifiers =
    NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl | NSEventModifierFlagShift;

- (BOOL)performKeyEquivalent:(NSEvent *)event {
  NSString *key = event.charactersIgnoringModifiers.lowercaseString;
  NSEventModifierFlags flags = event.modifierFlags & AKShortcutModifiers;
  for (NSMenuItem *item in _items) {
    if (item.submenu && [item.submenu performKeyEquivalent:event]) return YES;
    if (!item.enabled || item.keyEquivalent.length == 0 || !item.action) continue;
    if (![item.keyEquivalent.lowercaseString isEqualToString:key]) continue;
    if ((item.keyEquivalentModifierMask & AKShortcutModifiers) != flags) continue;

    [NSNotificationCenter.defaultCenter postNotificationName:NSMenuWillSendActionNotification
                                                      object:self userInfo:@{ @"MenuItem": item }];
    id target = item.target;
    if (target && [target respondsToSelector:item.action]) {
      ((void (*)(id, SEL, id))[target methodForSelector:item.action])(target, item.action, item);
      return YES;
    }
    // No explicit target: the action goes down the responder chain, as on the Mac.
    NSResponder *start = NSApp.keyWindow.firstResponder ?: (NSResponder *)NSApp.keyWindow;
    if ([start tryToPerform:item.action with:item] || [NSApp tryToPerform:item.action with:item]) return YES;
  }
  return NO;
}

- (BOOL)popUpMenuPositioningItem:(NSMenuItem *)item atLocation:(NSPoint)location inView:(NSView *)view {
  return NO;
}

+ (void)popUpContextMenu:(NSMenu *)menu withEvent:(NSEvent *)event forView:(NSView *)view {}

- (void)cancelTracking {}

// The Mac menu bar's visibility (SDL hides it for fullscreen). There is no menu bar on iOS;
// remember what was asked so the getter round-trips.
static BOOL gMenuBarVisible = YES;
+ (BOOL)menuBarVisible { return gMenuBarVisible; }
+ (void)setMenuBarVisible:(BOOL)visible { gMenuBarVisible = visible; }
// It takes no room: a game's window gets the whole screen (Unity and SDL subtract this).
+ (CGFloat)menuBarHeight { return 0; }
- (CGFloat)menuBarHeight { return 0; }

AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER

@end
