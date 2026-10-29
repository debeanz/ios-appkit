// The web side of the Safari-engine helper: WKWebViews for the browsers Steam creates and the
// popups its interface opens, and the SteamClient bridge between those pages and Steam.
//
// How Steam's interface is put together (seen in Steam Helper's log and the UI's code):
// Steam creates one hidden browser, the "SP Shared JS Context" (browser type 12), and loads
// https://steamloopback.host/index.html into it. That page runs the whole interface. Each
// window - Big Picture's own ("SP BPM_uid0"), its menus - is a popup it opens with
// window.open("about:blank?createflags=...&minwidth=...&browserType=...") and then fills
// itself, writing the popup's document and rendering into it. The menus are BrowserView
// popups: SteamClient.BrowserView.CreatePopup gives the URL to open, and the BrowserView
// object places the page inside its parent window.
//
// Here every browser is a WKWebView on one stage, the top layer of the app's window. The
// shared context's is 1x1 at the back (it must stay in the window, or WebKit stops its timers
// and animation frames); popups fill the screen, and BrowserViews sit where their parent's
// script puts them. All of them share one configuration, so the popups belong to the shared
// context's page (same process, direct access to their documents) and load https through
// WebHelperLoopback.m. Big Picture lays itself out for at least its window's
// minwidth/minheight (853x534) CSS pixels; a phone in landscape is about 932x430 points, so a
// popup gets a window that big and its view is scaled down to the screen.
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import "HTMLMessages.h"
#import "WebHelper.h"

#include "WebHelperBridge.inc"

static const uint32_t kSharedJSContextType = 12;   // CMsgBrowserCreate.browser_type
static const double kMinWidth = 853, kMinHeight = 534;   // Big Picture's window minimum (CSS px)

@interface AKWHBrowser : NSObject
@property(nonatomic) uint32_t index;          // also what Browser.GetBrowserID returns
@property(nonatomic) uint32_t handle;         // Steam's handle (Browser.GetSteamBrowserID)
@property(nonatomic) uint32_t type;
@property(nonatomic) BOOL createdBySteam;     // made by CMsgBrowserCreate
@property(nonatomic) BOOL knownToSteam;       // created by Steam or announced to it: Steam gets its events
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *userAgentFamily;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, weak) AKWHBrowser *parent;      // the window a BrowserView sits in
@property(nonatomic, weak) AKWHBrowser *viewOwner;   // whose script holds the BrowserView object
@property(nonatomic) uint32_t viewId;                // that object's id (0: not a BrowserView)
@property(nonatomic) BOOL isPopupView;               // a BrowserView filled by its owner's script
@property(nonatomic) CGRect cssBounds;
@property(nonatomic) BOOL viewVisible;
@property(nonatomic) double zoom;
@property(nonatomic, copy) NSString *loadedURL;
@property(nonatomic) BOOL lostPage;                          // its page process ended; not reloaded yet
@property(nonatomic, copy) NSDictionary *viewportArguments;  // as last given to WebKit (placeView)
@property(nonatomic, strong) NSMutableArray *outbox;   // messages for the page, sent together
@property(nonatomic) CFAbsoluteTime pingSent;           // see startWatchingPages
@property(nonatomic) unsigned stuckReports;
@end
@implementation AKWHBrowser
@end

@interface AKWHWebDelegate : NSObject <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate>
- (void)longPressed:(UILongPressGestureRecognizer *)g;
@end

static NSMutableArray<AKWHBrowser *> *gBrowsers;
static uint32_t gNextIndex = 0x4000;
static NSMutableArray<NSArray *> *gMethods;          // [name, type] registered by Steam
static uint32_t gMethodOwner;                        // the browser they were registered for
static WKWebViewConfiguration *gSteamConfig;         // Steam's pages and their popups
static BOOL gBridgeInstalled;
static AKWHWebDelegate *gDelegate;
static NSDictionary *gPendingOpen;                   // the latest window.open, from the bridge
static uint64_t gBuildID;
static unsigned gConsoleLines;

static BOOL gRestarting;   // this helper is ending for Steam to start a new one (pageProcessEnded)
static CFTimeInterval gLastTouch;   // when a finger last went down anywhere in the app

static void closeSockets(AKWHBrowser *b);
static void layoutBrowser(AKWHBrowser *b);
static void watchTouchesAndKeyboard(UIWindow *window);
static void logWindows(NSString *when);
static void viewEvent(AKWHBrowser *v, NSString *event, NSArray *args);
static WKWebView *focusedWebView(void);

#pragma mark Browsers

// The stage: the web interface is the whole UI in this mode, so it sits above everything the
// Mac-window layer puts in the app's window (NSWindow.m orders Steam's windows in below it),
// and nothing there can cover a page or take its touches. Where no web view is, touches go
// through to what's below.
@interface AKWHStage : UIView
@end

@implementation AKWHStage
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  UIView *hit = [super hitTest:point withEvent:event];
  return hit == self ? nil : hit;
}
- (void)layoutSubviews {
  [super layoutSubviews];
  for (AKWHBrowser *b in [gBrowsers copy]) layoutBrowser(b);
}
@end

static AKWHStage *gStage;

static UIView *appView(void) {
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    for (UIWindow *w in ((UIWindowScene *)scene).windows)
      if (w.rootViewController.view) return w.rootViewController.view;
  }
  return nil;
}

// Where the web views go (the stage, made on first use and kept in front).
static UIView *hostView(void) {
  UIView *app = appView();
  if (!app) return nil;
  if (!gStage) {
    gStage = [[AKWHStage alloc] initWithFrame:app.bounds];
    gStage.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    gStage.backgroundColor = UIColor.clearColor;
    watchTouchesAndKeyboard(app.window);
  }
  if (gStage.superview != app) [app addSubview:gStage];
  else if (app.subviews.lastObject != gStage) [app bringSubviewToFront:gStage];
  return gStage;
}

UIView *AKWHStageView(void) { return gStage; }

// The screen in points, landscape.
static CGSize screenPoints(void) {
  CGSize s = hostView().bounds.size;
  if (s.width <= 0) s = UIScreen.mainScreen.bounds.size;
  return CGSizeMake(MAX(s.width, s.height), MIN(s.width, s.height));
}

static double zoomFor(double minWidth, double minHeight) {
  CGSize s = screenPoints();
  double z = 1;
  if (minWidth > 0) z = MIN(z, s.width / minWidth);
  if (minHeight > 0) z = MIN(z, s.height / minHeight);
  return MAX(z, 0.5);
}

static AKWHBrowser *browserForWebView(WKWebView *webView) {
  for (AKWHBrowser *b in gBrowsers) if (b.webView == webView) return b;
  return nil;
}

static AKWHBrowser *browserForHandle(uint32_t handle) {
  for (AKWHBrowser *b in gBrowsers) if (b.handle == handle) return b;
  return nil;
}

static AKWHBrowser *browserForIndex(uint32_t index) {
  for (AKWHBrowser *b in gBrowsers) if (b.index == index) return b;
  return nil;
}

static AKWHBrowser *viewFor(AKWHBrowser *owner, uint32_t viewId) {
  for (AKWHBrowser *b in gBrowsers) if (b.viewId == viewId && b.viewOwner == owner) return b;
  return nil;
}

static NSString *userAgent(NSString *family) {
  return [NSString stringWithFormat:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7; %@/default/%llu) AppleWebKit/605.1.15 "
                                    @"(KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                                    family.length ? family : @"Valve Steam Client", gBuildID];
}

// Browser numbers (what Browser.GetBrowserID returns, and the low half of Steam's handle).
// Steam's pages number their own popups from 2 up (WebHelperBridge.js picks the number and
// passes it as akwh_id); the page Steam creates first is 1, and everything else the app makes
// counts from 0x4000, out of their way.
static uint32_t freeIndex(uint32_t wanted) {
  if (wanted > 0 && wanted < 0x10000 && !browserForIndex(wanted)) return wanted;
  while (browserForIndex(gNextIndex)) gNextIndex++;
  return gNextIndex++;
}

static AKWHBrowser *newBrowser(uint32_t type, NSString *name, uint32_t wantedIndex) {
  if (!gBrowsers) gBrowsers = [NSMutableArray array];
  AKWHBrowser *b = [AKWHBrowser new];
  b.index = freeIndex(wantedIndex);
  b.handle = (1u << 16) | b.index;   // like Steam Helper's: an index plus a serial
  b.type = type;
  b.name = name ?: @"";
  b.zoom = 1;
  b.outbox = [NSMutableArray array];
  [gBrowsers addObject:b];
  return b;
}

// WebKit puts a bar (previous/next field, Done) over the keyboard; Steam's interface has its
// own navigation, so the keyboard comes alone. The keyboard itself follows iOS's rule: a
// field gets it when tapped, not when a page focuses it by itself.
static void hideKeyboardBar(void) {
  Class contentView = NSClassFromString(@"WKContentView");
  if (!contentView) return;
  IMP none = imp_implementationWithBlock(^UIView *(id view) { return nil; });
  if (!class_addMethod(contentView, @selector(inputAccessoryView), none, "@@:"))
    method_setImplementation(class_getInstanceMethod(contentView, @selector(inputAccessoryView)), none);
}

// Videos play in the page. iPhone WebKit otherwise opens every <video> without playsinline in
// its full-screen player - Steam's don't set it, and the Big Picture intro did - which puts a
// window over the app that takes every touch. (WebHelperBridge.js also marks videos
// playsinline, in case this private switch goes away.)
static void playVideosInline(WKWebViewConfiguration *c) {
  c.allowsInlineMediaPlayback = YES;
  c.allowsPictureInPictureMediaPlayback = NO;
  SEL requires = NSSelectorFromString(@"_setInlineMediaPlaybackRequiresPlaysInlineAttribute:");
  if ([c respondsToSelector:requires]) ((void (*)(id, SEL, BOOL))[c methodForSelector:requires])(c, requires, NO);
  // Pages are laid out wider than the screen and zoomed out (placeView); iOS would enlarge
  // their running text to make up for it, which the store's pages don't expect.
  SEL autosizing = NSSelectorFromString(@"_setTextAutosizingEnabled:");
  if ([c.preferences respondsToSelector:autosizing])
    ((void (*)(id, SEL, BOOL))[c.preferences methodForSelector:autosizing])(c.preferences, autosizing, NO);
}

static WKWebViewConfiguration *steamConfiguration(void) {
  if (gSteamConfig) return gSteamConfig;
  if (!gDelegate) gDelegate = [AKWHWebDelegate new];
  hideKeyboardBar();
  WKWebViewConfiguration *c = [WKWebViewConfiguration new];
  c.preferences.javaScriptCanOpenWindowsAutomatically = YES;
  playVideosInline(c);
  c.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
  c.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
  c.userContentController = [WKUserContentController new];
  [c.userContentController addScriptMessageHandler:gDelegate name:@"steamclient"];
  AKWHLoopbackInstall(c);
  gSteamConfig = c;
  return c;
}

// A plain web configuration (BrowserView.Create: store and community pages): the real
// network, the same cookies.
static WKWebViewConfiguration *webConfiguration(void) {
  static WKWebViewConfiguration *c;
  if (c) return c;
  if (!gDelegate) gDelegate = [AKWHWebDelegate new];
  c = [WKWebViewConfiguration new];
  playVideosInline(c);
  c.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
  c.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
  c.userContentController = [WKUserContentController new];
  // Which field has the focus, for the view's "node-has-focus" event: Big Picture shows its
  // on-screen keyboard for a text field in the page (a store search box), hides it otherwise.
  [c.userContentController addScriptMessageHandler:gDelegate name:@"akwhview"];
  NSString *focus =
      @"(function () {"
       "  var post = function (el) { try { window.webkit.messageHandlers.akwhview.postMessage({ op: 'focus',"
       "    tag: el && el.tagName ? el.tagName : '', type: el && el.type ? String(el.type) : '' }); } catch (e) {} };"
       "  document.addEventListener('focusin', function (e) { post(e.target); }, true);"
       "  document.addEventListener('focusout', function (e) { if (!e.relatedTarget) post(null); }, true);"
       "})();";
  [c.userContentController addUserScript:[[WKUserScript alloc] initWithSource:focus injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                             forMainFrameOnly:YES]];
  // Steam's own sites get the two calls Steam Helper gives every page in a BrowserView to
  // talk with the window it sits in (SteamClient.BrowserView.PostMessageToParent and
  // RegisterForMessageFromParent). Over them the store joins Big Picture's controller
  // navigation: it says it takes controller input, Big Picture forwards the buttons into it
  // and tells it when to take the focus. Without them Big Picture moved past the page as a
  // whole (down scrolled it, up left it for the top bar). Nothing else is exposed, and not to
  // other sites.
  NSString *messaging =
      @"(function () {"
       "  if (!/(^|\\.)(steampowered\\.com|steamcommunity\\.com|steam-chat\\.com|steamchina\\.com)$/.test(location.hostname)) return;"
       "  if (window.SteamClient) return;"
       "  var listeners = [];"
       "  window.SteamClient = { BrowserView: {"
       "    PostMessageToParent: function (message, args) {"
       "      try { window.webkit.messageHandlers.akwhview.postMessage({ op: 'to-parent', message: String(message),"
       "        args: args === undefined ? '' : String(args) }); } catch (e) {}"
       "    },"
       "    RegisterForMessageFromParent: function (fn) {"
       "      if (typeof fn === 'function') listeners.push(fn);"
       "      return { unregister: function () { var i = listeners.indexOf(fn); if (i >= 0) listeners.splice(i, 1); } };"
       "    }"
       "  } };"
       "  Object.defineProperty(window, '__akwhFromParent', { value: function (message, args) {"
       "    listeners.slice().forEach(function (fn) { try { fn(message, args); } catch (e) {} });"
       "  } });"
       "})();";
  [c.userContentController addUserScript:[[WKUserScript alloc] initWithSource:messaging injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                             forMainFrameOnly:YES]];
  return c;
}

static WKWebView *makeWebView(AKWHBrowser *b, WKWebViewConfiguration *config, BOOL appPage) {
  WKWebView *wv = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 1, 1) configuration:config];
  wv.navigationDelegate = gDelegate;
  wv.UIDelegate = gDelegate;
  wv.customUserAgent = userAgent(b.userAgentFamily);
  wv.allowsLinkPreview = NO;
  wv.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
  if (appPage) {
    // Steam's windows are apps, not documents: they lay out to the window and scroll inside,
    // with nothing of the web view's own showing (scroll bars, the white behind the page).
    wv.scrollView.bounces = NO;
    wv.scrollView.scrollEnabled = NO;
    wv.scrollView.showsVerticalScrollIndicator = NO;
    wv.scrollView.showsHorizontalScrollIndicator = NO;
    if (@available(iOS 15.0, *)) wv.underPageBackgroundColor = UIColor.blackColor;
    // A long press is the touch screen's right click (see -longPressed:).
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:gDelegate action:@selector(longPressed:)];
    press.delegate = gDelegate;
    press.cancelsTouchesInView = NO;
    press.delaysTouchesEnded = NO;
    [wv addGestureRecognizer:press];
  }
  if (@available(iOS 16.4, *)) wv.inspectable = YES;
  // WebKit asks this before a focused field brings up the keyboard (logged, see
  // _webView:decidePolicyForFocusedElement:).
  SEL setInputDelegate = NSSelectorFromString(@"_setInputDelegate:");
  if ([wv respondsToSelector:setInputDelegate])
    ((void (*)(id, SEL, id))[wv methodForSelector:setInputDelegate])(wv, setInputDelegate, gDelegate);
  b.webView = wv;
  return wv;
}

// A page shown in `frame` of the stage at `scale`: it lays out frame.size / scale CSS pixels
// big (Big Picture asks for at least 853x534, more than a phone's screen in points) and is
// drawn at scale. WebKit is given that layout width and scale as viewport arguments (what a
// page's viewport tag says, but taking precedence over it), so it draws straight at the
// screen's resolution. Without that switch (it's private) the view is made frame.size / scale
// points big and shrunk with a transform, which draws about half as many pixels again as the
// screen shows. WKWebView's pageZoom isn't used either way: viewport units ignore it (100vw
// stayed the unzoomed width and Big Picture stopped short of the screen's edges).
static void placeView(AKWHBrowser *b, CGRect frame, double scale) {
  WKWebView *v = b.webView;
  SEL override = NSSelectorFromString(@"_overrideViewportWithArguments:");
  if ([v respondsToSelector:override]) {
    v.transform = CGAffineTransformIdentity;
    v.frame = frame;
    if (frame.size.width < 1 || frame.size.height < 1) return;
    NSString *s = [NSString stringWithFormat:@"%.6f", scale];
    NSDictionary *args = @{ @"width": [NSString stringWithFormat:@"%.0f", round(frame.size.width / scale)],
                            @"initial-scale": s, @"minimum-scale": s, @"maximum-scale": s,
                            @"user-scalable": @"no", @"viewport-fit": @"cover" };
    if ([args isEqualToDictionary:b.viewportArguments]) return;
    b.viewportArguments = args;
    ((void (*)(id, SEL, id))[v methodForSelector:override])(v, override, args);
    static BOOL told;
    if (!told) { told = YES; AKWHLog(NO, @"pages are drawn at the screen's resolution (viewport %@ wide at %@)", args[@"width"], s); }
    return;
  }
  v.transform = CGAffineTransformIdentity;
  v.bounds = CGRectMake(0, 0, frame.size.width / scale, frame.size.height / scale);
  v.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
  v.transform = CGAffineTransformMakeScale(scale, scale);
}

// Where a browser's view goes: a window fills the screen at its zoom (the screen in CSS
// pixels is the screen in points divided by it); BrowserViews take their bounds (CSS pixels
// of the parent window) at the parent's zoom; the shared context stays 1x1.
static void layoutBrowser(AKWHBrowser *b) {
  UIView *stage = hostView();
  if (!b.webView || !stage) return;
  b.webView.autoresizingMask = UIViewAutoresizingNone;
  if (b.type == kSharedJSContextType) {
    b.webView.transform = CGAffineTransformIdentity;
    b.webView.frame = CGRectMake(0, 0, 1, 1);
  } else if (b.viewId) {
    AKWHBrowser *parent = b.parent;
    CGRect pf = parent.webView ? parent.webView.frame : stage.bounds;
    double z = parent ? parent.zoom : b.zoom;
    placeView(b, CGRectMake(pf.origin.x + b.cssBounds.origin.x * z, pf.origin.y + b.cssBounds.origin.y * z,
                            b.cssBounds.size.width * z, b.cssBounds.size.height * z), z);
    b.webView.hidden = !b.viewVisible || b.cssBounds.size.width <= 0 || b.cssBounds.size.height <= 0;
  } else {
    // A whole number of CSS pixels wide, the scale adjusted to match: a fractional width left
    // a hairline of the page's background down the right edge.
    CGSize s = stage.bounds.size;
    double width = ceil(s.width / b.zoom - 0.01), scale = s.width / width;
    b.zoom = scale;   // what its BrowserViews are placed with
    placeView(b, CGRectMake(0, 0, s.width, ceil(s.height / scale - 0.01) * scale), scale);
  }
}

// A BrowserView sits just above its parent window, and moves with it.
static void raiseBrowser(AKWHBrowser *b) {
  UIView *host = hostView();
  if (!b.webView) return;
  [host bringSubviewToFront:b.webView];
  for (AKWHBrowser *v in [gBrowsers copy])
    if (v.parent == b && v.webView) [host bringSubviewToFront:v.webView];
}

static void removeBrowser(AKWHBrowser *b) {
  if (!b) return;
  for (AKWHBrowser *v in [gBrowsers copy])
    if (v.parent == b) removeBrowser(v);
  AKWHLog(YES, @"browser %u \"%@\" closed", b.index, b.name);
  // A window Steam was told about and that closed on its own (window.close()).
  if (b.knownToSteam && !b.createdBySteam) AKWHSend(kAKWHClose, b.handle, @{ @"browser_handle": @(b.handle) });
  b.knownToSteam = NO;
  closeSockets(b);
  [b.webView stopLoading];
  [b.webView removeFromSuperview];
  b.webView.navigationDelegate = nil;
  b.webView.UIDelegate = nil;
  b.webView = nil;
  [gBrowsers removeObject:b];
}

#pragma mark Messages to pages

// Foundation objects as JSON for a page: bytes travel as base64.
static id jsonSafe(id v) {
  if ([v isKindOfClass:NSData.class]) return [(NSData *)v base64EncodedStringWithOptions:0];
  if ([v isKindOfClass:NSDictionary.class]) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    [(NSDictionary *)v enumerateKeysAndObjectsUsingBlock:^(id k, id obj, BOOL *stop) { out[k] = jsonSafe(obj); }];
    return out;
  }
  if ([v isKindOfClass:NSArray.class]) {
    NSMutableArray *out = [NSMutableArray array];
    for (id obj in (NSArray *)v) [out addObject:jsonSafe(obj)];
    return out;
  }
  return v ?: NSNull.null;
}

static NSString *jsonString(id v) {
  NSData *d = [NSJSONSerialization dataWithJSONObject:jsonSafe(v) options:NSJSONWritingFragmentsAllowed error:nil];
  return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"null";
}

static void flush(AKWHBrowser *b) {
  if (!b.outbox.count || !b.webView) return;
  NSArray *batch = [b.outbox copy];
  [b.outbox removeAllObjects];
  NSString *js = [NSString stringWithFormat:@"window.__akwhDispatch && window.__akwhDispatch(%@)", jsonString(batch)];
  [b.webView evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
    if (error) AKWHLog(NO, @"browser %u: delivering %lu messages failed: %@", b.index, (unsigned long)batch.count, error.localizedDescription);
  }];
}

// Messages for one page go out together once this turn of the run loop is done.
static void enqueue(AKWHBrowser *b, NSDictionary *msg) {
  if (!b) return;
  BOOL first = b.outbox.count == 0;
  [b.outbox addObject:msg];
  if (first) dispatch_async(dispatch_get_main_queue(), ^{ flush(b); });
}

#pragma mark WebSockets to Steam on this device

// The bridge hands WebSockets to localhost to the app (WebHelperBridge.js says why). Each is a
// NSURLSessionWebSocketTask with the Origin Steam accepts; events go back to the page in
// order, through the same batches as everything else.
@interface AKWHSocket : NSObject
@property(nonatomic, weak) AKWHBrowser *browser;
@property(nonatomic) uint32_t pageId;
@property(nonatomic, strong) NSURLSessionWebSocketTask *task;
@property(nonatomic) BOOL closed;
@end
@implementation AKWHSocket
@end

@interface AKWHSocketDelegate : NSObject <NSURLSessionWebSocketDelegate>
@end

static NSMutableArray<AKWHSocket *> *gSockets;
static NSURLSession *gSocketSession;

static AKWHSocket *socketForTask(NSURLSessionTask *task) {
  for (AKWHSocket *s in gSockets) if (s.task == task) return s;
  return nil;
}

static AKWHSocket *socketFor(AKWHBrowser *b, uint32_t pageId) {
  for (AKWHSocket *s in gSockets) if (s.browser == b && s.pageId == pageId) return s;
  return nil;
}

static void socketEvent(AKWHSocket *s, NSDictionary *fields) {
  NSMutableDictionary *m = [fields mutableCopy];
  m[@"t"] = @"ws";
  m[@"id"] = @(s.pageId);
  enqueue(s.browser, m);
}

static void socketClosed(AKWHSocket *s, NSInteger code, NSString *reason, BOOL clean, BOOL failed) {
  if (s.closed) return;
  s.closed = YES;
  if (failed) socketEvent(s, @{ @"ev": @"error" });
  socketEvent(s, @{ @"ev": @"close", @"code": @(code), @"reason": reason ?: @"", @"clean": @(clean) });
  [gSockets removeObject:s];
}

static void receiveNext(AKWHSocket *s) {
  NSURLSessionWebSocketTask *task = s.task;
  [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
    if (s.closed) return;
    if (error) {
      NSInteger code = task.closeCode;
      socketClosed(s, code ? code : 1006, @"", code != 0, code == 0);
      return;
    }
    if (message.type == NSURLSessionWebSocketMessageTypeString) socketEvent(s, @{ @"ev": @"message", @"text": message.string ?: @"" });
    else socketEvent(s, @{ @"ev": @"message", @"data": message.data ?: [NSData data] });
    receiveNext(s);
  }];
}

static void openSocket(AKWHBrowser *b, NSDictionary *m) {
  if (!gSocketSession) {
    gSockets = [NSMutableArray array];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 30;
    gSocketSession = [NSURLSession sessionWithConfiguration:config delegate:[AKWHSocketDelegate new] delegateQueue:NSOperationQueue.mainQueue];
  }
  AKWHSocket *s = [AKWHSocket new];
  s.browser = b;
  s.pageId = [m[@"id"] unsignedIntValue];
  // The URL as the page wrote it, so the Host header is what Chromium sends too.
  NSURL *url = [NSURL URLWithString:m[@"url"] ?: @""];
  if (!url) { socketClosed(s, 1006, @"", NO, YES); return; }
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  [request setValue:@"https://steamloopback.host" forHTTPHeaderField:@"Origin"];
  NSArray *protocols = m[@"protocols"];
  if ([protocols isKindOfClass:NSArray.class] && protocols.count)
    [request setValue:[protocols componentsJoinedByString:@", "] forHTTPHeaderField:@"Sec-WebSocket-Protocol"];
  s.task = [gSocketSession webSocketTaskWithRequest:request];
  s.task.maximumMessageSize = 64 << 20;
  [gSockets addObject:s];
  [s.task resume];
  receiveNext(s);
  AKWHLog(YES, @"page %u: WebSocket %u to %@ (through the app)", b.index, s.pageId, url);
}

static void sendOnSocket(AKWHBrowser *b, NSDictionary *m) {
  AKWHSocket *s = socketFor(b, [m[@"id"] unsignedIntValue]);
  if (!s || s.closed) return;
  NSURLSessionWebSocketMessage *message;
  if (m[@"text"]) message = [[NSURLSessionWebSocketMessage alloc] initWithString:m[@"text"]];
  else message = [[NSURLSessionWebSocketMessage alloc] initWithData:[[NSData alloc] initWithBase64EncodedString:m[@"data"] ?: @"" options:0] ?: [NSData data]];
  [s.task sendMessage:message completionHandler:^(NSError *error) {
    if (error) AKWHLog(NO, @"page %u: WebSocket %u send failed: %@", s.browser.index, s.pageId, error.localizedDescription);
  }];
}

static void closeSocket(AKWHBrowser *b, NSDictionary *m) {
  AKWHSocket *s = socketFor(b, [m[@"id"] unsignedIntValue]);
  if (!s || s.closed) return;
  NSInteger code = [m[@"code"] integerValue] ?: 1000;
  [s.task cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)code reason:[m[@"reason"] dataUsingEncoding:NSUTF8StringEncoding]];
  socketClosed(s, code, m[@"reason"], YES, NO);
}

// A page that goes away (or loads another document) takes its sockets with it.
static void closeSockets(AKWHBrowser *b) {
  for (AKWHSocket *s in [gSockets copy]) {
    if (s.browser != b) continue;
    s.closed = YES;
    [s.task cancel];
    [gSockets removeObject:s];
  }
}

@implementation AKWHSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task didOpenWithProtocol:(NSString *)protocol {
  AKWHSocket *s = socketForTask(task);
  if (!s || s.closed) return;
  AKWHLog(NO, @"page %u: WebSocket %u open", s.browser.index, s.pageId);
  socketEvent(s, @{ @"ev": @"open", @"protocol": protocol ?: @"" });
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task
    didCloseWithCode:(NSURLSessionWebSocketCloseCode)code reason:(NSData *)reason {
  AKWHSocket *s = socketForTask(task);
  if (!s) return;
  socketClosed(s, code, reason ? [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding] : @"", YES, NO);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
  AKWHSocket *s = socketForTask(task);
  if (!s) return;
  if (error) AKWHLog(YES, @"page %u: WebSocket %u failed: %@", s.browser.index, s.pageId, error.localizedDescription);
  socketClosed(s, 1006, @"", NO, error != nil);
}

@end

#pragma mark Are the pages answering?

// Every 5 s each of Steam's pages is asked to evaluate a trivial script. A page whose
// JavaScript is stuck - busy in a loop, or blocked waiting on something - doesn't answer,
// and that goes in the log with how long, so a frozen interface shows up as one.
// What keeps a window redrawing on its own: the CSS animations running in it, and the ones
// that never end (a spinner, a glow). WebKit's page process (where that work happens) isn't
// counted in the app's CPU figures, so this is how the log shows it. Every 30 s.
static NSString *const kAnimationsScript =
  @"(function () {"
   "  if (!document.getAnimations) return null;"
   "  var running = document.getAnimations().filter(function (a) { return a.playState === 'running'; });"
   "  var endless = running.filter(function (a) { var t = a.effect && a.effect.getTiming && a.effect.getTiming(); return t && t.iterations === Infinity; });"
   "  var name = function (a) { var el = a.effect && a.effect.target; var c = el && typeof el.className === 'string' ? el.className.split(' ')[0] : '';"
   "    return (a.animationName || a.transitionProperty || 'script') + (c ? ' on .' + c : '') + (el && el.offsetParent === null ? ' (hidden)' : ''); };"
   "  return running.length + ' running, ' + endless.length + ' endless' + (endless.length ? ': ' + endless.slice(0, 5).map(name).join(', ') : '');"
   "})()";

static void logAnimations(void) {
  for (AKWHBrowser *b in [gBrowsers copy]) {
    if (!b.webView || b.webView.hidden || b.type == kSharedJSContextType || (b.viewId && !b.isPopupView)) continue;
    uint32_t index = b.index;
    [b.webView evaluateJavaScript:kAnimationsScript completionHandler:^(id result, NSError *error) {
      if ([result isKindOfClass:NSString.class] && ![result hasPrefix:@"0 running"]) AKWHLog(NO, @"page %u animations: %@", index, result);
    }];
  }
}

static void startWatchingPages(void) {
  static NSTimer *timer;
  if (timer) return;
  static unsigned ticks;
  timer = [NSTimer timerWithTimeInterval:5 repeats:YES block:^(NSTimer *t) {
    if (++ticks % 6 == 0) logAnimations();
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    for (AKWHBrowser *b in [gBrowsers copy]) {
      if (!b.webView || (b.viewId && !b.isPopupView)) continue;   // Steam's own pages only
      if (b.pingSent > 0) {
        unsigned n = ++b.stuckReports;
        if (n <= 3 || n % 6 == 0)
          AKWHLog(YES, @"page %u \"%@\" hasn't answered for %.0f s: its JavaScript is stuck", b.index, b.name, now - b.pingSent);
        continue;
      }
      b.pingSent = now;
      __weak AKWHBrowser *weak = b;
      [b.webView evaluateJavaScript:@"0" completionHandler:^(id result, NSError *error) {
        AKWHBrowser *page = weak;
        if (!page) return;
        double ms = (CFAbsoluteTimeGetCurrent() - page.pingSent) * 1000;
        if (ms > 1000 || page.stuckReports) AKWHLog(YES, @"page %u answered after %.0f ms", page.index, ms);
        page.pingSent = 0;
        page.stuckReports = 0;
      }];
    }
  }];
  timer.tolerance = 1;   // lets iOS fold this wake-up in with others
  [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

#pragma mark Steam's interface page

static void installBridge(AKWHBrowser *b) {
  if (gBridgeInstalled) return;
  gBridgeInstalled = YES;
  double z = zoomFor(kMinWidth, kMinHeight);
  CGSize s = screenPoints();
  NSDictionary *config = @{
    @"methods": gMethods ?: @[],
    @"screen": @{ @"width": @(floor(s.width / z)), @"height": @(floor(s.height / z)) },
    @"self": @{ @"id": @(b.index), @"handle": @(b.handle) },   // popups get theirs from window.open
  };
  NSString *source = [[NSString stringWithUTF8String:kAKWHBridgeJS]
      stringByAppendingFormat:@"\nakwhInstall(window, %@);\n", jsonString(config)];
  WKUserScript *script = [[WKUserScript alloc] initWithSource:source injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
  [steamConfiguration().userContentController addUserScript:script];
  AKWHLog(YES, @"SteamClient bridge ready: %lu methods from Steam, screen %.0fx%.0f CSS px (zoom %.2f)",
          (unsigned long)gMethods.count, floor(s.width / z), floor(s.height / z), z);
  startWatchingPages();
  AKWHGamepadStart();
}

static void createSteamBrowser(uint32_t requestId, NSDictionary *msg) {
  gRestarting = NO;   // a (new) helper's first browser
  uint32_t type = [msg[@"browser_type"] unsignedIntValue];
  AKWHBrowser *b = newBrowser(type, @"", 1);
  b.createdBySteam = YES;
  b.knownToSteam = YES;
  b.userAgentFamily = msg[@"useragent"];
  UIView *host = hostView();
  if (host) {
    b.zoom = type == kSharedJSContextType ? 1 : zoomFor(kMinWidth, kMinHeight);
    WKWebView *wv = makeWebView(b, steamConfiguration(), YES);
    if (type == kSharedJSContextType) [host insertSubview:wv atIndex:0];
    else [host addSubview:wv];
    layoutBrowser(b);
  }
  AKWHLog(YES, @"browser %u (Steam handle %u) created: type %u, %@", b.index, b.handle, type,
          !host ? @"but there is no app window to show it in"
                : type == kSharedJSContextType ? @"runs Steam's interface (hidden)" : @"a window");
  AKWHSend(kAKWHBrowserCreateResponse, b.handle, @{ @"browser_handle": @(b.handle), @"request_id": @(requestId) });
  AKWHSend(kAKWHBrowserReady, b.handle, @{ @"browser_handle": @(b.handle) });
}

static void loadURL(AKWHBrowser *b, NSString *url) {
  if (!b.webView || !url.length) return;
  if ([url isEqualToString:b.loadedURL] && !b.lostPage) return;   // Steam sends its first URL twice
  b.loadedURL = url;
  b.lostPage = NO;
  if (b.createdBySteam) installBridge(b);
  AKWHLog(YES, @"browser %u loads %@", b.index, url);
  [b.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
}

#pragma mark Commands from Steam

// A function handle Steam was given: the browser's index above, the page's own handle below.
static uint64_t globalHandle(AKWHBrowser *b, uint64_t local) { return ((uint64_t)b.index << 32) | (local & 0xffffffffu); }

static void callbackToPage(uint64_t handle, NSDictionary *msg) {
  AKWHBrowser *b = browserForIndex((uint32_t)(handle >> 32));
  if (!b) { AKWHLog(NO, @"callback %llu: its page is gone", handle); return; }
  enqueue(b, @{ @"t": @"call", @"h": @(handle & 0xffffffffu), @"a": msg[@"arguments"] ?: @[] });
}

#pragma mark Controller input for the pages

// The page's System.UI.RegisterForSystemKeyEvents callback (registered with Steam, which
// calls it for the Steam/Quick Access buttons it sees), and whether Steam ever has.
static uint64_t gSystemKeyHandle;
static BOOL gSteamSendsSystemKeys;

void AKWHSendControllerButton(uint32_t controller, uint32_t button, BOOL pressed) {
  for (AKWHBrowser *b in gBrowsers)
    if (b.webView && !b.viewId) enqueue(b, @{ @"t": @"controller", @"c": @(controller), @"b": @(button), @"p": @(pressed) });
}

void AKWHSendSystemKey(uint32_t key, uint32_t controller) {
  if (!gSystemKeyHandle || gSteamSendsSystemKeys) return;
  NSDictionary *(^field)(NSString *, uint32_t) = ^(NSString *name, uint32_t v) {
    return @{ @"name": name, @"value": @{ @"int_value": @(v) } };
  };
  callbackToPage(gSystemKeyHandle, @{ @"arguments": @[ @{
    @"is_object": @YES,
    @"object_properties": @[ field(@"eKey", key), field(@"nControllerIndex", controller), field(@"nAppID", 0) ],
  } ] });
}

void AKWHWebHandleCommand(uint32_t cmd, uint32_t browser, NSDictionary *msg) {
  AKWHBrowser *b = browserForHandle(browser);
  switch (cmd) {
    case kAKWHBrowserCreate:
      createSteamBrowser([msg[@"request_id"] unsignedIntValue], msg);
      break;
    case kAKWHBrowserSetName:
      if (b) b.name = msg[@"name"] ?: b.name;
      break;
    case kAKWHBuildID:
      gBuildID = [msg[@"build_id"] unsignedLongLongValue];
      break;
    case kAKWHJSRegisterMethod: {
      if (!gMethods) gMethods = [NSMutableArray array];
      NSArray *entry = @[ msg[@"name"] ?: @"", @([msg[@"method_type"] intValue]) ];
      [gMethods addObject:entry];
      if (b) gMethodOwner = b.handle;
      if (gBridgeInstalled) {
        // Registered after the page started: add it to the pages there are.
        for (AKWHBrowser *p in gBrowsers) if (p.webView && !p.viewId) enqueue(p, @{ @"t": @"methods", @"methods": @[ entry ] });
      }
      break;
    }
    case kAKWHSetLocalFileRequestMapping:
      AKWHLoopbackMapHost([NSURL URLWithString:msg[@"request_url"] ?: @""].host, msg[@"default_local_path"], msg[@"routes"]);
      break;
    case kAKWHSetBrowserViewDomainRequestMapping:
      AKWHLoopbackMapHost(msg[@"request_domain"], msg[@"default_local_path"], nil);
      break;
    case kAKWHSetCookie:
      AKWHLoopbackSetCookie(msg);
      break;
    case kAKWHPostURL:
      loadURL(b, msg[@"url"]);
      break;
    case kAKWHExecuteJavaScript:
      if (b.webView && [msg[@"script"] length])
        [b.webView evaluateJavaScript:msg[@"script"] completionHandler:^(id r, NSError *e) {
          if (e) AKWHLog(NO, @"browser %u: Steam's script failed: %@", b.index, e.localizedDescription);
        }];
      break;
    case kAKWHJSExecuteCallback:
      if ([msg[@"function_handle"] unsignedLongLongValue] == gSystemKeyHandle && gSystemKeyHandle) gSteamSendsSystemKeys = YES;
      callbackToPage([msg[@"function_handle"] unsignedLongLongValue], msg);
      break;
    case kAKWHJSReleaseCallback: {
      uint64_t handle = [msg[@"function_handle"] unsignedLongLongValue];
      enqueue(browserForIndex((uint32_t)(handle >> 32)), @{ @"t": @"release", @"h": @(handle & 0xffffffffu) });
      break;
    }
    case kAKWHJSRaiseException:
      AKWHLog(YES, @"Steam raised a JavaScript exception in browser %u: %@", browser, msg[@"exception"]);
      enqueue(b, @{ @"t": @"exception", @"text": msg[@"exception"] ?: @"" });
      break;
    case kAKWHJSExecutePromise:
      AKWHLog(YES, @"JSExecutePromise isn't handled yet: %@", AKHTMLDescribe(msg, 300));
      break;
    case kAKWHBrowserRemove:
      if (b) {
        b.knownToSteam = NO;   // Steam's own decision: no need to tell it
        removeBrowser(b);
      }
      break;
    case kAKWHPopupCreated: {
      // What Steam Helper does on PopupCreated: tell the window. Steam's popup class only
      // renders into a new window once that message arrives (OnMessage "popup-created").
      AKWHLog(YES, @"Steam took window %u (%@) as browser %u", b.index, b.name, browser);
      [b.webView evaluateJavaScript:@"window.postMessage( 'popup-created', '*' );" completionHandler:^(id r, NSError *e) {
        if (e) AKWHLog(YES, @"window %u: telling it it was created failed: %@", b.index, e.localizedDescription);
      }];
      break;
    }
    case kAKWHReload: [b.webView reload]; break;
    case kAKWHGoBack: [b.webView goBack]; break;
    case kAKWHGoForward: [b.webView goForward]; break;
    case kAKWHStopLoad: [b.webView stopLoading]; break;
    case kAKWHWasHidden:
      if (b && b.type != kSharedJSContextType) b.webView.hidden = [msg[@"hidden"] boolValue];
      break;
    default:
      break;
  }
}

#pragma mark Calls from pages

// Function handles in a call's arguments become global ones (any depth: the promise's
// resolve/reject pair sits inside an object).
static id globalizeHandles(id v, AKWHBrowser *b) {
  if ([v isKindOfClass:NSArray.class]) {
    NSMutableArray *out = [NSMutableArray array];
    for (id item in (NSArray *)v) [out addObject:globalizeHandles(item, b)];
    return out;
  }
  if ([v isKindOfClass:NSDictionary.class]) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    [(NSDictionary *)v enumerateKeysAndObjectsUsingBlock:^(NSString *k, id obj, BOOL *stop) {
      if ([k isEqualToString:@"function_handle"] && [obj isKindOfClass:NSNumber.class])
        out[k] = @(globalHandle(b, [obj unsignedLongLongValue]));
      else
        out[k] = globalizeHandles(obj, b);
    }];
    return out;
  }
  return v;
}

static void reply(AKWHBrowser *b, NSDictionary *m, id value) {
  if (m[@"reply"]) enqueue(b, @{ @"t": @"reply", @"id": m[@"reply"], @"v": value ?: NSNull.null });
}

static void windowCall(AKWHBrowser *b, NSString *name, NSDictionary *m) {
  if ([name isEqualToString:@"ShowWindow"] || [name isEqualToString:@"BringToFront"]) {
    b.webView.hidden = NO;
    raiseBrowser(b);
    // The window in front has the keyboard focus, as on a Mac: its document gets focus (the
    // window's focus event, document.hasFocus()), which Steam's windows wait for.
    if (b.type != kSharedJSContextType) [b.webView becomeFirstResponder];
  } else if ([name isEqualToString:@"HideWindow"] || [name isEqualToString:@"Minimize"]) {
    if (b.type != kSharedJSContextType) b.webView.hidden = YES;
  } else if ([name isEqualToString:@"Close"]) {
    if (b.createdBySteam) b.webView.hidden = YES;
    else removeBrowser(b);
  } else if ([name isEqualToString:@"SetKeyFocus"]) {
    [b.webView becomeFirstResponder];
  }
  reply(b, m, nil);
}

static void browserViewCall(AKWHBrowser *owner, AKWHBrowser *v, NSString *name, NSArray *args, NSDictionary *m) {
  if (!v) { AKWHLog(NO, @"BrowserView %@ for a view that doesn't exist (yet)", name); return; }
  if ([name isEqualToString:@"SetBounds"] && args.count >= 4) {
    v.cssBounds = CGRectMake([args[0] doubleValue], [args[1] doubleValue], [args[2] doubleValue], [args[3] doubleValue]);
    layoutBrowser(v);
  } else if ([name isEqualToString:@"SetVisible"]) {
    v.viewVisible = [args.firstObject boolValue];
    layoutBrowser(v);
    if (v.viewVisible) [hostView() bringSubviewToFront:v.webView];
    AKWHGameOverlayMenu(v.name, v.viewVisible);
  } else if ([name isEqualToString:@"LoadURL"] && args.count) {
    NSURL *url = [NSURL URLWithString:args[0]];
    if (url) [v.webView loadRequest:[NSURLRequest requestWithURL:url]];
  } else if ([name isEqualToString:@"Reload"]) {
    [v.webView reload];
  } else if ([name isEqualToString:@"GoBack"]) {
    [v.webView goBack];
  } else if ([name isEqualToString:@"GoForward"]) {
    [v.webView goForward];
  } else if ([name isEqualToString:@"SetWindowStackingOrder"]) {
    // EWindowStackingOrder: 1 above the other views (an opened menu), 2 just above its window.
    UIView *stage = hostView();
    if ([args.firstObject intValue] == 2 && v.parent.webView.superview == stage)
      [stage insertSubview:v.webView aboveSubview:v.parent.webView];
    else if ([args.firstObject intValue] == 1)
      [stage bringSubviewToFront:v.webView];
  } else if ([name isEqualToString:@"SetFocus"]) {
    // Big Picture's keyboard calls SetFocus(false) then SetFocus(true) for every key it types:
    // only a view that doesn't have the focus yet takes it.
    if ([args.firstObject boolValue] && focusedWebView() != v.webView) [v.webView becomeFirstResponder];
  } else if ([name isEqualToString:@"PostMessage"]) {
    if (v.isPopupView) {
      enqueue(v, @{ @"t": @"parent-message", @"a": args ?: @[] });
    } else {
      // A web page (the store): to the listeners its SteamClient.BrowserView registered.
      NSString *json = jsonString(@[ args.count > 0 ? args[0] : @"", args.count > 1 ? args[1] : @"" ]);
      [v.webView evaluateJavaScript:[NSString stringWithFormat:@"window.__akwhFromParent && window.__akwhFromParent.apply(null, %@)", json]
                  completionHandler:nil];
    }
  } else {
    AKWHLog(NO, @"BrowserView %@ isn't supported yet", name);
  }
}

@implementation AKWHWebDelegate

- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
  AKWHBrowser *b = browserForWebView(message.webView);
  if (![message.body isKindOfClass:NSDictionary.class] || !b) return;
  NSDictionary *m = message.body;
  NSString *op = m[@"op"];
  // A web page in a BrowserView (the store: anyone's page) only reports focus, nothing else.
  if ([message.name isEqualToString:@"akwhview"]) {
    if ([op isEqualToString:@"focus"] && [m[@"tag"] isKindOfClass:NSString.class] && [m[@"type"] isKindOfClass:NSString.class])
      viewEvent(b, @"node-has-focus", @[ message.webView.URL.absoluteString ?: @"", m[@"tag"], m[@"type"], @"", @NO ]);
    else if ([op isEqualToString:@"to-parent"] && [m[@"message"] isKindOfClass:NSString.class] && [m[@"args"] isKindOfClass:NSString.class])
      viewEvent(b, @"message", @[ m[@"message"], m[@"args"] ]);
    return;
  }
  if ([op isEqualToString:@"call"]) {
    NSArray *args = globalizeHandles(m[@"args"] ?: @[], b);
    if ([m[@"name"] isEqualToString:@"System.UI.RegisterForSystemKeyEvents"]) {
      id handle = [args.firstObject isKindOfClass:NSDictionary.class] ? args.firstObject[@"function_handle"] : nil;
      if (handle) gSystemKeyHandle = [handle unsignedLongLongValue];
    }
    AKWHSend(kAKWHJSMethodCall, b.handle, @{
      @"browser_handle": @(b.handle),
      @"owning_browser_handle": @(gMethodOwner ?: b.handle),
      @"name": m[@"name"] ?: @"",
      @"arguments": args,
    });
  } else if ([op isEqualToString:@"release"]) {
    AKWHSend(kAKWHJSReleaseCallback, b.handle, @{
      @"browser_handle": @(b.handle),
      @"owning_browser_handle": @(gMethodOwner ?: b.handle),
      @"function_handle": @(globalHandle(b, [m[@"handle"] unsignedLongLongValue])),
    });
  } else if ([op isEqualToString:@"console"]) {
    if (++gConsoleLines <= 5000) AKWHLog(NO, @"[js %u %@] %@", b.index, m[@"level"], m[@"text"]);
    if ([m[@"level"] isEqualToString:@"error"] && gConsoleLines <= 200) AKWHLog(YES, @"page %u error: %@", b.index, m[@"text"]);
  } else if ([op isEqualToString:@"ws-open"]) {
    openSocket(b, m);
  } else if ([op isEqualToString:@"ws-send"]) {
    sendOnSocket(b, m);
  } else if ([op isEqualToString:@"ws-close"]) {
    closeSocket(b, m);
  } else if ([op isEqualToString:@"will-open"]) {
    gPendingOpen = m;
  } else if ([op isEqualToString:@"window"]) {
    windowCall(b, m[@"name"], m);
  } else if ([op isEqualToString:@"browser"]) {
    if ([m[@"name"] isEqualToString:@"PostMessageToParent"]) {
      AKWHBrowser *owner = b.viewOwner;
      if (owner) enqueue(owner, @{ @"t": @"bv", @"id": @(b.viewId), @"ev": @"message", @"a": m[@"args"] ?: @[] });
    } else if ([m[@"name"] isEqualToString:@"OpenSteamURL"]) {
      // A steam:// link from a BrowserView for Steam to carry out (CMsgOpenSteamURL), on
      // behalf of the window the view is in.
      NSArray *args = m[@"args"];
      AKWHBrowser *view = args.count > 1 ? viewFor(b, [args[1] unsignedIntValue]) : nil;
      AKWHBrowser *window = view.parent.knownToSteam ? view.parent : b;
      NSString *url = [args.firstObject isKindOfClass:NSString.class] ? args.firstObject : @"";
      AKWHLog(YES, @"Steam link from page %u: %@", view.index, url);
      AKWHSend(kAKWHOpenSteamURL, window.handle, @{ @"browser_handle": @(window.handle), @"url": url,
                                                    @"referrer": view.webView.URL.absoluteString ?: @"" });
    } else {
      AKWHLog(NO, @"page %u: Browser.%@ ignored", b.index, m[@"name"]);
    }
  } else if ([op isEqualToString:@"bv-create"]) {
    NSDictionary *options = m[@"options"];
    AKWHBrowser *v = newBrowser(0, options[@"strName"] ?: @"BrowserView", 0);
    v.viewId = [m[@"id"] unsignedIntValue];
    v.viewOwner = b;
    v.parent = browserForIndex([options[@"parentPopupBrowserID"] unsignedIntValue]) ?: (b.type == kSharedJSContextType ? nil : b);
    v.zoom = v.parent ? v.parent.zoom : zoomFor(kMinWidth, kMinHeight);
    v.userAgentFamily = options[@"strUserAgentIdentifier"] ?: b.userAgentFamily;
    WKWebView *wv = makeWebView(v, webConfiguration(), NO);
    wv.hidden = YES;
    [hostView() addSubview:wv];
    layoutBrowser(v);
    // Its first page can come with it (the store's pages do) instead of in a LoadURL.
    NSString *initial = [options[@"strInitialURL"] isKindOfClass:NSString.class] ? options[@"strInitialURL"] : nil;
    NSURL *initialURL = initial.length ? [NSURL URLWithString:initial] : nil;
    if (initialURL) [wv loadRequest:[NSURLRequest requestWithURL:initialURL]];
    AKWHLog(YES, @"BrowserView %u (browser %u) created in window %u%@", v.viewId, v.index, v.parent.index,
            initialURL ? [NSString stringWithFormat:@", loading %@", initial] : @"");
  } else if ([op isEqualToString:@"bv-createpopup"]) {
    AKWHLog(NO, @"BrowserView popup %@ requested: %@", m[@"id"], AKHTMLDescribe(m[@"options"], 300));
  } else if ([op isEqualToString:@"bv"]) {
    browserViewCall(b, viewFor(b, [m[@"id"] unsignedIntValue]), m[@"name"], m[@"args"], m);
  } else if ([op isEqualToString:@"bv-destroy"]) {
    removeBrowser(viewFor(b, [m[@"id"] unsignedIntValue]));
  }
}

#pragma mark Popups

static NSDictionary<NSString *, NSString *> *queryOf(NSURL *url) {
  NSMutableDictionary *q = [NSMutableDictionary dictionary];
  NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
  for (NSURLQueryItem *item in c.queryItems) if (item.value) q[item.name] = item.value;
  return q;
}

- (WKWebView *)webView:(WKWebView *)openerView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
   forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
  AKWHBrowser *opener = browserForWebView(openerView);
  NSURL *url = action.request.URL;
  // A web page in a BrowserView (the store) opening a link in a new window: it opens in the
  // same view, as in a single-window browser.
  if (opener.viewId && !opener.isPopupView) {
    AKWHLog(NO, @"page %u: new window for %@ opens in the same view", opener.index, url);
    if (url && ![url.absoluteString isEqualToString:@"about:blank"]) [openerView loadRequest:action.request];
    return nil;
  }
  NSDictionary *q = queryOf(url);
  NSString *name = @"";
  if (gPendingOpen && [gPendingOpen[@"url"] isEqualToString:url.absoluteString]) name = gPendingOpen[@"name"];
  gPendingOpen = nil;
  BOOL isView = [q[@"browserviewpopup"] isEqualToString:@"1"];
  // A window whose page process ended gives its number to the one replacing it.
  AKWHBrowser *dead = browserForIndex((uint32_t)[q[@"akwh_id"] intValue]);
  if (dead.lostPage && !dead.createdBySteam) {
    dead.knownToSteam = NO;
    removeBrowser(dead);
  }
  AKWHBrowser *b = newBrowser(isView ? 6 : (q[@"browserType"] ? (uint32_t)[q[@"browserType"] intValue] : 3), name,
                              (uint32_t)[q[@"akwh_id"] intValue]);
  if (q[@"akwh_id"] && b.index != (uint32_t)[q[@"akwh_id"] intValue])
    AKWHLog(YES, @"window number %@ was already taken; this window is %u", q[@"akwh_id"], b.index);
  b.userAgentFamily = q[@"useragent"] ?: opener.userAgentFamily;
  if (isView) {
    b.viewId = (uint32_t)[q[@"requestid"] intValue];
    b.viewOwner = opener;
    b.isPopupView = YES;
    b.parent = browserForIndex((uint32_t)[q[@"parentpopup"] intValue]);
    b.zoom = b.parent ? b.parent.zoom : zoomFor(kMinWidth, kMinHeight);
  } else {
    b.zoom = zoomFor([q[@"minwidth"] doubleValue] ?: kMinWidth, [q[@"minheight"] doubleValue] ?: kMinHeight);
  }
  WKWebView *wv = makeWebView(b, configuration, YES);
  if (isView) {
    wv.opaque = NO;
    wv.backgroundColor = UIColor.clearColor;
    wv.scrollView.backgroundColor = UIColor.clearColor;
    wv.hidden = YES;
  } else {
    wv.backgroundColor = UIColor.blackColor;
  }
  [hostView() addSubview:wv];
  layoutBrowser(b);
  if (b.parent) raiseBrowser(b.parent);
  AKWHLog(YES, @"%@ %u \"%@\" opened by %u (zoom %.2f): %@", isView ? @"BrowserView popup" : @"window", b.index, name,
          opener.index, b.zoom, url.absoluteString);
  if (!isView) {
    uint32_t index = b.index;
    logWindows([NSString stringWithFormat:@"window %u opened", index]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      logWindows([NSString stringWithFormat:@"3 s after window %u opened", index]);
    });
  }
  if (!isView && opener.knownToSteam) {
    // Steam Helper tells the client about each window a page opens (BrowserView popups
    // aside): browser_handle is the opener, popup_index the new window's handle. Steam then
    // takes calls from it (it ignored them before) and answers with PopupCreated.
    CGSize s = screenPoints();
    AKWHSend(kAKWHPopupHTMLWindow, opener.handle, @{
      @"browser_handle": @(opener.handle),
      @"url": url.absoluteString ?: @"",
      @"x": @0, @"y": @0,
      @"wide": @((uint32_t)floor(s.width / b.zoom)),
      @"tall": @((uint32_t)floor(s.height / b.zoom)),
      @"popup_index": @(b.handle),
      @"trusted_creator": @YES,
      @"name": name ?: @"",
      @"creation_flags": @((uint32_t)[q[@"createflags"] longLongValue]),
    });
    b.knownToSteam = YES;
  }
  return wv;
}

// Long press: a touch screen's context menu. Chromium's Steam Helper reports it to Steam
// (CMsgTouchGesture, ETouchGesture 5, in the window's CSS pixels), Steam hands it to the
// window's Browser.RegisterForGestureEvents listener, and Big Picture turns it into a
// contextmenu event where the finger is (a game's options, say). WebKit reports no such
// gesture, so this recognizer does, with the tap an iPhone gives for a context menu; the page
// (WebHelperBridge.js) swallows the click WebKit may still make where the finger lifts, so
// the item pressed isn't opened as well. Only for Steam's windows: its listener looks in the
// window, so a press on a menu over it would land on whatever is behind the menu.
- (void)longPressed:(UILongPressGestureRecognizer *)g {
  WKWebView *wv = (WKWebView *)g.view;
  AKWHBrowser *b = browserForWebView(wv);
  if (!b.knownToSteam || b.viewId) return;
  // In the window's CSS pixels: the scroll view's coordinates are the page's, zoomed.
  CGPoint p = [g locationInView:wv.scrollView];
  CGFloat zoom = wv.scrollView.zoomScale > 0 ? wv.scrollView.zoomScale : 1;
  p = CGPointMake(p.x / zoom, p.y / zoom);
  if (g.state == UIGestureRecognizerStateBegan) {
    AKWHSend(kAKWHTouchGesture, b.handle, @{ @"browser_handle": @(b.handle), @"gesture": @5, @"x": @(p.x), @"y": @(p.y) });
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    AKWHLog(NO, @"page %u: long press at %.0f,%.0f", b.index, p.x, p.y);
  }
  if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled)
    [wv evaluateJavaScript:[NSString stringWithFormat:@"window.__akwhLongPress && window.__akwhLongPress(%.1f, %.1f, %@)", p.x, p.y,
                                                      g.state == UIGestureRecognizerStateBegan ? @"false" : @"true"]
         completionHandler:nil];
}

// Alongside WebKit's own recognizers: the press only adds to them.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
  return YES;
}

// WebKit's private input delegate: asked before a focused field brings up the keyboard. Only
// a field the finger just tapped gets the iPhone's keyboard (_WKFocusStartsInputSessionPolicy
// 1, allow); focus from anything else stays without it (2, disallow) - with a controller,
// Big Picture shows its own keyboard, and the keys it types arrive through evaluateJavaScript,
// which WebKit counts as the user's doing, so the iPhone's came up with every letter.
- (NSInteger)_webView:(WKWebView *)webView decidePolicyForFocusedElement:(id)info {
  BOOL tapped = CACurrentMediaTime() - gLastTouch < 1.5;
  static unsigned logged;
  if (++logged <= 100) {
    id type = nil, placeholder = nil;
    @try {
      type = [info valueForKey:@"type"];
      placeholder = [info valueForKey:@"placeholder"];
    } @catch (NSException *e) {
    }
    AKWHLog(NO, @"page %u: field focused (input type %@, placeholder \"%@\"): %@", browserForWebView(webView).index, type,
            placeholder ?: @"", tapped ? @"tapped, keyboard shown" : @"not tapped, no keyboard");
  }
  return tapped ? 1 : 2;
}

- (void)webViewDidClose:(WKWebView *)webView {
  AKWHBrowser *b = browserForWebView(webView);
  if (b && !b.createdBySteam) removeBrowser(b);
}

// The bridge's synchronous questions arrive as prompts and are answered at once.
- (void)webView:(WKWebView *)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSString *))completionHandler {
  AKWHBrowser *b = browserForWebView(webView);
  if ([prompt isEqualToString:@"akwh-sync:browser-id"] && b) {
    completionHandler(jsonString(@{ @"id": @(b.index), @"handle": @(b.handle) }));
    return;
  }
  AKWHLog(NO, @"page %u prompt ignored: %@", b.index, prompt);
  completionHandler(nil);
}

- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame
    completionHandler:(void (^)(void))completionHandler {
  AKWHLog(YES, @"page %u alert: %@", browserForWebView(webView).index, message);
  completionHandler();
}

- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame
    completionHandler:(void (^)(BOOL))completionHandler {
  AKWHLog(YES, @"page %u confirm (answered yes): %@", browserForWebView(webView).index, message);
  completionHandler(YES);
}

#pragma mark Navigation

static void viewEvent(AKWHBrowser *v, NSString *event, NSArray *args) {
  if (v.viewOwner && v.viewId && !v.isPopupView) enqueue(v.viewOwner, @{ @"t": @"bv", @"id": @(v.viewId), @"ev": event, @"a": args });
}

// A BrowserView's history the way Steam Helper reports it: {index, entries: [{url}]}, the
// back-forward list oldest first and the one showing. Big Picture's store keeps its own
// navigation in step with it (a bare address there made it navigate again: the page kept
// jumping back to its top, and Back stopped working).
static void historyChanged(AKWHBrowser *b) {
  WKWebView *wv = b.webView;
  if (!wv || !b.viewId || b.isPopupView) return;
  WKBackForwardList *list = wv.backForwardList;
  NSMutableArray *entries = [NSMutableArray array];
  for (WKBackForwardListItem *item in list.backList) [entries addObject:@{ @"url": item.URL.absoluteString ?: @"" }];
  NSUInteger index = entries.count;
  [entries addObject:@{ @"url": (list.currentItem.URL ?: wv.URL).absoluteString ?: @"" }];
  for (WKBackForwardListItem *item in list.forwardList) [entries addObject:@{ @"url": item.URL.absoluteString ?: @"" }];
  viewEvent(b, @"history-changed", @[ @{ @"index": @(index), @"entries": entries } ]);
  viewEvent(b, @"can-go-back-forward-changed", @[ @(wv.canGoBack), @(wv.canGoForward) ]);
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
  AKWHBrowser *b = browserForWebView(webView);
  NSString *scheme = action.request.URL.scheme.lowercaseString;
  // steam:// links in a BrowserView (the store's Install and Play buttons) go to the view's
  // Steam URL callback, which hands them to Steam, as Steam Helper does.
  if ([scheme isEqualToString:@"steam"] && b.viewOwner && b.viewId) {
    enqueue(b.viewOwner, @{ @"t": @"bv", @"id": @(b.viewId), @"ev": @"steam-url", @"a": @[ action.request.URL.absoluteString ?: @"" ] });
    decisionHandler(WKNavigationActionPolicyCancel);
    return;
  }
  if ([scheme isEqualToString:@"steam"] && b.knownToSteam) {   // from one of Steam's windows
    AKWHSend(kAKWHOpenSteamURL, b.handle, @{ @"browser_handle": @(b.handle), @"url": action.request.URL.absoluteString ?: @"",
                                             @"referrer": webView.URL.absoluteString ?: @"" });
    decisionHandler(WKNavigationActionPolicyCancel);
    return;
  }
  if (scheme && ![@[ @"https", @"http", @"about", @"blob", @"data" ] containsObject:scheme]) {
    AKWHLog(YES, @"page %u: not following %@", b.index, action.request.URL);
    decisionHandler(WKNavigationActionPolicyCancel);
    return;
  }
  if (action.targetFrame.isMainFrame) viewEvent(b, @"start-request", @[ action.request.URL.absoluteString ?: @"" ]);
  decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
  AKWHBrowser *b = browserForWebView(webView);
  viewEvent(b, @"start-loading", @[ webView.URL.absoluteString ?: @"" ]);
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
  AKWHBrowser *b = browserForWebView(webView);
  NSString *url = webView.URL.absoluteString ?: @"";
  closeSockets(b);   // the previous document's
  if (b.knownToSteam)
    AKWHSend(kAKWHURLChanged, b.handle, @{ @"browser_handle": @(b.handle), @"url": url, @"bNewNavigation": @YES });
  historyChanged(b);
}

// A page moving within its document (history.pushState, an anchor): a new history entry.
- (void)_webView:(WKWebView *)webView navigation:(WKNavigation *)navigation didSameDocumentNavigation:(NSInteger)type {
  historyChanged(browserForWebView(webView));
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
  AKWHBrowser *b = browserForWebView(webView);
  NSString *url = webView.URL.absoluteString ?: @"";
  NSString *title = webView.title ?: @"";
  AKWHLog(YES, @"page %u loaded: %@ \"%@\"", b.index, url, title);
  if (b.knownToSteam) {
    AKWHSend(kAKWHFinishedRequest, b.handle, @{ @"browser_handle": @(b.handle), @"url": url, @"pageTitle": title });
    AKWHSend(kAKWHSetHTMLTitle, b.handle, @{ @"browser_handle": @(b.handle), @"title": title });
  }
  viewEvent(b, @"finished-request", @[ url, title ]);
  viewEvent(b, @"set-title", @[ title ]);
  viewEvent(b, @"can-go-back-forward-changed", @[ @(webView.canGoBack), @(webView.canGoForward) ]);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
  AKWHBrowser *b = browserForWebView(webView);
  AKWHLog(YES, @"page %u failed to load: %@", b.index, error.localizedDescription);
  viewEvent(b, @"load-error", @[ @(error.code), error.userInfo[NSURLErrorFailingURLStringErrorKey] ?: @"", error.localizedDescription ?: @"" ]);
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
  AKWHLog(YES, @"page %u stopped loading: %@", browserForWebView(webView).index, error.localizedDescription);
}

// A page process ended. Steam's own pages share one (its windows are the shared context's
// popups), so its whole interface goes at once. Steam Helper restarts Chromium's renderer
// for its browsers, but Steam's script and windows can't be put back by reloading pages here
// (the interface came back as a Steam logo that never finished loading): Steam has to build
// them again. So the helper ends as a crashed Steam Helper does - its pages are cleared off
// the screen without telling Steam they closed (Big Picture's window asked for Steam to quit
// with it) - and Steam's client starts a new helper and its interface, still signed in. A web
// page in a BrowserView (the store) has a process of its own and just reloads.

static NSString *terminationReason(NSInteger reason) {
  switch (reason) {   // _WKProcessTerminationReason
    case 0: return @"it went over its memory limit";
    case 1: return @"it used too much CPU";
    case 2: return @"the app asked";
    case 3: return @"it crashed (or iOS ended it for memory)";
    default: return [NSString stringWithFormat:@"WebKit reason %ld", (long)reason];
  }
}

static void restartForSteam(void) {
  if (gRestarting) return;
  gRestarting = YES;
  AKWHLog(YES, @"Steam's interface lost its page process; ending this helper so Steam starts a new one");
  for (AKWHBrowser *b in [gBrowsers copy]) {
    b.knownToSteam = NO;
    removeBrowser(b);
  }
  gBrowsers = nil;
  gMethods = nil;
  gMethodOwner = 0;
  gBridgeInstalled = NO;
  gSteamConfig = nil;   // a new one, with the bridge script for the new helper's methods
  gPendingOpen = nil;
  gNextIndex = 0x4000;
  gSystemKeyHandle = 0;
  gSteamSendsSystemKeys = NO;
  AKWHExitForRestart();
}

static void pageProcessEnded(WKWebView *webView, NSString *why) {
  AKWHBrowser *b = browserForWebView(webView);
  if (!b || b.lostPage) return;
  b.lostPage = YES;
  AKWHLog(YES, @"page %u's web content process ended: %@", b.index, why);
  closeSockets(b);
  if (!(b.viewId && !b.isPopupView)) {
    // One of Steam's pages: the others went with it. After this turn (they all report now).
    dispatch_async(dispatch_get_main_queue(), ^{ restartForSteam(); });
  } else {
    b.lostPage = NO;
    [webView reload];
  }
}

- (void)_webView:(WKWebView *)webView webContentProcessDidTerminateWithReason:(NSInteger)reason {
  pageProcessEnded(webView, terminationReason(reason));
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
  pageProcessEnded(webView, @"WebKit gave no reason");
}

@end

#pragma mark Where touches and the keyboard go

// For the log: what the first touches land on, every window in the app and what is in front
// of the stage when a Steam window opens, and what the keyboard comes up and goes away for.
// A page that doesn't respond to taps, or a keyboard that flickers, then names its cause
// (a window over the app, a view over the page, focus moving between views).

static NSString *describeView(UIView *v) {
  NSMutableArray *chain = [NSMutableArray array];
  for (UIView *u = v; u && chain.count < 6; u = u.superview) {
    if ([u isKindOfClass:WKWebView.class]) {
      AKWHBrowser *b = browserForWebView((WKWebView *)u);
      [chain addObject:[NSString stringWithFormat:@"page %u's web view", b.index]];
      break;
    }
    if (u == gStage) { [chain addObject:@"stage"]; break; }
    [chain addObject:NSStringFromClass(u.class)];
  }
  return chain.count ? [chain componentsJoinedByString:@" in "] : @"nothing";
}

static void logWindows(NSString *when) {
  NSMutableArray *lines = [NSMutableArray array];
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    for (UIWindow *w in ((UIWindowScene *)scene).windows)
      [lines addObject:[NSString stringWithFormat:@"%@ level %.0f%@%@ %@", NSStringFromClass(w.class), w.windowLevel,
                                                  w.hidden ? @" hidden" : @"", w.isKeyWindow ? @" key" : @"",
                                                  NSStringFromCGRect(w.frame)]];
  }
  UIView *app = gStage.superview;
  NSMutableArray *views = [NSMutableArray array];
  for (UIView *v in app.subviews)
    [views addObject:[NSString stringWithFormat:@"%@%@%@", v == gStage ? @"stage" : NSStringFromClass(v.class),
                                                v.hidden ? @" hidden" : @"", v.alpha < 1 ? [NSString stringWithFormat:@" alpha %.2f", v.alpha] : @""]];
  AKWHLog(NO, @"%@: windows [%@]; app view, back to front: [%@]", when, [lines componentsJoinedByString:@"; "],
          [views componentsJoinedByString:@", "]);
}

@interface AKWHTouchWatcher : UIGestureRecognizer
@end

@implementation AKWHTouchWatcher
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  gLastTouch = CACurrentMediaTime();
  static unsigned logged;
  UITouch *t = touches.anyObject;
  if (++logged <= 30) AKWHLog(NO, @"touch at %@ lands on %@", NSStringFromCGPoint([t locationInView:nil]), describeView(t.view));
  if (logged == 1) logWindows(@"first touch");
  self.state = UIGestureRecognizerStateFailed;   // only watching
}
@end

static __weak UIResponder *gFoundResponder;

@interface UIResponder (AKWHFirstResponder)
- (void)akwh_reportFirstResponder:(id)sender;
@end

@implementation UIResponder (AKWHFirstResponder)
- (void)akwh_reportFirstResponder:(id)sender { gFoundResponder = self; }
@end

static NSString *firstResponderDescription(void) {
  gFoundResponder = nil;
  [UIApplication.sharedApplication sendAction:@selector(akwh_reportFirstResponder:) to:nil from:nil forEvent:nil];
  UIResponder *r = gFoundResponder;
  if (!r) return @"nothing";
  return [r isKindOfClass:UIView.class] ? describeView((UIView *)r) : NSStringFromClass(r.class);
}

static void watchTouchesAndKeyboard(UIWindow *window) {
  if (!window) return;
  AKWHTouchWatcher *watcher = [[AKWHTouchWatcher alloc] initWithTarget:nil action:nil];
  watcher.cancelsTouchesInView = NO;
  watcher.delaysTouchesBegan = NO;
  watcher.delaysTouchesEnded = NO;
  [window addGestureRecognizer:watcher];
  static unsigned logged;
  NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
  [nc addObserverForName:UIKeyboardWillShowNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
    if (++logged <= 60) AKWHLog(NO, @"keyboard up, for %@", firstResponderDescription());
  }];
  [nc addObserverForName:UIKeyboardWillHideNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
    if (++logged <= 60) AKWHLog(NO, @"keyboard down; focus now on %@", firstResponderDescription());
  }];
}

#pragma mark Keys Steam types

// Steam's on-screen keyboard (Big Picture's, played with a controller) types through the
// Steam client, which on a Mac posts key events to the focused app (CGEvents.m hands them
// here). They go to the focused page's focused field: text as typed text
// (execCommand('insertText'), which fires the same input events typing does), Backspace and
// Delete as deletions, Enter as Enter (a one-line field's form is submitted, as a browser
// does), the arrows move the caret; each key also reaches the page's key handlers first,
// which may take it. The keyboard's paste (Command-V) pastes the clipboard.

// The page with the keyboard focus: the web view that is first responder, else the front
// visible one.
static WKWebView *focusedWebView(void) {
  gFoundResponder = nil;
  [UIApplication.sharedApplication sendAction:@selector(akwh_reportFirstResponder:) to:nil from:nil forEvent:nil];
  for (UIView *v = [gFoundResponder isKindOfClass:UIView.class] ? (UIView *)gFoundResponder : nil; v; v = v.superview)
    if ([v isKindOfClass:WKWebView.class] && browserForWebView((WKWebView *)v)) return (WKWebView *)v;
  for (UIView *v in gStage.subviews.reverseObjectEnumerator) {
    if (![v isKindOfClass:WKWebView.class] || v.hidden || v.bounds.size.width < 2) continue;
    AKWHBrowser *b = browserForWebView((WKWebView *)v);
    if (b && b.type != kSharedJSContextType) return (WKWebView *)v;
  }
  return nil;
}

static NSString *namedKey(uint16_t code, NSString *text) {
  switch (code) {   // Mac virtual key codes
    case 0x33: return @"Backspace";
    case 0x24: case 0x4C: return @"Enter";
    case 0x30: return @"Tab";
    case 0x35: return @"Escape";
    case 0x75: return @"Delete";
    case 0x7B: return @"ArrowLeft";
    case 0x7C: return @"ArrowRight";
    case 0x7D: return @"ArrowDown";
    case 0x7E: return @"ArrowUp";
    case 0x73: return @"Home";
    case 0x77: return @"End";
  }
  if ([text isEqualToString:@"\b"] || [text isEqualToString:@"\x7f"]) return @"Backspace";
  if ([text isEqualToString:@"\r"] || [text isEqualToString:@"\n"]) return @"Enter";
  if ([text isEqualToString:@"\t"]) return @"Tab";
  if ([text isEqualToString:@"\x1b"]) return @"Escape";
  return nil;
}

static NSString *const kTypeKeyScript =
  @"(function (down, key, text, paste) {"
   "  var el = document.activeElement;"
   "  if (!el || el === document.body) return 'nothing focused';"
   "  var codes = { Backspace: 8, Tab: 9, Enter: 13, Escape: 27, End: 35, Home: 36, ArrowLeft: 37, ArrowUp: 38,"
   "                ArrowRight: 39, ArrowDown: 40, Delete: 46 };"
   "  var kc = codes[key] || (text ? text.toUpperCase().charCodeAt(0) : 0);"
   "  var ev = new KeyboardEvent(down ? 'keydown' : 'keyup', { key: key || text, bubbles: true, cancelable: true });"
   "  try { Object.defineProperty(ev, 'keyCode', { get: function () { return kc; } });"
   "        Object.defineProperty(ev, 'which', { get: function () { return kc; } }); } catch (e) {}"
   "  if (!el.dispatchEvent(ev) || !down) return 'handled by the page';"
   "  if (paste !== null) { document.execCommand('insertText', false, paste); return 'pasted'; }"
   "  if (text) { document.execCommand('insertText', false, text); return 'typed'; }"
   "  if (key === 'Backspace') document.execCommand('delete');"
   "  else if (key === 'Delete') document.execCommand('forwardDelete');"
   "  else if (key === 'Enter') {"
   "    if (el.tagName === 'TEXTAREA' || el.isContentEditable) document.execCommand('insertLineBreak');"
   "    else if (el.form) { if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit(); }"
   "  } else if ((key === 'ArrowLeft' || key === 'ArrowRight' || key === 'Home' || key === 'End') &&"
   "             typeof el.selectionStart === 'number' && el.value !== undefined) {"
   "    var p = key === 'Home' ? 0 : key === 'End' ? el.value.length : el.selectionStart + (key === 'ArrowLeft' ? -1 : 1);"
   "    p = Math.max(0, Math.min(el.value.length, p)); el.setSelectionRange(p, p);"
   "  }"
   "  return key;"
   "})";

void AKWHTypeKey(BOOL down, uint16_t keyCode, NSString *text, BOOL command) {
  WKWebView *wv = focusedWebView();
  if (!wv) return;
  NSString *key = namedKey(keyCode, text);
  id paste = NSNull.null;
  if (command) {
    if (keyCode != 0x09 || !down) return;   // V; the keyboard's other shortcuts aren't used here
    paste = UIPasteboard.generalPasteboard.string ?: @"";
  }
  if (!key && !text.length && paste == NSNull.null) return;
  NSArray *args = @[ @(down), key ?: @"", key ? @"" : (text ?: @""), paste ];
  NSString *json = jsonString(args);
  NSString *call = [NSString stringWithFormat:@"%@(%@)", kTypeKeyScript, [json substringWithRange:NSMakeRange(1, json.length - 2)]];
  static unsigned logged;
  BOOL log = down && ++logged <= 20;
  uint32_t index = browserForWebView(wv).index;
  [wv evaluateJavaScript:call completionHandler:^(id result, NSError *error) {
    if (log) AKWHLog(NO, @"key %@ for page %u: %@", key ?: @"(text)", index, error ? error.localizedDescription : result);
  }];
}
