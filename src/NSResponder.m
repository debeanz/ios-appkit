#import "AKShimPrivate.h"

// Each event handler forwards to the next responder by default, so an unhandled event
// walks the chain and falls off the end at -noResponderFor:, matching AppKit.
@implementation NSResponder

- (BOOL)acceptsFirstResponder { return NO; }
- (BOOL)becomeFirstResponder  { return YES; }
- (BOOL)resignFirstResponder  { return YES; }

#define FORWARD(sel) \
  if (_nextResponder) [_nextResponder sel:event]; else [self noResponderFor:@selector(sel:)];

- (void)mouseDown:(NSEvent *)event         { FORWARD(mouseDown) }
- (void)mouseUp:(NSEvent *)event           { FORWARD(mouseUp) }
- (void)mouseDragged:(NSEvent *)event      { FORWARD(mouseDragged) }
- (void)mouseMoved:(NSEvent *)event        { FORWARD(mouseMoved) }
- (void)mouseEntered:(NSEvent *)event      { FORWARD(mouseEntered) }
- (void)mouseExited:(NSEvent *)event       { FORWARD(mouseExited) }
- (void)rightMouseDown:(NSEvent *)event    { FORWARD(rightMouseDown) }
- (void)rightMouseUp:(NSEvent *)event      { FORWARD(rightMouseUp) }
- (void)rightMouseDragged:(NSEvent *)event { FORWARD(rightMouseDragged) }
- (void)otherMouseDown:(NSEvent *)event    { FORWARD(otherMouseDown) }
- (void)otherMouseUp:(NSEvent *)event      { FORWARD(otherMouseUp) }
- (void)otherMouseDragged:(NSEvent *)event { FORWARD(otherMouseDragged) }
- (void)scrollWheel:(NSEvent *)event       { FORWARD(scrollWheel) }
- (void)keyDown:(NSEvent *)event           { FORWARD(keyDown) }
- (void)keyUp:(NSEvent *)event             { FORWARD(keyUp) }
- (void)flagsChanged:(NSEvent *)event      { FORWARD(flagsChanged) }

#undef FORWARD

// Without an input context, translate each key directly: editing keys become commands,
// everything else is inserted as text. NSView overrides this to use its NSTextInputContext.
- (void)interpretKeyEvents:(NSArray<NSEvent *> *)events {
  for (NSEvent *e in events) {
    if (e.type != NSEventTypeKeyDown) continue;
    SEL cmd = AKCommandSelectorForKeyEvent(e);
    if (cmd) [self doCommandBySelector:cmd];
    else if (e.characters.length) [self insertText:e.characters];
  }
}

- (BOOL)performKeyEquivalent:(NSEvent *)event { return NO; }

- (BOOL)tryToPerform:(SEL)action with:(id)object {
  for (NSResponder *r = self; r; r = r.nextResponder) {
    if ([r respondsToSelector:action]) {
      ((void (*)(id, SEL, id))[r methodForSelector:action])(r, action, object);
      return YES;
    }
  }
  return NO;
}

- (void)doCommandBySelector:(SEL)selector {
  if (![self tryToPerform:selector with:nil]) [self noResponderFor:selector];
}

- (void)insertText:(id)string {
  if (_nextResponder) [_nextResponder insertText:string];
}

- (void)noResponderFor:(SEL)selector {
  // End of the chain. AppKit beeps for key events; we stay silent and drop it.
}

// Covers NSWindow and NSView (and client subclasses such as SDL3Window/SDL3View): a method
// the shim lacks is logged and returns zero instead of aborting. See AKShimPrivate.h.
AK_UNIMPLEMENTED_FORWARDER

@end
