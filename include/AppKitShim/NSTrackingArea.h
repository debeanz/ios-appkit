// NSTrackingArea — a region of a view that wants pointer enter/exit/move events.
// NSWindow's hover dispatch reads these (see -[NSWindow sendEvent:]).
#import <Foundation/Foundation.h>
#import "NSGeometry.h"

typedef NS_OPTIONS(NSUInteger, NSTrackingAreaOptions) {
  NSTrackingMouseEnteredAndExited     = 0x01,
  NSTrackingMouseMoved                = 0x02,
  NSTrackingCursorUpdate              = 0x04,
  NSTrackingActiveWhenFirstResponder  = 0x10,
  NSTrackingActiveInKeyWindow         = 0x20,
  NSTrackingActiveInActiveApp         = 0x40,
  NSTrackingActiveAlways              = 0x80,
  NSTrackingAssumeInside              = 0x100,
  NSTrackingInVisibleRect             = 0x200,
  NSTrackingEnabledDuringMouseDrag    = 0x400,
};

@interface NSTrackingArea : NSObject
- (instancetype)initWithRect:(NSRect)rect
                     options:(NSTrackingAreaOptions)options
                       owner:(id)owner
                    userInfo:(NSDictionary *)userInfo;
@property (nonatomic, readonly) NSRect rect;
@property (nonatomic, readonly) NSTrackingAreaOptions options;
@property (nonatomic, readonly, weak) id owner;
@property (nonatomic, readonly, copy) NSDictionary *userInfo;
@end
