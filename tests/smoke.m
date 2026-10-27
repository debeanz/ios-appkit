// Smoke test: construct the core objects through the shim's public headers, link against
// libAppKitShim + real UIKit, and push events through the same path real input takes.
// It does not put anything on screen; that needs a hosted simulator app.
#import "AppKitShim/AppKit.h"
#import <objc/runtime.h>

unsigned short AKMacKeyCodeForHIDUsage(long usage); // private, in KeyCodes.m

// Lists every Objective-C class this binary defines that some loaded system image also
// defines. Two classes with one name make the runtime pick either at random, so any hit
// here needs AK_SHIM_RUNTIME_NAME on its @interface.
static int AKCountClassCollisions(const char *ourImage) {
  unsigned int ourCount = 0;
  const char **ours = objc_copyClassNamesForImage(ourImage, &ourCount);
  NSMutableSet<NSString *> *ourNames = [NSMutableSet set];
  for (unsigned int i = 0; i < ourCount; i++) [ourNames addObject:@(ours[i])];
  free((void *)ours);

  int collisions = 0;
  unsigned int imageCount = 0;
  const char **images = objc_copyImageNames(&imageCount);
  for (unsigned int i = 0; i < imageCount; i++) {
    if (strcmp(images[i], ourImage) == 0) continue;
    unsigned int n = 0;
    const char **names = objc_copyClassNamesForImage(images[i], &n);
    for (unsigned int j = 0; j < n; j++) {
      if ([ourNames containsObject:@(names[j])]) {
        fprintf(stderr, "smoke: class collision: %s is also defined in %s\n", names[j], images[i]);
        collisions++;
      }
    }
    free((void *)names);
  }
  free((void *)images);
  return collisions;
}

#define CHECK(cond, msg) do { if (!(cond)) { fprintf(stderr, "smoke: FAIL %s (%s)\n", msg, #cond); return 1; } } while (0)

// A stand-in for Chromium's view: a text client that records what the shim delivers.
@interface AKTestTextView : NSView <NSTextInputClient>
@property (nonatomic, strong) NSMutableString *typed;
@property (nonatomic, strong) NSMutableArray<NSString *> *commands;
@end

@implementation AKTestTextView
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) { _typed = [NSMutableString string]; _commands = [NSMutableArray array]; }
  return self;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event { [self interpretKeyEvents:@[ event ]]; } // what Chromium does
- (void)insertText:(id)string replacementRange:(NSRange)range { [_typed appendString:string]; }
- (void)doCommandBySelector:(SEL)selector { [_commands addObject:NSStringFromSelector(selector)]; }
- (void)setMarkedText:(id)s selectedRange:(NSRange)sel replacementRange:(NSRange)rep {}
- (void)unmarkText {}
- (NSRange)selectedRange { return NSMakeRange(_typed.length, 0); }
- (NSRange)markedRange { return NSMakeRange(NSNotFound, 0); }
- (BOOL)hasMarkedText { return NO; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)r actualRange:(NSRangePointer)a { return nil; }
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }
- (NSRect)firstRectForCharacterRange:(NSRange)r actualRange:(NSRangePointer)a { return NSZeroRect; }
- (NSUInteger)characterIndexForPoint:(NSPoint)p { return 0; }
@end

@interface AKTestParentView : NSView
@property (nonatomic, assign) BOOL actionReached;
@end
@implementation AKTestParentView
- (void)ak_testAction:(id)sender { _actionReached = YES; }
@end

@interface AKTestMenuTarget : NSObject
@property (nonatomic, assign) int copies;
@end
@implementation AKTestMenuTarget
- (void)ak_copy:(id)sender { _copies++; }
@end

static NSEvent *KeyDown(NSWindow *w, NSString *chars, unsigned short code, NSEventModifierFlags flags) {
  return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0
                      windowNumber:w.windowNumber context:nil characters:chars
       charactersIgnoringModifiers:chars isARepeat:NO keyCode:code];
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    // Before anything else: no shim class may share a runtime name with a system class.
    CHECK(AKCountClassCollisions(class_getImageName(AKTestTextView.class)) == 0,
          "no shim class collides with a system class (see collisions above)");

    NSApplication *app = NSApplication.sharedApplication;
    CHECK(app == NSApp, "NSApp is the shared application");

    // Windows and views.
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 720)
                                                styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    CHECK([app windowWithWindowNumber:win.windowNumber] == win, "window registered with NSApp");
    AKTestParentView *content = [[AKTestParentView alloc] initWithFrame:NSMakeRect(0, 0, 1280, 720)];
    win.contentView = content;
    AKTestTextView *field = [[AKTestTextView alloc] initWithFrame:NSMakeRect(10, 10, 300, 40)];
    [content addSubview:field];
    CHECK(content.subviews.count == 1, "subview registered");
    CHECK(field.window == win, "view finds its window through the content view");
    CHECK(field.nextResponder == content && content.nextResponder == win, "responder chain is view -> superview -> window");

    // Event queue.
    NSEvent *custom = [NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSMakePoint(5, 5)
                                    modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0];
    [app postEvent:custom atStart:NO];
    CHECK([app nextEventMatchingMask:NSAnyEventMask untilDate:nil inMode:@"" dequeue:YES] == custom, "event queue round-trip");

    // Typing: NSApp -> window -> first responder -> input context -> text client.
    CHECK([win makeFirstResponder:field] && win.firstResponder == field, "text view takes focus");
    CHECK(field.inputContext != nil, "text client gets an input context");
    [app sendEvent:KeyDown(win, @"h", 0x04, 0)];
    [app sendEvent:KeyDown(win, @"i", 0x22, 0)];
    CHECK([field.typed isEqualToString:@"hi"], "typed text reaches the client");
    unichar del = 0x7F;
    [app sendEvent:KeyDown(win, [NSString stringWithCharacters:&del length:1], 0x33, 0)];
    CHECK([field.commands containsObject:@"deleteBackward:"], "Backspace becomes deleteBackward:");
    [app sendEvent:KeyDown(win, @"\r", 0x24, 0)];
    CHECK([field.commands containsObject:@"insertNewline:"], "Return becomes insertNewline:");

    // Actions climb the responder chain.
    CHECK([field tryToPerform:@selector(ak_testAction:) with:nil] && content.actionReached, "action reaches the superview");

    // Command shortcuts go through the main menu.
    AKTestMenuTarget *target = [AKTestMenuTarget new];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Main"];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    NSMenuItem *copy = [edit addItemWithTitle:@"Copy" action:@selector(ak_copy:) keyEquivalent:@"c"];
    copy.target = target;
    [menu addItemWithTitle:@"Edit" action:NULL keyEquivalent:@""].submenu = edit;
    app.mainMenu = menu;
    [app sendEvent:KeyDown(win, @"c", 0x08, NSEventModifierFlagCommand)];
    CHECK(target.copies == 1, "Cmd+C triggers the Copy menu item");
    CHECK(![field.typed containsString:@"c"], "a shortcut does not type text");

    // Cursor stack.
    [NSCursor.IBeamCursor push];
    CHECK(NSCursor.currentCursor == NSCursor.IBeamCursor, "push sets the cursor");
    [NSCursor pop];
    CHECK(NSCursor.currentCursor == NSCursor.arrowCursor, "pop restores the cursor");

    // Key codes: HID usages -> macOS virtual key codes.
    CHECK(AKMacKeyCodeForHIDUsage(0x04) == 0x00, "HID a -> kVK_ANSI_A");
    CHECK(AKMacKeyCodeForHIDUsage(0x28) == 0x24, "HID Return -> kVK_Return");
    CHECK(AKMacKeyCodeForHIDUsage(0x52) == 0x7E, "HID Up -> kVK_UpArrow");

    // Odds and ends.
    NSColor *c = [NSColor colorWithRed:1 green:0 blue:0 alpha:1];
    CHECK(c.CGColor != NULL, "color has a CGColor");
    (void)NSScreen.mainScreen.backingScaleFactor;
    NSBeep();

    fprintf(stderr, "smoke: ok (NSAppKitVersionNumber=%.1f)\n", NSAppKitVersionNumber);
    return 0;
  }
}
