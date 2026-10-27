// NSScreen — wraps UIScreen. Steam reads frame, backingScaleFactor and visibleFrame to
// size Big Picture, and Chromium finds the matching CGDirectDisplayID through
// deviceDescription[@"NSScreenNumber"]. On iOS there is no menu bar, so visibleFrame is
// the safe-area-inset frame.
#import <Foundation/Foundation.h>
#import "NSGeometry.h"

extern NSNotificationName const NSScreenColorSpaceDidChangeNotification;

@interface NSScreen : NSObject
@property (class, readonly, copy) NSArray<NSScreen *> *screens;
@property (class, readonly, strong) NSScreen *mainScreen;
@property (nonatomic, readonly) NSRect frame;
@property (nonatomic, readonly) NSRect visibleFrame;
@property (nonatomic, readonly) CGFloat backingScaleFactor;
@property (nonatomic, readonly) NSInteger maximumFramesPerSecond;
@property (nonatomic, readonly, copy) NSString *localizedName;
// NSScreenNumber (the CGDirectDisplayID), NSDeviceSize and NSDeviceResolution, as on the Mac.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *deviceDescription;
@end
