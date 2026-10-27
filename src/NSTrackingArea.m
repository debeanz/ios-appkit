#import "AppKitShim/NSTrackingArea.h"

@implementation NSTrackingArea

- (instancetype)initWithRect:(NSRect)rect
                     options:(NSTrackingAreaOptions)options
                       owner:(id)owner
                    userInfo:(NSDictionary *)userInfo {
  if ((self = [super init])) {
    _rect = rect;
    _options = options;
    _owner = owner;
    _userInfo = [userInfo copy];
  }
  return self;
}

@end
