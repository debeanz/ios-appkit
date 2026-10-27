#import "AKShimPrivate.h"

static NSPoint gMouseLocation;
static NSEventModifierFlags gModifierFlags;

@implementation NSEvent {
  NSEventType _type;
  NSEventModifierFlags _flags;
  NSTimeInterval _timestamp;
  NSPoint _location;
  NSInteger _buttonNumber, _clickCount, _data1, _data2;
  CGFloat _deltaX, _deltaY;
  unsigned short _keyCode;
  BOOL _repeat;
  NSString *_characters, *_charactersIgnoringModifiers;
  short _subtype;
  __weak NSWindow *_eventWindow;
  __weak NSView *_target;
}

@synthesize type = _type, modifierFlags = _flags, timestamp = _timestamp;
@synthesize locationInWindow = _location, buttonNumber = _buttonNumber, clickCount = _clickCount;
@synthesize deltaX = _deltaX, deltaY = _deltaY, keyCode = _keyCode, ARepeat = _repeat;
@synthesize characters = _characters, charactersIgnoringModifiers = _charactersIgnoringModifiers;
@synthesize subtype = _subtype, data1 = _data1, data2 = _data2;

- (NSWindow *)window { return _eventWindow; }
- (NSInteger)windowNumber { return _eventWindow.windowNumber; }
- (NSView *)_targetView { return _target; }

// Scrolling deltas come from a trackpad pan, which is continuous, so report them as precise.
- (CGFloat)scrollingDeltaX { return _deltaX; }
- (CGFloat)scrollingDeltaY { return _deltaY; }
- (BOOL)hasPreciseScrollingDeltas { return _type == NSEventTypeScrollWheel; }

static NSEvent *AKMakeEvent(NSEventType type, NSPoint location, NSEventModifierFlags flags,
                            NSTimeInterval time, NSInteger windowNumber) {
  NSEvent *e = [[NSEvent alloc] init];
  e->_type = type;
  e->_location = location;
  e->_flags = flags;
  e->_timestamp = time > 0 ? time : NSProcessInfo.processInfo.systemUptime;
  e->_eventWindow = windowNumber > 0 ? [NSApp windowWithWindowNumber:windowNumber] : nil;
  return e;
}

+ (NSEvent *)otherEventWithType:(NSEventType)type
                       location:(NSPoint)location
                  modifierFlags:(NSEventModifierFlags)flags
                      timestamp:(NSTimeInterval)time
                   windowNumber:(NSInteger)wn
                        context:(id)context
                        subtype:(short)subtype
                          data1:(NSInteger)d1
                          data2:(NSInteger)d2 {
  NSEvent *e = AKMakeEvent(type, location, flags, time, wn);
  e->_subtype = subtype;
  e->_data1 = d1;
  e->_data2 = d2;
  return e;
}

+ (NSEvent *)keyEventWithType:(NSEventType)type
                     location:(NSPoint)location
                modifierFlags:(NSEventModifierFlags)flags
                    timestamp:(NSTimeInterval)time
                 windowNumber:(NSInteger)wn
                      context:(id)context
                   characters:(NSString *)keys
  charactersIgnoringModifiers:(NSString *)ukeys
                    isARepeat:(BOOL)repeat
                      keyCode:(unsigned short)code {
  NSEvent *e = AKMakeEvent(type, location, flags, time, wn);
  e->_characters = [keys copy];
  e->_charactersIgnoringModifiers = [ukeys copy];
  e->_repeat = repeat;
  e->_keyCode = code;
  return e;
}

+ (NSEvent *)mouseEventWithType:(NSEventType)type
                       location:(NSPoint)location
                  modifierFlags:(NSEventModifierFlags)flags
                      timestamp:(NSTimeInterval)time
                   windowNumber:(NSInteger)wn
                        context:(id)context
                    eventNumber:(NSInteger)eventNumber
                     clickCount:(NSInteger)clickCount
                       pressure:(float)pressure {
  NSEvent *e = AKMakeEvent(type, location, flags, time, wn);
  e->_clickCount = clickCount;
  switch (type) {
    case NSEventTypeRightMouseDown: case NSEventTypeRightMouseUp: case NSEventTypeRightMouseDragged:
      e->_buttonNumber = 1; break;
    case NSEventTypeOtherMouseDown: case NSEventTypeOtherMouseUp: case NSEventTypeOtherMouseDragged:
      e->_buttonNumber = 2; break;
    default: e->_buttonNumber = 0; break;
  }
  return e;
}

- (void)_setWindow:(NSWindow *)window targetView:(NSView *)view {
  _eventWindow = window;
  _target = view;
}

- (void)_setDeltaX:(CGFloat)dx deltaY:(CGFloat)dy {
  _deltaX = dx;
  _deltaY = dy;
}

+ (NSEventModifierFlags)modifierFlags { return gModifierFlags; }
+ (void)_setModifierFlags:(NSEventModifierFlags)flags { gModifierFlags = flags; }

// iOS has no persistent cursor; the input bridge records the last touch or pointer position.
+ (NSPoint)mouseLocation { return gMouseLocation; }
+ (void)_setMouseLocation:(NSPoint)location { gMouseLocation = location; }

@end
