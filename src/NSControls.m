#import "AKShimPrivate.h"
#import "AppKitShim/NSControls.h"

@implementation NSCell

- (instancetype)init { return [self initTextCell:@""]; }

- (instancetype)initTextCell:(NSString *)string {
  if ((self = [super init])) { _title = @""; _stringValue = [string copy] ?: @""; _enabled = YES; }
  return self;
}

- (id)copyWithZone:(NSZone *)zone {
  NSCell *c = [[self.class allocWithZone:zone] initTextCell:_stringValue];
  c.title = _title; c.state = _state; c.enabled = _enabled; c.tag = _tag;
  c.target = _target; c.action = _action; c.representedObject = _representedObject;
  return c;
}

- (NSInteger)integerValue { return _stringValue.integerValue; }
- (void)setIntegerValue:(NSInteger)v { self.stringValue = [NSString stringWithFormat:@"%ld", (long)v]; }


AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

// A control's value lives in its cell, as in AppKit.
@implementation NSControl

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) _cell = [NSCell new];
  return self;
}

- (NSString *)stringValue { return _cell.stringValue; }
- (void)setStringValue:(NSString *)s { _cell.stringValue = s ?: @""; }
- (NSInteger)integerValue { return _cell.integerValue; }
- (void)setIntegerValue:(NSInteger)v { _cell.integerValue = v; }
- (double)doubleValue { return _cell.stringValue.doubleValue; }
- (void)setDoubleValue:(double)v { _cell.stringValue = [NSString stringWithFormat:@"%g", v]; }
- (BOOL)isEnabled { return _cell.enabled; }
- (void)setEnabled:(BOOL)e { _cell.enabled = e; }
- (NSInteger)tag { return _cell.tag; }
- (void)setTag:(NSInteger)t { _cell.tag = t; }
- (id)target { return _cell.target; }
- (void)setTarget:(id)t { _cell.target = t; }
- (SEL)action { return _cell.action; }
- (void)setAction:(SEL)a { _cell.action = a; }

// An explicit target gets the action; otherwise it travels the responder chain.
- (BOOL)sendAction:(SEL)action to:(id)target {
  if (!action) return NO;
  if (target && [target respondsToSelector:action]) {
    ((void (*)(id, SEL, id))[target methodForSelector:action])(target, action, self);
    return YES;
  }
  NSResponder *start = self.window.firstResponder ?: (NSResponder *)self;
  return [start tryToPerform:action with:self] || [NSApp tryToPerform:action with:self];
}

- (void)sizeToFit {}

@end

@implementation NSButton

+ (instancetype)buttonWithTitle:(NSString *)title target:(id)target action:(SEL)action {
  NSButton *b = [[self alloc] initWithFrame:NSMakeRect(0, 0, 80, 32)];
  b.title = title;
  b.target = target;
  b.action = action;
  return b;
}

- (NSString *)title { return self.cell.title; }
- (void)setTitle:(NSString *)t { self.cell.title = t ?: @""; }
- (NSInteger)state { return self.cell.state; }
- (void)setState:(NSInteger)s { self.cell.state = s; }
- (void)setButtonType:(NSButtonType)type {}

- (void)performClick:(id)sender {
  if (!self.enabled) return;
  [self sendAction:self.action to:self.target];
}

@end

@implementation NSTextField

+ (instancetype)labelWithString:(NSString *)string {
  NSTextField *f = [[self alloc] initWithFrame:NSZeroRect];
  f.stringValue = string;
  f.editable = NO;
  f.selectable = NO;
  return f;
}

+ (instancetype)textFieldWithString:(NSString *)string {
  NSTextField *f = [[self alloc] initWithFrame:NSZeroRect];
  f.stringValue = string;
  f.editable = YES;
  f.selectable = YES;
  return f;
}

@end
