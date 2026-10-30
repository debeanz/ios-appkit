#import "AppKitShim/NSTrackingArea.h"
#import "AKShimPrivate.h"

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

// Nothing of it changes once made: a copy is itself, as for AppKit's own (NSCopying).
- (id)copyWithZone:(NSZone *)zone { return self; }

AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end
