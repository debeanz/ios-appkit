// Hooks the shim's classes use to talk to each other. Not part of the public API.
#import "AppKitShim/AppKit.h"
#import <UIKit/UIKit.h>

// The UIView behind every NSView. Drawing lives in NSView.m; touch, keyboard and
// pointer input are added by a category in InputBridge.m.
@interface _AKShimBackingView : UIView
@property (nonatomic, weak) NSView *owner;
@end

@interface _AKShimBackingView (AKShimInput) <UIKeyInput>
- (void)_ak_installInputSupport;
@end

@interface NSColor (AKShimPrivate)
- (instancetype)initWithUIColor:(UIColor *)color;
@end

@interface NSView (AKShimPrivate)
- (void)_setOwningWindow:(NSWindow *)window;
- (void)_ak_backingDidLayout;
- (void)_ak_deliverEvent:(NSEvent *)event; // send via NSApp on the thread that owns this view
@end

// NSAlert.m: the view controller to present UIKit modals from, and a nested run loop that
// returns once `finished` reports YES (AppKit's -runModal works the same way).
UIViewController *AKTopViewController(void);
void AKRunModalUntil(BOOL (^finished)(void));

// CGEvents.m: records every event NSApp delivers (per-type times and counts, keys and
// buttons held, last mouse movement) for the CGEventSource state queries.
void AKNoteInputEvent(NSEvent *event);
uint32_t AKMouseButtonsDown(void);  // bit n set while mouse button n is held

// paramErr lives in the Mac-only MacErrors.h; the Carbon shims return the same value.
enum { AKParamErr = -50 };

// Carbon.m: fires a registered hotkey for this key event; YES if one matched (and so the
// key should not also go to the app, as on the Mac).
BOOL AKCarbonDispatchHotKey(unsigned short keyCode, NSEventModifierFlags flags, BOOL down);

// KeyLayout.m: the US layout in 'uchr' format (kTISPropertyUnicodeKeyLayoutData).
NSData *AKUSKeyboardLayoutData(void);

// CGDisplay.m: display IDs are 1-based positions in UIScreen's list.
CGDirectDisplayID AKDisplayIDForScreen(UIScreen *screen);
UIScreen *AKScreenForDisplayID(CGDirectDisplayID display);

@interface NSApplication (AKShimPrivate)
- (void)_registerWindow:(NSWindow *)window;
- (void)_unregisterWindow:(NSWindow *)window;
@end

@interface NSEvent (AKShimPrivate)
// The view the input bridge hit-tested for a mouse event; nil for synthetic events.
@property (nonatomic, readonly, weak) NSView *_targetView;
- (void)_setWindow:(NSWindow *)window targetView:(NSView *)view;
- (void)_setDeltaX:(CGFloat)dx deltaY:(CGFloat)dy;
+ (void)_setMouseLocation:(NSPoint)location;
+ (void)_setModifierFlags:(NSEventModifierFlags)flags;
@end

// AKForwarding.m: a shim class that is missing a method logs it (once per class+selector,
// to stderr -> steam-console.log) and returns zero instead of raising "unrecognized
// selector". This keeps the client running so one launch surfaces every method the shim
// still needs, the way a real AppKit object would already respond. A class opts in by
// putting AK_UNIMPLEMENTED_FORWARDER in its @implementation. respondsToSelector: is
// unaffected (it checks the real method list), so feature detection still sees the truth.
void AKLogUnimplemented(id obj, SEL sel);
NSMethodSignature *AKGenericSignatureForSelector(SEL sel);

#define AK_UNIMPLEMENTED_FORWARDER \
  - (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector { \
    NSMethodSignature *sig = [super methodSignatureForSelector:aSelector]; \
    return sig ?: AKGenericSignatureForSelector(aSelector); \
  } \
  - (void)forwardInvocation:(NSInvocation *)anInvocation { \
    AKLogUnimplemented(self, anInvocation.selector); \
    NSUInteger len = anInvocation.methodSignature.methodReturnLength; \
    if (len) { void *zero = calloc(1, len); [anInvocation setReturnValue:zero]; free(zero); } \
  }

// The same for class methods (+[NSEvent ...], +[NSMenu ...]).
#define AK_UNIMPLEMENTED_CLASS_FORWARDER \
  + (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector { \
    NSMethodSignature *sig = [super methodSignatureForSelector:aSelector]; \
    return sig ?: AKGenericSignatureForSelector(aSelector); \
  } \
  + (void)forwardInvocation:(NSInvocation *)anInvocation { \
    AKLogUnimplemented(self, anInvocation.selector); \
    NSUInteger len = anInvocation.methodSignature.methodReturnLength; \
    if (len) { void *zero = calloc(1, len); [anInvocation setReturnValue:zero]; free(zero); } \
  }

// NSApplication.m: run a UIKit step on the main thread and wait for it. AppKit code runs off
// the main thread here (the in-process web helper's Chromium UI thread), and UIKit throws
// when a view in the live hierarchy is changed from another thread. Only the UIKit step
// moves; the client's own callbacks stay on the thread that made the call.
void AKOnMainSync(dispatch_block_t block);

// WebHelperWeb.m: the view the Safari-engine web interface lives on (nil with Chromium). It is
// the app's top layer: NSWindow.m orders windows in below it and leaves UIKit focus to it.
UIView *AKWHStageView(void);

// InProcessExec.m: programs run in this process as stand-in processes (see there).
pid_t AKSpawnInProcess(const char *path, char *const argv[], char *const envp[], const char *cwd);
struct mach_header;
int AKRebindSymbol(const char *pathPrefix, const char *symbol, void *replacement);
// One loaded image's imports (names with their leading underscore), each pointed at what the
// block answers for it (NULL: left alone). Returns how many were changed.
int AKRebindImports(const struct mach_header *header, intptr_t slide, void *(^replacement)(const char *symbol));
const char *AKInProcessCurrentPath(void);   // the program this thread is the main thread of, or NULL
void AKInProcessDetach(pid_t pid);
void AKInProcessForceExit(pid_t pid, int status);   // one that didn't end when asked
void AKInProcessSetExitObserver(void (*observer)(pid_t pid, int status));
void AKInProcessSetSignalObserver(void (*observer)(pid_t pid, int sig));

// MacPrograms.m: the Mac game Steam started (one at a time), run in this process.
pid_t AKLaunchMacApplication(NSURL *app, NSArray<NSString *> *arguments, NSDictionary<NSString *, NSString *> *environment,
                             NSError **error);
BOOL AKGameIsRunning(void);
pid_t AKGamePid(void);
NSBundle *AKGameBundleForPid(pid_t pid);
BOOL AKIsGameThread(void);                     // its main thread
BOOL AKAddressIsInGame(const void *address);   // code of its own
int AKGameApplicationMain(int argc, const char *argv[]);
void AKGameNoteRunLoop(void);                  // called on its main thread as it pumps events
// NSApplication.m, NSWindow.m, NSWorkspace.m: what goes when it ends.
void AKGameAppEnded(void);
void AKGameWindowsClose(void);                 // main thread
void AKGameDidLaunch(pid_t pid);
void AKGameDidEnd(pid_t pid);

@interface NSWindow (AKShimGame)
@property (nonatomic, readonly) BOOL _ak_gameWindow;
@end

// WebHelperWeb.m: a key Steam typed (CGEventPost: its on-screen keyboard, driven by a
// controller) for the focused page. `text` is what the key types; `command` is the Command
// modifier. Main thread.
void AKWHTypeKey(BOOL down, uint16_t keyCode, NSString *text, BOOL command);

// CGEvents.m: Quartz's global display points (origin top-left, y down) <-> AppKit screen
// points (origin bottom-left, y up), as +[NSEvent mouseLocation] reports them.
CGPoint AKQuartzPointFromAppKit(NSPoint p);
NSPoint AKAppKitPointFromQuartz(CGPoint p);

// NSEvent.m: local event monitors (+addLocalMonitorForEventsMatchingMask:handler:). NSApp's
// -sendEvent: passes each event through them first; a handler returning nil swallows it.
NSEvent *AKRunLocalEventMonitors(NSEvent *event);

// KeyCodes.m
unsigned short AKMacKeyCodeForHIDUsage(long usage);       // 0xFF when unknown
unsigned short AKMacKeyCodeForCharacter(unichar c);        // 0xFF when unknown
NSString *AKCharactersForMacKeyCode(unsigned short code);  // AppKit's characters for non-text keys, or nil
NSEventModifierFlags AKModifierFlagForHIDUsage(long usage); // 0 unless a modifier key
SEL AKCommandSelectorForKeyEvent(NSEvent *event);          // NULL when the key types text

// NibLoading.m: Interface Builder nibs (keyed archives and NIBArchive files), loaded as AppKit
// loads them — objects made, outlets and actions connected, -awakeFromNib sent, windows marked
// visible at launch shown. `name` is a nib in `bundle` (or a path); the top-level objects are
// returned in `topLevelObjects` when asked for, else kept alive for good (as AppKit's legacy
// loading does for MainMenu).
BOOL AKLoadNib(NSString *name, NSBundle *bundle, id owner, NSArray **topLevelObjects);
// An archived NSFrame (or NSFrameSize, at the origin) as AppKit numbers it.
NSRect AKNibDecodeFrame(NSCoder *coder);

@interface NSView (AKShimNib)
- (void)_ak_applyNibCoder:(NSCoder *)coder;           // NSvFlags, OpenGL resolution, subviews
- (void)_ak_performOnOwnerThread:(dispatch_block_t)block; // the thread that made the view
@end

// NSOpenGL.m: a game's OpenGL views as AppKit's first display after launch leaves them: each
// with its context, current on the game's main thread, and -prepareOpenGL sent once.
void AKPrepareGameOpenGLViews(void);

@interface NSOpenGLView (AKShimDisplay)
- (void)_ak_display;   // UIKit asked the view to draw: context current, then -drawRect:
@end

// GameHID.m: a game library's IOKit HID imports, answered from GameController (called for each
// of the game's images as it loads).
void AKGameBindControllers(const struct mach_header *header, intptr_t slide, const char *name);
// GameAudio.m: a game library's lookups of the Mac's output audio units find iOS's RemoteIO.
void AKGameBindAudio(const struct mach_header *header, intptr_t slide);
// GameTimers.m: repeating NSTimers made on a game's main thread fire late rather than skip a tick.
void AKGameInstallTimers(void);
// GameTimers.m: a game library's clock reads rest the core while its code spins on them.
void AKGameBindClock(const struct mach_header *header, intptr_t slide);

// WebHelperGamepad.m: Steam's overlay - Big Picture over a running game (View + Menu, or the
// Home button) - and Menu or View as a game should see them (held back to tell them from that
// chord). Main thread, but for the two a game's thread asks.
@class GCController;
BOOL AKGameOverlayShown(void);
void AKGameOverlayHide(void);    // back to the game
void AKGameOverlayReset(void);   // the game ended
BOOL AKControllerMenuViewPressed(GCController *controller, BOOL menu);
