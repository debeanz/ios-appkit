// NSCursor — Chromium changes the cursor on every hover. iPhones have no cursor, so the
// shim records the current one (and posts AKShimCursorDidChangeNotification) without
// drawing anything; an iPad pointer-shape hook can listen for that later.
#import <Foundation/Foundation.h>
#import "NSGeometry.h"

extern NSNotificationName const AKShimCursorDidChangeNotification;

@interface NSCursor : NSObject
- (instancetype)initWithImage:(id)image hotSpot:(NSPoint)hotSpot;
@property (nonatomic, readonly, strong) id image;
@property (nonatomic, readonly) NSPoint hotSpot;
// Which system cursor this is ("arrow", "IBeam", ...), or nil for a custom image.
@property (nonatomic, readonly, copy) NSString *systemName;

@property (class, readonly, strong) NSCursor *currentCursor;
@property (class, readonly, strong) NSCursor *currentSystemCursor;
@property (class, readonly, strong) NSCursor *arrowCursor;
@property (class, readonly, strong) NSCursor *IBeamCursor;
@property (class, readonly, strong) NSCursor *IBeamCursorForVerticalLayout;
@property (class, readonly, strong) NSCursor *pointingHandCursor;
@property (class, readonly, strong) NSCursor *closedHandCursor;
@property (class, readonly, strong) NSCursor *openHandCursor;
@property (class, readonly, strong) NSCursor *crosshairCursor;
@property (class, readonly, strong) NSCursor *resizeLeftCursor;
@property (class, readonly, strong) NSCursor *resizeRightCursor;
@property (class, readonly, strong) NSCursor *resizeLeftRightCursor;
@property (class, readonly, strong) NSCursor *resizeUpCursor;
@property (class, readonly, strong) NSCursor *resizeDownCursor;
@property (class, readonly, strong) NSCursor *resizeUpDownCursor;
@property (class, readonly, strong) NSCursor *operationNotAllowedCursor;
@property (class, readonly, strong) NSCursor *dragLinkCursor;
@property (class, readonly, strong) NSCursor *dragCopyCursor;
@property (class, readonly, strong) NSCursor *contextualMenuCursor;
@property (class, readonly, strong) NSCursor *disappearingItemCursor;

+ (void)hide;
+ (void)unhide;
+ (void)setHiddenUntilMouseMoves:(BOOL)flag;
+ (void)pop;

- (void)set;
- (void)push;
- (void)pop;
@end
