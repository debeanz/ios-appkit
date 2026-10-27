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
- (void)rightMouseDown:(NSEvent *)event;
- (void)rightMouseUp:(NSEvent *)event;
- (void)scrollWheel:(NSEvent *)event;
- (void)keyDown:(NSEvent *)event;
- (void)keyUp:(NSEvent *)event;
- (void)flagsChanged:(NSEvent *)event;
- (void)doCommandBySelector:(SEL)selector;
- (void)insertText:(id)string;
- (void)noResponderFor:(SEL)selector;
@end
