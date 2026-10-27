// Smoke test: construct the core objects through the shim's public headers, link against
// libAppKitShim + real UIKit, and push events through the same path real input takes.
// It does not put anything on screen; that needs a hosted simulator app.
#import "AppKitShim/AppKit.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

unsigned short AKMacKeyCodeForHIDUsage(long usage); // private, in KeyCodes.m
BOOL AKCarbonDispatchHotKey(unsigned short keyCode, NSEventModifierFlags flags, BOOL down); // private, in Carbon.m

static int gCarbonTrace;
static UInt32 gHotKeyFired;
static OSStatus AKTestInner(EventHandlerCallRef call, EventRef event, void *ud) { gCarbonTrace += 1; return noErr; }
static OSStatus AKTestOuter(EventHandlerCallRef call, EventRef event, void *ud) {
  gCarbonTrace += 10;
  return CallNextEventHandler(call, event); // newest handler runs first, then passes it on
}
static OSStatus AKTestHotKey(EventHandlerCallRef call, EventRef event, void *ud) {
  EventHotKeyID hid;
  if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof hid, NULL, &hid) == noErr) gHotKeyFired = hid.id;
  return noErr;
}

static NSString *AKTranslate(const UCKeyboardLayout *layout, UInt16 key, UInt32 carbonModifiers, UInt16 action) {
  UniChar buf[4];
  UniCharCount n = 0;
  UInt32 dead = 0;
  UCKeyTranslate(layout, key, action, (carbonModifiers >> 8) & 0xFF, LMGetKbdType(), 0, &dead, 4, &n, buf);
  return [NSString stringWithCharacters:buf length:n];
}

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

@interface AKTestViewController : NSViewController
@property (nonatomic, assign) int loads;
@end
@implementation AKTestViewController
- (void)loadView { self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 50, 50)]; }
- (void)viewDidLoad { _loads++; }
@end

@interface AKTestTableSource : NSObject
@property (nonatomic, assign) NSInteger rows;
@end
@implementation AKTestTableSource
- (NSInteger)numberOfRowsInTableView:(id)tableView { return _rows; }
@end

@interface AKTestMenuTarget : NSObject
@property (nonatomic, assign) int copies;
@end
@implementation AKTestMenuTarget
- (void)ak_copy:(id)sender { _copies++; }
@end

// Records the override points Chromium's view relies on.
@interface AKTestLayerView : NSView
@property (nonatomic, assign) int movedToWindow;
@property (nonatomic, assign) NSSize lastSize;
@end
@implementation AKTestLayerView
- (void)viewDidMoveToWindow { _movedToWindow++; }
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; _lastSize = size; }
@end

static int gDisplayLinkTicks;
static CVReturn AKTestDisplayLinkCallback(CVDisplayLinkRef link, const CVTimeStamp *now, const CVTimeStamp *out,
                                          CVOptionFlags flagsIn, CVOptionFlags *flagsOut, void *ctx) {
  __atomic_add_fetch(&gDisplayLinkTicks, 1, __ATOMIC_RELAXED);
  return kCVReturnSuccess;
}

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

    // Views: window moves, frame-size overrides, layer hosting.
    AKTestLayerView *lv = [[AKTestLayerView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
    [content addSubview:lv];
    CHECK(lv.movedToWindow == 1, "viewDidMoveToWindow fires when a view joins a window");
    [lv setFrame:NSMakeRect(0, 0, 200, 150)];
    CHECK(NSEqualSizes(lv.lastSize, NSMakeSize(200, 150)), "setFrame: goes through setFrameSize:");
    lv.wantsLayer = YES;
    CALayer *hosted = lv.layer;
    CHECK(hosted && hosted != lv.backingView.layer, "the client's layer is not UIKit's own layer");
    CHECK(hosted.superlayer.geometryFlipped, "client layers sit under a macOS-orientation container");
    CHECK(CGSizeEqualToSize(hosted.bounds.size, CGSizeMake(200, 150)), "hosted layer fills the view");
    CHECK(NSEqualSizes([lv convertSizeToBacking:NSMakeSize(10, 10)],
                       NSMakeSize(10 * win.backingScaleFactor, 10 * win.backingScaleFactor)), "backing conversion");
    CHECK(win.styleMask & NSWindowStyleMaskFullScreen, "windows report full screen");

    // Displays: CoreGraphics and NSScreen agree on display 1.
    CHECK(CGMainDisplayID() == 1, "main display is 1");
    uint32_t displays = 0;
    CHECK(CGGetActiveDisplayList(0, NULL, &displays) == kCGErrorSuccess && displays >= 1, "at least one display");
    CHECK(CGDisplayPixelsWide(1) > 0 && CGDisplayPixelsHigh(1) > 0, "display has a size");
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(1);
    CHECK(mode && CGDisplayModeGetRefreshRate(mode) > 0, "display mode has a refresh rate");
    CHECK(CGDisplayModeGetPixelWidth(mode) >= CGDisplayModeGetWidth(mode), "pixels >= points");
    CGDisplayModeRelease(mode);
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(1, NULL);
    CHECK(modes && CFArrayGetCount(modes) == 1, "one mode per iOS screen");
    CFRelease(modes);
    CHECK([NSScreen.mainScreen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == CGMainDisplayID(),
          "NSScreenNumber matches the CoreGraphics display ID");

    // CVDisplayLink: create, start, stop. Ticks need a live display, which a command-line
    // simulator process may not get, so they are reported rather than required.
    CVDisplayLinkRef link = NULL;
    CHECK(CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess && link, "display link created");
    CHECK(CVDisplayLinkStart(link) != kCVReturnSuccess, "display link refuses to start without a callback");
    CVDisplayLinkSetOutputCallback(link, AKTestDisplayLinkCallback, NULL);
    CHECK(CVDisplayLinkStart(link) == kCVReturnSuccess && CVDisplayLinkIsRunning(link), "display link running");
    CVTime period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link);
    CHECK(period.timeValue == 1 && period.timeScale >= 30, "nominal refresh period is one frame");
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    fprintf(stderr, "smoke: display link ticked %d times in 0.5s\n", __atomic_load_n(&gDisplayLinkTicks, __ATOMIC_RELAXED));
    CVDisplayLinkStop(link);
    CHECK(!CVDisplayLinkIsRunning(link), "display link stopped");
    CVDisplayLinkRelease(link);

    // Carbon events: handler chaining, the event queue, hotkeys.
    EventTypeSpec testType = { 'test', 1 };
    InstallEventHandler(GetApplicationEventTarget(), AKTestInner, 1, &testType, NULL, NULL);
    EventHandlerRef outer = NULL;
    InstallEventHandler(GetApplicationEventTarget(), AKTestOuter, 1, &testType, NULL, &outer);
    EventRef ev = NULL;
    CreateEvent(NULL, 'test', 1, 0, 0, &ev);
    CHECK(SendEventToEventTargetWithOptions(ev, GetApplicationEventTarget(), 0) == noErr && gCarbonTrace == 11,
          "Carbon handlers run newest first and chain with CallNextEventHandler");
    RemoveEventHandler(outer);
    PostEventToQueue(GetMainEventQueue(), ev, kEventPriorityStandard);
    EventRef got = NULL;
    CHECK(ReceiveNextEvent(1, &testType, 0, true, &got) == noErr && got == ev, "Carbon event queue round-trip");
    ReleaseEvent(got);
    ReleaseEvent(ev);

    EventTypeSpec hotType = { kEventClassKeyboard, kEventHotKeyPressed };
    InstallEventHandler(GetApplicationEventTarget(), AKTestHotKey, 1, &hotType, NULL, NULL);
    EventHotKeyRef hotKey = NULL;
    CHECK(RegisterEventHotKey(0x31, cmdKey | shiftKey, (EventHotKeyID){ 'stem', 7 }, GetApplicationEventTarget(), 0, &hotKey) == noErr,
          "hotkey registered");
    CHECK(AKCarbonDispatchHotKey(0x31, NSEventModifierFlagCommand | NSEventModifierFlagShift, YES) && gHotKeyFired == 7,
          "Cmd+Shift+Space fires the registered hotkey");
    CHECK(!AKCarbonDispatchHotKey(0x31, NSEventModifierFlagCommand, YES), "a different combination does not");
    UnregisterEventHotKey(hotKey);

    // Keyboard layout: the US 'uchr' from Text Input Sources, read by UCKeyTranslate.
    TISInputSourceRef source = TISCopyCurrentKeyboardLayoutInputSource();
    CFDataRef layoutData = (CFDataRef)TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData);
    CHECK(layoutData != NULL, "the input source has layout data");
    const UCKeyboardLayout *layout = (const UCKeyboardLayout *)CFDataGetBytePtr(layoutData);
    CHECK([AKTranslate(layout, 0x00, 0, kUCKeyActionDown) isEqualToString:@"a"], "A key -> a");
    CHECK([AKTranslate(layout, 0x00, shiftKey, kUCKeyActionDown) isEqualToString:@"A"], "Shift+A -> A");
    CHECK([AKTranslate(layout, 0x12, shiftKey, kUCKeyActionDown) isEqualToString:@"!"], "Shift+1 -> !");
    CHECK([AKTranslate(layout, 0x12, alphaLock, kUCKeyActionDown) isEqualToString:@"1"], "Caps Lock leaves digits alone");
    CHECK([AKTranslate(layout, 0x24, 0, kUCKeyActionDown) isEqualToString:@"\r"], "Return -> CR");
    CHECK([AKTranslate(layout, 0x00, 0, kUCKeyActionUp) length] == 0, "key up types nothing");
    NSString *sourceID = (__bridge NSString *)TISGetInputSourceProperty(source, kTISPropertyInputSourceID);
    CHECK([sourceID isEqualToString:@"com.apple.keylayout.US"], "US input source");
    CFRelease(source);
    CHECK(KBGetLayoutType(LMGetKbdType()) == kKeyboardANSI, "ANSI keyboard");

    // AppKit constants carry AppKit's values.
    CHECK([NSAccessibilityButtonRole isEqualToString:@"AXButton"], "accessibility role value");
    CHECK([NSAccessibilityValueChangedNotification isEqualToString:@"AXValueChanged"], "accessibility notification value");
    CHECK([NSAccessibilityLineForIndexParameterizedAttribute isEqualToString:@"AXLineForIndex"], "parameterized attribute value");
    CHECK(NSFontWeightBold == 0.4 && NSFontWeightRegular == 0, "font weights");
    CHECK(NSFontIdentityMatrix[0] == 1 && NSFontIdentityMatrix[3] == 1 && NSFontIdentityMatrix[1] == 0, "identity text matrix");
    CHECK([NSAccessibilityRoleDescription(NSAccessibilityPopUpButtonRole, nil) isEqualToString:@"pop up button"], "role description");

    // Kill ring: consecutive kills join, a new sequence starts a new entry.
    _NSInitializeKillRing();
    _NSNewKillRingSequence();
    _NSAppendToKillRing(@"foo");
    _NSAppendToKillRing(@"bar");
    CHECK([_NSYankFromKillRing() isEqualToString:@"foobar"], "consecutive kills join");
    _NSNewKillRingSequence();
    _NSAppendToKillRing(@"baz");
    CHECK([_NSYankFromKillRing() isEqualToString:@"baz"], "a new kill sequence starts a new entry");

    // This process is the one running application.
    NSRunningApplication *me = NSRunningApplication.currentApplication;
    CHECK(me.processIdentifier == getpid(), "current application is this process");
    CHECK(NSWorkspace.sharedWorkspace.frontmostApplication == me, "frontmost application is this one");
    CHECK([NSRunningApplication runningApplicationWithProcessIdentifier:getpid()] == me, "lookup by pid");
    CHECK([NSRunningApplication runningApplicationWithProcessIdentifier:1] == nil, "other processes are not visible");

    // UIKit's lifecycle arrives under AppKit's names.
    __block BOOL becameActive = NO;
    id token = [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidBecomeActiveNotification object:nil
                                                                queue:nil usingBlock:^(NSNotification *n) { becameActive = YES; }];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    CHECK(becameActive, "UIApplicationDidBecomeActive is re-posted as NSApplicationDidBecomeActive");
    [NSNotificationCenter.defaultCenter removeObserver:token];

    // Graphics: color space, bezier path, an image round-tripped through PNG.
    CHECK(NSColorSpace.sRGBColorSpace.colorSpaceModel == NSColorSpaceModelRGB, "sRGB is an RGB space");
    CHECK(NSColorSpace.sRGBColorSpace.numberOfColorComponents == 3, "RGB has 3 components");
    NSBezierPath *path = [NSBezierPath bezierPathWithRect:NSMakeRect(0, 0, 10, 20)];
    CHECK(!path.isEmpty && NSEqualSizes(path.bounds.size, NSMakeSize(10, 20)), "bezier path bounds");
    CHECK([path containsPoint:NSMakePoint(5, 5)] && ![path containsPoint:NSMakePoint(50, 50)], "bezier containsPoint");

    unsigned char px[4 * 2 * 2] = {255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,0,255};
    unsigned char *planes = px;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:&planes pixelsWide:2 pixelsHigh:2
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bitmapFormat:0 bytesPerRow:8 bitsPerPixel:32];
    CHECK(rep.CGImage && CGImageGetWidth(rep.CGImage) == 2, "bitmap rep builds a 2x2 CGImage");
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    CHECK(png.length > 8 && ((const uint8_t *)png.bytes)[1] == 'P', "encodes PNG");
    NSImage *decoded = [[NSImage alloc] initWithData:png];
    CHECK(decoded.isValid && NSEqualSizes(decoded.size, NSMakeSize(2, 2)), "decodes the PNG back to a 2x2 image");

    NSImage *drawn = [NSImage imageWithSize:NSMakeSize(4, 4) flipped:NO drawingHandler:^BOOL(NSRect r) {
      [[NSColor redColor] set];
      NSRectFill(r);
      return YES;
    }];
    CHECK([drawn CGImageForProposedRect:NULL context:nil hints:nil] != NULL, "drawingHandler produces an image");

    // Appearance follows light/dark and resolves a best match.
    NSAppearance *dark = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    NSArray *choices = @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ];
    CHECK([[dark bestMatchFromAppearancesWithNames:choices] isEqualToString:NSAppearanceNameDarkAqua],
          "dark appearance picks the dark match");

    // Controls: value lives in the cell; actions reach an explicit target.
    AKTestMenuTarget *clickTarget = [AKTestMenuTarget new];
    NSButton *button = [NSButton buttonWithTitle:@"Go" target:clickTarget action:@selector(ak_copy:)];
    CHECK([button.title isEqualToString:@"Go"], "button title");
    [button performClick:nil];
    CHECK(clickTarget.copies == 1, "performClick sends the action to the target");
    NSTextField *field2 = [NSTextField textFieldWithString:@"hello"];
    field2.integerValue = 42;
    CHECK(field2.integerValue == 42 && [field2.stringValue isEqualToString:@"42"], "control value round-trips through the cell");

    // NSAnimation: a zero-duration animation completes immediately and applies its curve.
    NSAnimation *anim = [[NSAnimation alloc] initWithDuration:0 animationCurve:NSAnimationLinear];
    [anim startAnimation];
    CHECK(anim.currentProgress == 1.0 && !anim.isAnimating, "zero-duration animation finishes at once");
    NSAnimation *eased = [[NSAnimation alloc] initWithDuration:1 animationCurve:NSAnimationEaseIn];
    eased.currentProgress = 0.5;
    CHECK(eased.currentValue == 0.25, "ease-in curve maps 0.5 -> 0.25");

    // NSAlert builds its buttons with AppKit's return codes (presenting UI needs a device).
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Title";
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    CHECK(alert.buttons.count == 2 && alert.buttons[0].tag == NSAlertFirstButtonReturn, "alert buttons numbered from NSAlertFirstButtonReturn");

    // NSSavePanel resolves to a real URL under the app's Documents directory.
    NSSavePanel *save = [NSSavePanel savePanel];
    save.nameFieldStringValue = @"save.txt";
    CHECK([save runModal] == NSModalResponseOK && [save.URL.lastPathComponent isEqualToString:@"save.txt"], "save panel yields a Documents URL");

    // Controllers: the view loads once, through -loadView, on first access.
    AKTestViewController *vc = [AKTestViewController new];
    CHECK(!vc.isViewLoaded, "view not loaded before first access");
    (void)vc.view; (void)vc.view;
    CHECK(vc.isViewLoaded && vc.loads == 1 && NSEqualSizes(vc.view.frame.size, NSMakeSize(50, 50)), "loadView + viewDidLoad run once");
    NSWindowController *wc = [[NSWindowController alloc] initWithWindow:win];
    CHECK(wc.window == win && wc.isWindowLoaded, "window controller holds its window");

    // Fonts, answered from the system's font list.
    NSFontManager *fm = NSFontManager.sharedFontManager;
    CHECK(fm.availableFontFamilies.count > 0 && fm.availableFonts.count > 0, "font families listed");
    UIFont *courierBold = [fm fontWithFamily:@"Courier" traits:NSBoldFontMask weight:5 size:12];
    CHECK(courierBold && ([fm traitsOfFont:courierBold] & NSBoldFontMask), "bold Courier found");
    CHECK([fm traitsOfFont:courierBold] & NSFixedPitchFontMask, "Courier is fixed pitch");
    CHECK([fm fontWithFamily:@"No Such Family" traits:0 weight:5 size:12] == nil, "unknown family -> nil");
    CHECK(llabs((long long)[fm weightOfFont:[UIFont systemFontOfSize:12]] - 5) <= 1, "regular weight is about 5");

    // Spelling, when the simulator has dictionaries installed.
    NSSpellChecker *spell = NSSpellChecker.sharedSpellChecker;
    if (spell.availableLanguages.count) {
      NSRange bad = [spell checkSpellingOfString:@"helo world" startingAt:0];
      CHECK(bad.location == 0 && bad.length == 4, "'helo' is flagged");
      CHECK([spell guessesForWordRange:bad inString:@"helo world" language:nil inSpellDocumentWithTag:0].count > 0, "guesses offered");
      NSInteger doc = NSSpellChecker.uniqueSpellDocumentTag;
      [spell ignoreWord:@"helo" inSpellDocumentWithTag:doc];
      NSRange ignored = [spell checkSpellingOfString:@"helo world" startingAt:0 language:nil wrap:NO inSpellDocumentWithTag:doc wordCount:NULL];
      CHECK(ignored.location == NSNotFound, "ignored word is skipped in that document");
      [spell closeSpellDocumentWithTag:doc];
    } else {
      fprintf(stderr, "smoke: no spelling dictionaries on this simulator; spell checks skipped\n");
    }

    // Speech, toolbar, status bar, printing defaults.
    NSSpeechSynthesizer *speech = [[NSSpeechSynthesizer alloc] initWithVoice:nil];
    CHECK(speech.rate == 180 && !speech.isSpeaking, "speech defaults to 180 wpm, idle");
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"main"];
    [toolbar insertItemWithItemIdentifier:@"a" atIndex:0];
    [toolbar insertItemWithItemIdentifier:@"b" atIndex:0];
    CHECK([toolbar.items isEqualToArray:(@[ @"b", @"a" ])], "toolbar items keep their order");
    CHECK(NSStatusBar.systemStatusBar.thickness == 0, "no menu bar");
    NSPrintInfo *pi = NSPrintInfo.sharedPrintInfo;
    CHECK(NSEqualSizes(pi.paperSize, NSMakeSize(612, 792)) && pi.leftMargin == 72, "US Letter with AppKit margins");
    CHECK([NSPrintPanel.printPanel runModal] == NSModalResponseCancel, "print panel cancels without a document");

    // Widgets keep working models.
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 100, 24) pullsDown:NO];
    [popup addItemsWithTitles:@[ @"Low", @"Medium", @"High" ]];
    CHECK(popup.indexOfSelectedItem == 0 && [popup.title isEqualToString:@"Low"], "first pop-up item starts selected");
    [popup selectItemWithTitle:@"High"];
    CHECK(popup.indexOfSelectedItem == 2 && [popup.titleOfSelectedItem isEqualToString:@"High"], "select by title");
    CHECK([popup itemAtIndex:2].state == NSControlStateValueOn && [popup itemAtIndex:0].state == NSControlStateValueOff, "selected item is checked");

    NSSegmentedControl *seg = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
    seg.segmentCount = 3;
    [seg setLabel:@"A" forSegment:0];
    seg.selectedSegment = 1;
    [seg setSelected:YES forSegment:2]; // select-one mode: clears segment 1
    CHECK(seg.selectedSegment == 2 && ![seg isSelectedForSegment:1] && [[seg labelForSegment:0] isEqualToString:@"A"], "segmented control selects one");

    NSComboBox *combo = [[NSComboBox alloc] initWithFrame:NSZeroRect];
    [combo addItemWithObjectValue:@"red"];
    [combo addItemWithObjectValue:@"blue"];
    [combo selectItemAtIndex:1];
    CHECK(combo.indexOfSelectedItem == 1 && [combo.stringValue isEqualToString:@"blue"], "combo box selection fills the field");

    NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
    NSTabViewItem *t1 = [[NSTabViewItem alloc] initWithIdentifier:@"one"], *t2 = [[NSTabViewItem alloc] initWithIdentifier:@"two"];
    t1.view = [[NSView alloc] initWithFrame:NSZeroRect];
    t2.view = [[NSView alloc] initWithFrame:NSZeroRect];
    [tabs addTabViewItem:t1];
    [tabs addTabViewItem:t2];
    CHECK(tabs.selectedTabViewItem == t1 && t1.view.superview == tabs, "first tab shown");
    [tabs selectTabViewItemAtIndex:1];
    CHECK(tabs.selectedTabViewItem == t2 && t2.view.superview == tabs && t1.view.superview == nil, "only the selected tab's view is in the tree");

    AKTestTableSource *tableSource = [AKTestTableSource new];
    tableSource.rows = 5;
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    table.dataSource = tableSource;
    [table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"name"]];
    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:4] byExtendingSelection:NO];
    CHECK(table.numberOfRows == 5 && table.selectedRow == 4 && [table tableColumnWithIdentifier:@"name"], "table rows come from the data source");
    tableSource.rows = 3;
    [table reloadData];
    CHECK(table.selectedRow == -1, "reload drops rows that no longer exist from the selection");

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
    scroll.documentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, 400)];
    [scroll scrollToPoint:NSMakePoint(0, 1000)];
    CHECK(NSMinY(scroll.documentVisibleRect) == 300, "scrolling clamps to the document's end");

    NSText *text = [[NSText alloc] initWithFrame:NSZeroRect];
    text.string = @"Hello";
    [text replaceCharactersInRange:NSMakeRange(5, 0) withString:@" world"];
    CHECK([text.string isEqualToString:@"Hello world"] && text.selectedRange.location == 11, "NSText edits and moves the caret");

    NSProgressIndicator *progress = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    progress.doubleValue = 150;
    CHECK(progress.doubleValue == 100, "progress clamps to maxValue");
    CHECK([[NSOpenGLPixelFormat alloc] initWithAttributes:NULL] == nil, "no desktop OpenGL: pixel format is nil, as AppKit reports when unsupported");

    // Quartz events: key codes translate through the US layout with the event's modifiers.
    CGEventRef keyA = CGEventCreateKeyboardEvent(NULL, 0x00, true);
    UniChar chars[4];
    UniCharCount nChars = 0;
    CGEventKeyboardGetUnicodeString(keyA, 4, &nChars, chars);
    CHECK(nChars == 1 && chars[0] == 'a' && CGEventGetType(keyA) == kCGEventKeyDown, "CGEvent key A types 'a'");
    CGEventSetFlags(keyA, (CGEventFlags)NSEventModifierFlagShift);
    CGEventKeyboardGetUnicodeString(keyA, 4, &nChars, chars);
    CHECK(nChars == 1 && chars[0] == 'A', "with Shift it types 'A'");
    CFDataRef blob = CGEventCreateData(NULL, keyA);
    CGEventRef copied = CGEventCreateFromData(NULL, blob);
    CHECK(copied && CGEventGetIntegerValueField(copied, kCGKeyboardEventKeycode) == 0x00 &&
          CGEventGetFlags(copied) == (CGEventFlags)NSEventModifierFlagShift, "CGEvent survives serialization");
    CFRelease(blob); CFRelease(copied); CFRelease(keyA);

    // Input state comes from the events NSApp delivered.
    uint32_t keyDownsBefore = CGEventSourceCounterForEventType(kCGEventSourceStateCombinedSessionState, kCGEventKeyDown);
    [app sendEvent:KeyDown(win, @"q", 0x0C, 0)];
    CHECK(CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, 0x0C), "Q is held after its key down");
    CHECK(CGEventSourceCounterForEventType(kCGEventSourceStateCombinedSessionState, kCGEventKeyDown) == keyDownsBefore + 1, "key-down counter advances");
    CHECK(CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, kCGEventKeyDown) < 5, "last key down was just now");
    [app sendEvent:[NSEvent keyEventWithType:NSEventTypeKeyUp location:NSZeroPoint modifierFlags:0 timestamp:0
                                windowNumber:win.windowNumber context:nil characters:@"q" charactersIgnoringModifiers:@"q"
                                   isARepeat:NO keyCode:0x0C]];
    CHECK(!CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, 0x0C), "Q released after its key up");

    // CGEventPost delivers into this app: a posted Z types into the focused field.
    [win makeKeyWindow];
    CGEventRef keyZ = CGEventCreateKeyboardEvent(NULL, 0x06, true);
    CGEventPost(kCGHIDEventTap, keyZ);
    CFRelease(keyZ);
    CHECK([field.typed hasSuffix:@"z"], "posted key event reaches the focused text field");

    // Windows: only this app's, with Quartz's dictionary keys.
    NSArray *infos = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    BOOL listed = NO;
    for (NSDictionary *info in infos)
      if ([info[(__bridge NSString *)kCGWindowNumber] integerValue] == win.windowNumber &&
          [info[(__bridge NSString *)kCGWindowOwnerPID] intValue] == getpid()) listed = YES;
    CHECK(listed, "window list includes this app's window");
    CHECK(CGWindowLevelForKey(kCGNormalWindowLevelKey) == 0 && CGWindowLevelForKey(kCGFloatingWindowLevelKey) == 3, "window levels");

    // Capture and system-wide taps are unavailable, through the API's own failure values.
    CHECK(CGEventTapCreate(kCGSessionEventTap, 0, 0, ~0ULL, NULL, NULL) == NULL, "no event taps");
    CHECK(CGDisplayStreamCreate(1, 100, 100, 0, NULL, nil) == NULL && CGDisplayCreateImage(1) == NULL, "no screen capture");
    CGDisplayFadeReservationToken fadeToken = 1;
    CHECK(CGAcquireDisplayFadeReservation(1, &fadeToken) != kCGErrorSuccess && fadeToken == 0, "no display fades");

    // Apple Event descriptors build and read back (nothing is dispatched on iOS).
    NSAppleEventDescriptor *list = [NSAppleEventDescriptor listDescriptor];
    [list insertDescriptor:[NSAppleEventDescriptor descriptorWithString:@"one"] atIndex:0];
    [list insertDescriptor:[NSAppleEventDescriptor descriptorWithInt32:42] atIndex:0];
    CHECK(list.numberOfItems == 2, "list descriptor holds its items");
    CHECK([[list descriptorAtIndex:1].stringValue isEqualToString:@"one"] && [list descriptorAtIndex:2].int32Value == 42, "descriptor values read back");
    CHECK([NSAppleEventManager.sharedAppleEventManager currentAppleEvent] == nil, "no Apple Event is current on iOS");

    // Odds and ends.
    NSColor *c = [NSColor colorWithRed:1 green:0 blue:0 alpha:1];
    CHECK(c.CGColor != NULL, "color has a CGColor");
    (void)NSScreen.mainScreen.backingScaleFactor;
    NSBeep();

    fprintf(stderr, "smoke: ok (NSAppKitVersionNumber=%.1f)\n", NSAppKitVersionNumber);
    return 0;
  }
}
