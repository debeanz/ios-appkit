// NSViewController / NSWindowController — MVC controllers. Backed by the NSView/NSWindow
// shims; -viewDidLoad and the appearance callbacks fire as on the Mac.
#import "NSResponder.h"
#import "NSView.h"

@class NSWindow, NSNib;

@interface NSViewController : NSResponder
- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil;
@property (nonatomic, strong) NSView *view;
@property (nonatomic, readonly) BOOL isViewLoaded;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) id representedObject;
@property (nonatomic, readonly, copy) NSString *nibName;
@property (nonatomic, readonly, strong) NSBundle *nibBundle;
@property (nonatomic, readonly, copy) NSArray<NSViewController *> *childViewControllers;
@property (nonatomic, weak) NSViewController *parentViewController;

- (void)loadView;                 // override to build the view in code
- (void)viewDidLoad;
- (void)viewWillAppear;
- (void)viewDidAppear;
- (void)viewWillDisappear;
- (void)viewDidDisappear;
- (void)addChildViewController:(NSViewController *)childViewController;
- (void)removeFromParentViewController;
@end

@interface NSWindowController : NSResponder
- (instancetype)initWithWindow:(NSWindow *)window;
- (instancetype)initWithWindowNibName:(NSString *)windowNibName;
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSViewController *contentViewController;
@property (nonatomic, copy) NSString *windowFrameAutosaveName;
@property (nonatomic, readonly) BOOL isWindowLoaded;
@property (nonatomic, strong) id document;

- (void)windowDidLoad;
- (void)loadWindow;
- (void)showWindow:(id)sender;
- (void)close;
- (IBAction)performClose:(id)sender;
@end
