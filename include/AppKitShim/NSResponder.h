// NSResponder — base of the event/responder chain. Mirrors the AppKit class so
// NSView, NSWindow and NSApplication can share nextResponder plumbing.
#import <Foundation/Foundation.h>
#import "NSGeometry.h"

@class NSEvent, NSMenu, NSUndoManager;

@interface NSResponder : NSObject
@property (nonatomic, assign) NSResponder *nextResponder;

- (BOOL)acceptsFirstResponder;
- (BOOL)becomeFirstResponder;
- (BOOL)resignFirstResponder;

// Default implementations forward to nextResponder, exactly as AppKit does, so an
// unhandled event walks the chain until something consumes it or it reaches nil.
- (void)mouseDown:(NSEvent *)event;
- (void)mouseUp:(NSEvent *)event;
- (void)mouseDragged:(NSEvent *)event;
- (void)mouseMoved:(NSEvent *)event;
- (void)mouseEntered:(NSEvent *)event;
- (void)mouseExited:(NSEvent *)event;
- (void)rightMouseDown:(NSEvent *)event;
- (void)rightMouseUp:(NSEvent *)event;
- (void)rightMouseDragged:(NSEvent *)event;
- (void)otherMouseDown:(NSEvent *)event;
- (void)otherMouseUp:(NSEvent *)event;
- (void)otherMouseDragged:(NSEvent *)event;
- (void)scrollWheel:(NSEvent *)event;
- (void)keyDown:(NSEvent *)event;
- (void)keyUp:(NSEvent *)event;
- (void)flagsChanged:(NSEvent *)event;

// Key events → text or editing commands. NSView routes this through its input context.
- (void)interpretKeyEvents:(NSArray<NSEvent *> *)events;
- (BOOL)performKeyEquivalent:(NSEvent *)event;

// Runs `selector` on the first responder in the chain that implements it.
- (BOOL)tryToPerform:(SEL)action with:(id)object;
- (void)doCommandBySelector:(SEL)selector;
- (void)insertText:(id)string;
- (void)noResponderFor:(SEL)selector;
@end
