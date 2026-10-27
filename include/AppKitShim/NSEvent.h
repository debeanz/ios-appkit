// NSEvent — input events. The shim builds these from UIKit touches, key presses and
// pointer input (see InputBridge.m), and the client can build its own with the AppKit
// factories below. Only the members Steam/CEF actually read are modelled.
//
// Coordinates: the shim uses top-left-origin window coordinates throughout, which is
// what a flipped NSView (Chromium's view is flipped) expects from -locationInWindow
// passed through -convertPoint:fromView:nil.
#import <Foundation/Foundation.h>
#import "NSGeometry.h"

@class NSWindow;

typedef NS_ENUM(NSUInteger, NSEventType) {
  NSEventTypeLeftMouseDown = 1, NSEventTypeLeftMouseUp = 2,
  NSEventTypeRightMouseDown = 3, NSEventTypeRightMouseUp = 4,
  NSEventTypeMouseMoved = 5, NSEventTypeLeftMouseDragged = 6, NSEventTypeRightMouseDragged = 7,
  NSEventTypeMouseEntered = 8, NSEventTypeMouseExited = 9,
  NSEventTypeKeyDown = 10, NSEventTypeKeyUp = 11, NSEventTypeFlagsChanged = 12,
  NSEventTypeApplicationDefined = 15,
  NSEventTypeScrollWheel = 22,
  NSEventTypeOtherMouseDown = 25, NSEventTypeOtherMouseUp = 26, NSEventTypeOtherMouseDragged = 27,
};

typedef NS_OPTIONS(unsigned long long, NSEventMask) {
  NSEventMaskLeftMouseDown = 1ULL << NSEventTypeLeftMouseDown,
  NSEventMaskLeftMouseUp = 1ULL << NSEventTypeLeftMouseUp,
  NSEventMaskRightMouseDown = 1ULL << NSEventTypeRightMouseDown,
  NSEventMaskRightMouseUp = 1ULL << NSEventTypeRightMouseUp,
  NSEventMaskMouseMoved = 1ULL << NSEventTypeMouseMoved,
  NSEventMaskLeftMouseDragged = 1ULL << NSEventTypeLeftMouseDragged,
  NSEventMaskKeyDown = 1ULL << NSEventTypeKeyDown,
  NSEventMaskKeyUp = 1ULL << NSEventTypeKeyUp,
  NSEventMaskFlagsChanged = 1ULL << NSEventTypeFlagsChanged,
  NSEventMaskApplicationDefined = 1ULL << NSEventTypeApplicationDefined,
  NSEventMaskScrollWheel = 1ULL << NSEventTypeScrollWheel,
  NSEventMaskAny = ~0ULL,
};

NS_INLINE NSEventMask NSEventMaskFromType(NSEventType type) { return 1ULL << type; }

typedef NS_OPTIONS(NSUInteger, NSEventModifierFlags) {
  NSEventModifierFlagCapsLock   = 1 << 16,
  NSEventModifierFlagShift      = 1 << 17,
  NSEventModifierFlagControl    = 1 << 18,
  NSEventModifierFlagOption     = 1 << 19,
  NSEventModifierFlagCommand    = 1 << 20,
  NSEventModifierFlagNumericPad = 1 << 21,
  NSEventModifierFlagFunction   = 1 << 23,
  NSEventModifierFlagDeviceIndependentFlagsMask = 0xffff0000UL,
};

#define NSAnyEventMask NSUIntegerMax

// AppKit's characters for keys that don't type text (NSEvent.characters on the Mac).
enum {
  NSUpArrowFunctionKey = 0xF700, NSDownArrowFunctionKey = 0xF701,
  NSLeftArrowFunctionKey = 0xF702, NSRightArrowFunctionKey = 0xF703,
  NSF1FunctionKey = 0xF704,
  NSDeleteFunctionKey = 0xF728, NSHomeFunctionKey = 0xF729, NSEndFunctionKey = 0xF72B,
  NSPageUpFunctionKey = 0xF72C, NSPageDownFunctionKey = 0xF72D,
};

@interface NSEvent : NSObject
@property (nonatomic, readonly) NSEventType type;
@property (nonatomic, readonly) NSEventModifierFlags modifierFlags;
@property (nonatomic, readonly) NSTimeInterval timestamp;
@property (nonatomic, readonly, weak) NSWindow *window;
@property (nonatomic, readonly) NSInteger windowNumber;
@property (nonatomic, readonly) NSPoint locationInWindow;
@property (nonatomic, readonly) NSInteger buttonNumber;
@property (nonatomic, readonly) NSInteger clickCount;
@property (nonatomic, readonly) CGFloat deltaX;
@property (nonatomic, readonly) CGFloat deltaY;
@property (nonatomic, readonly) CGFloat scrollingDeltaX;
@property (nonatomic, readonly) CGFloat scrollingDeltaY;
@property (nonatomic, readonly) BOOL hasPreciseScrollingDeltas;
@property (nonatomic, readonly) unsigned short keyCode;
@property (nonatomic, readonly, getter=isARepeat) BOOL ARepeat;
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

+ (NSEvent *)keyEventWithType:(NSEventType)type
                     location:(NSPoint)location
                modifierFlags:(NSEventModifierFlags)flags
                    timestamp:(NSTimeInterval)time
                 windowNumber:(NSInteger)wn
                      context:(id)context
                   characters:(NSString *)keys
  charactersIgnoringModifiers:(NSString *)ukeys
                    isARepeat:(BOOL)repeat
                      keyCode:(unsigned short)code;

+ (NSEvent *)mouseEventWithType:(NSEventType)type
                       location:(NSPoint)location
                  modifierFlags:(NSEventModifierFlags)flags
                      timestamp:(NSTimeInterval)time
                   windowNumber:(NSInteger)wn
                        context:(id)context
                    eventNumber:(NSInteger)eventNumber
                     clickCount:(NSInteger)clickCount
                       pressure:(float)pressure;

+ (NSEventModifierFlags)modifierFlags;
+ (NSPoint)mouseLocation;
@end
