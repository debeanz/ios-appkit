// NSMenu / NSMenuItem — the client builds a main menu and context menus. iOS has no menu
// bar and Big Picture draws its own menus, so the shim keeps the full model (items,
// actions, key equivalents, submenus) without showing anything. Popping up a menu
// returns NO, which callers treat as "dismissed without a choice".
#import <Foundation/Foundation.h>
#import "NSGeometry.h"
#import "NSEvent.h"

@class NSMenu, NSView;

typedef NSInteger NSControlStateValue;
static const NSControlStateValue NSControlStateValueMixed = -1;
static const NSControlStateValue NSControlStateValueOff = 0;
static const NSControlStateValue NSControlStateValueOn = 1;

extern NSNotificationName const NSMenuDidBeginTrackingNotification;
extern NSNotificationName const NSMenuDidEndTrackingNotification;
extern NSNotificationName const NSMenuWillSendActionNotification;

@interface NSMenuItem : NSObject
+ (NSMenuItem *)separatorItem;
- (instancetype)initWithTitle:(NSString *)title action:(SEL)action keyEquivalent:(NSString *)keyEquivalent;

@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) SEL action;
@property (nonatomic, weak) id target;
@property (nonatomic, copy) NSString *keyEquivalent;
@property (nonatomic, assign) NSEventModifierFlags keyEquivalentModifierMask;
@property (nonatomic, assign) NSInteger tag;
@property (nonatomic, assign) NSControlStateValue state;
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;
@property (nonatomic, assign, getter=isHidden) BOOL hidden;
@property (nonatomic, strong) NSMenu *submenu;
@property (nonatomic, readonly, weak) NSMenu *menu;
@property (nonatomic, strong) id representedObject;
@property (nonatomic, strong) id image;
@property (nonatomic, copy) NSString *toolTip;
@property (nonatomic, readonly) BOOL hasSubmenu;
@property (nonatomic, readonly, getter=isSeparatorItem) BOOL separatorItem;
@end

@interface NSMenu : NSObject
- (instancetype)initWithTitle:(NSString *)title;

@property (nonatomic, copy) NSString *title;
@property (nonatomic, weak) id delegate;
@property (nonatomic, assign) BOOL autoenablesItems;
@property (nonatomic, readonly, copy) NSArray<NSMenuItem *> *itemArray;
@property (nonatomic, readonly) NSInteger numberOfItems;
@property (nonatomic, readonly, weak) NSMenu *supermenu;

- (void)addItem:(NSMenuItem *)item;
- (NSMenuItem *)addItemWithTitle:(NSString *)title action:(SEL)action keyEquivalent:(NSString *)keyEquivalent;
- (void)insertItem:(NSMenuItem *)item atIndex:(NSInteger)index;
- (void)removeItem:(NSMenuItem *)item;
- (void)removeItemAtIndex:(NSInteger)index;
- (void)removeAllItems;
- (NSMenuItem *)itemAtIndex:(NSInteger)index;
- (NSMenuItem *)itemWithTitle:(NSString *)title;
- (NSMenuItem *)itemWithTag:(NSInteger)tag;
- (NSInteger)indexOfItem:(NSMenuItem *)item;
- (void)setSubmenu:(NSMenu *)menu forItem:(NSMenuItem *)item;

// Finds an enabled item whose key equivalent matches the event and sends its action.
- (BOOL)performKeyEquivalent:(NSEvent *)event;

- (BOOL)popUpMenuPositioningItem:(NSMenuItem *)item atLocation:(NSPoint)location inView:(NSView *)view;
+ (void)popUpContextMenu:(NSMenu *)menu withEvent:(NSEvent *)event forView:(NSView *)view;
- (void)cancelTracking;
@end
