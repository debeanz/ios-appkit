// NSScreen — wraps UIScreen. Steam reads frame, backingScaleFactor and visibleFrame to
// size Big Picture, and Chromium finds the matching CGDirectDisplayID through
// deviceDescription[@"NSScreenNumber"]. On iOS there is no menu bar, so visibleFrame is
// the safe-area-inset frame.
#import <Foundation/Foundation.h>
#import "NSGeometry.h"

@class NSColorSpace;

extern NSNotificationName const NSScreenColorSpaceDidChangeNotification;

@interface NSScreen : NSObject
@property (class, readonly, copy) NSArray<NSScreen *> *screens;
@property (class, readonly, strong) NSScreen *mainScreen;
@property (nonatomic, readonly) NSRect frame;
@property (nonatomic, readonly) NSRect visibleFrame;
@property (class, readonly, strong) NSScreen *deepestScreen;
@property (nonatomic, readonly) CGFloat backingScaleFactor;
@property (nonatomic, readonly) NSInteger maximumFramesPerSecond;
@property (nonatomic, readonly) NSTimeInterval minimumRefreshInterval, maximumRefreshInterval;
@property (nonatomic, readonly) NSTimeInterval displayUpdateGranularity, lastDisplayUpdateTimestamp;
// No notch: zero insets and no areas beside one.
@property (nonatomic, readonly) NSEdgeInsets safeAreaInsets;
@property (nonatomic, readonly) NSRect auxiliaryTopLeftArea, auxiliaryTopRightArea;
@property (nonatomic, readonly) int depth;
@property (nonatomic, readonly) NSColorSpace *colorSpace;
- (BOOL)canRepresentDisplayGamut:(NSInteger)displayGamut;
@property (nonatomic, readonly) const int *supportedWindowDepths;
- (NSRect)convertRectToBacking:(NSRect)rect;
- (NSRect)convertRectFromBacking:(NSRect)rect;
- (NSRect)backingAlignedRect:(NSRect)rect options:(unsigned long long)options;
@property (nonatomic, readonly, copy) NSString *localizedName;
// NSScreenNumber (the CGDirectDisplayID), NSDeviceSize and NSDeviceResolution, as on the Mac.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *deviceDescription;
@end
