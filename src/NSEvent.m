#import "AppKitShim/NSEvent.h"
#import <UIKit/UIKit.h>

@implementation NSEvent {
  NSEventType _type;
  NSEventModifierFlags _flags;
  NSTimeInterval _timestamp;
  NSPoint _location;
  NSInteger _buttonNumber, _clickCount, _data1, _data2;
  CGFloat _deltaX, _deltaY;
  unsigned short _keyCode;
  NSString *_characters, *_charactersIgnoringModifiers;
  short _subtype;
}

@synthesize type = _type, modifierFlags = _flags, timestamp = _timestamp;
@synthesize locationInWindow = _location, buttonNumber = _buttonNumber, clickCount = _clickCount;
@synthesize deltaX = _deltaX, deltaY = _deltaY, keyCode = _keyCode;
@synthesize characters = _characters, charactersIgnoringModifiers = _charactersIgnoringModifiers;
@synthesize subtype = _subtype, data1 = _data1, data2 = _data2;

+ (NSEvent *)otherEventWithType:(NSEventType)type
                       location:(NSPoint)location
                  modifierFlags:(NSEventModifierFlags)flags
                      timestamp:(NSTimeInterval)time
                   windowNumber:(NSInteger)wn
                        context:(id)context
                        subtype:(short)subtype
                          data1:(NSInteger)d1
                          data2:(NSInteger)d2 {
  NSEvent *e = [[NSEvent alloc] init];
  e->_type = type;
  e->_location = location;
  e->_flags = flags;
  e->_timestamp = time;
  e->_subtype = subtype;
  e->_data1 = d1;
  e->_data2 = d2;
  return e;
}

// Factory used by the input bridge to turn UIKit input into AppKit events.
+ (NSEvent *)_eventWithType:(NSEventType)type
                   location:(NSPoint)location
                      flags:(NSEventModifierFlags)flags
                 characters:(NSString *)chars
                    keyCode:(unsigned short)keyCode {
  NSEvent *e = [[NSEvent alloc] init];
  e->_type = type;
  e->_location = location;
  e->_flags = flags;
  e->_characters = [chars copy];
  e->_charactersIgnoringModifiers = [chars copy];
  e->_keyCode = keyCode;
  e->_timestamp = NSProcessInfo.processInfo.systemUptime;
  e->_clickCount = 1;
  return e;
}

+ (NSEventModifierFlags)modifierFlags { return 0; }

+ (NSPoint)mouseLocation {
  // iOS has no persistent cursor; the input bridge updates this from the last touch.
  return NSZeroPoint;
}

@end
