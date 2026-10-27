// NSScreen — wraps UIScreen. Steam reads frame, backingScaleFactor and visibleFrame to
// size Big Picture. On iOS there is one screen and no menu bar, so visibleFrame is the
// safe-area-inset frame.
#import <Foundation/Foundation.h>
#import "NSGeometry.h"

@interface NSScreen : NSObject
@property (class, readonly, copy) NSArray<NSScreen *> *screens;
@property (class, readonly, nullable, strong) NSScreen *mainScreen;
@property (nonatomic, readonly) NSRect frame;
@property (nonatomic, readonly) NSRect visibleFrame;
@property (nonatomic, readonly) CGFloat backingScaleFactor;
@end
