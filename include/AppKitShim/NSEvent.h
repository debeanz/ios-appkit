// NSEvent — input events. The shim builds these from UIKit touches, key commands and
// game-controller input, and from synthetic events the client posts itself. Only the
// members Steam/CEF actually read are modelled.
#import <Foundation/Foundation.h>
#import "NSGeometry.h"

@class NSWindow;

typedef NS_ENUM(NSUInteger, NSEventType) {
  NSEventTypeLeftMouseDown = 1, NSEventTypeLeftMouseUp = 2,
  NSEventTypeRightMouseDown = 3, NSEventTypeRightMouseUp = 4,
  NSEventTypeMouseMoved = 5, NSEventTypeLeftMouseDragged = 6, NSEventTypeRightMouseDragged = 7,
  NSEventTypeKeyDown = 10, NSEventTypeKeyUp = 11, NSEventTypeFlagsChanged = 12,
  NSEventTypeScrollWheel = 22, NSEventTypeApplicationDefined = 15,
};

typedef NS_OPTIONS(NSUInteger, NSEventModifierFlags) {
  NSEventModifierFlagCapsLock = 1 << 16,
  NSEventModifierFlagShift    = 1 << 17,
  NSEventModifierFlagControl  = 1 << 18,
  NSEventModifierFlagOption   = 1 << 19,
  NSEventModifierFlagCommand  = 1 << 20,
  NSEventModifierFlagFunction = 1 << 23,
};

#define NSAnyEventMask NSUIntegerMax

@interface NSEvent : NSObject
@property (nonatomic, readonly) NSEventType type;
@property (nonatomic, readonly) NSEventModifierFlags modifierFlags;
@property (nonatomic, readonly) NSTimeInterval timestamp;
@property (nonatomic, readonly, weak) NSWindow *window;
@property (nonatomic, readonly) NSPoint locationInWindow;
@property (nonatomic, readonly) NSInteger buttonNumber;
@property (nonatomic, readonly) NSInteger clickCount;
@property (nonatomic, readonly) CGFloat deltaX;
@property (nonatomic, readonly) CGFloat deltaY;
@property (nonatomic, readonly) unsigned short keyCode;
@property (nonatomic, readonly, copy) NSString *characters;
@property (nonatomic, readonly, copy) NSString *charactersIgnoringModifiers;
@property (nonatomic, readonly) short subtype;
@property (nonatomic, readonly) NSInteger data1;
@property (nonatomic, readonly) NSInteger data2;

+ (NSEvent *)otherEventWithType:(NSEventType)type
                       location:(NSPoint)location
                  modifierFlags:(NSEventModifierFlags)flags
                      timestamp:(NSTimeInterval)time
                   windowNumber:(NSInteger)wn
                        context:(id)context
                        subtype:(short)subtype
                          data1:(NSInteger)d1
                          data2:(NSInteger)d2;
+ (NSEventModifierFlags)modifierFlags;
+ (NSPoint)mouseLocation;
@end
