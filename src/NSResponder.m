#import "AppKitShim/NSResponder.h"
#import "AppKitShim/NSEvent.h"

// Each event handler forwards to the next responder by default, so an unhandled event
// walks the chain and falls off the end at -noResponderFor:, matching AppKit.
@implementation NSResponder

- (BOOL)acceptsFirstResponder { return NO; }
- (BOOL)becomeFirstResponder  { return YES; }
- (BOOL)resignFirstResponder  { return YES; }

#define FORWARD(sel) \
  if (_nextResponder) [_nextResponder sel:event]; else [self noResponderFor:@selector(sel:)];

- (void)mouseDown:(NSEvent *)event       { FORWARD(mouseDown) }
- (void)mouseUp:(NSEvent *)event         { FORWARD(mouseUp) }
- (void)mouseDragged:(NSEvent *)event    { FORWARD(mouseDragged) }
- (void)rightMouseDown:(NSEvent *)event  { FORWARD(rightMouseDown) }
- (void)rightMouseUp:(NSEvent *)event    { FORWARD(rightMouseUp) }
- (void)scrollWheel:(NSEvent *)event     { FORWARD(scrollWheel) }
- (void)keyDown:(NSEvent *)event         { FORWARD(keyDown) }
- (void)keyUp:(NSEvent *)event           { FORWARD(keyUp) }
- (void)flagsChanged:(NSEvent *)event    { FORWARD(flagsChanged) }

#undef FORWARD

- (void)doCommandBySelector:(SEL)selector {
  if (_nextResponder) [_nextResponder doCommandBySelector:selector];
  else [self noResponderFor:selector];
}

- (void)insertText:(id)string {
  if (_nextResponder) [_nextResponder insertText:string];
}

- (void)noResponderFor:(SEL)selector {
  // End of the chain. AppKit beeps for key events; we stay silent and drop it.
}

@end
