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
// Here every browser is a WKWebView in the app's window. The shared context's is 1x1 at the
// back (it must stay in the window, or WebKit stops its timers and animation frames); popups
// fill the screen, and BrowserViews sit where their parent's script puts them. All of them
// share one configuration, so the popups belong to the shared context's page (same process,
// direct access to their documents) and load https through WebHelperLoopback.m. Big Picture
// lays itself out for at least its window's minwidth/minheight (853x534) CSS pixels; a phone in
// landscape is about 932x430 points, so popups are zoomed out until that fits.
#import <UIKit/UIKit.h>
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
@property(nonatomic, strong) NSMutableArray *outbox;   // messages for the page, sent together
@property(nonatomic) CFAbsoluteTime pingSent;           // see startWatchingPages
@property(nonatomic) unsigned stuckReports;
@end
@implementation AKWHBrowser
@end

@interface AKWHWebDelegate : NSObject <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler>
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

static void closeSockets(AKWHBrowser *b);

#pragma mark Browsers

static UIView *hostView(void) {
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    for (UIWindow *w in ((UIWindowScene *)scene).windows)
      if (w.rootViewController.view) return w.rootViewController.view;
  }
  return nil;
}

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

static WKWebViewConfiguration *steamConfiguration(void) {
  if (gSteamConfig) return gSteamConfig;
  if (!gDelegate) gDelegate = [AKWHWebDelegate new];
  hideKeyboardBar();
  WKWebViewConfiguration *c = [WKWebViewConfiguration new];
  c.preferences.javaScriptCanOpenWindowsAutomatically = YES;
  c.allowsInlineMediaPlayback = YES;
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
  c = [WKWebViewConfiguration new];
  c.allowsInlineMediaPlayback = YES;
  c.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
  c.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
  c.userContentController = [WKUserContentController new];
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
    // Steam's windows are apps, not documents: they lay out to the window and scroll inside.
    wv.scrollView.bounces = NO;
    wv.scrollView.scrollEnabled = NO;
  }
  if (@available(iOS 14.0, *)) wv.pageZoom = b.zoom;
  if (@available(iOS 16.4, *)) wv.inspectable = YES;
  // WebKit asks this before a focused field brings up the keyboard (logged, see
  // _webView:decidePolicyForFocusedElement:).
  SEL setInputDelegate = NSSelectorFromString(@"_setInputDelegate:");
  if ([wv respondsToSelector:setInputDelegate])
    ((void (*)(id, SEL, id))[wv methodForSelector:setInputDelegate])(wv, setInputDelegate, gDelegate);
  b.webView = wv;
  return wv;
}

// Where a browser's view goes: popups fill the screen; BrowserViews take their bounds (CSS
// pixels of the parent window) scaled by the parent's zoom; the shared context stays 1x1.
static void layoutBrowser(AKWHBrowser *b) {
  UIView *host = hostView();
  if (!b.webView || !host) return;
  if (b.type == kSharedJSContextType) {
    b.webView.frame = CGRectMake(0, 0, 1, 1);
    b.webView.autoresizingMask = UIViewAutoresizingNone;
  } else if (b.viewId) {
    AKWHBrowser *parent = b.parent;
    CGRect pf = parent.webView ? parent.webView.frame : host.bounds;
    double z = parent ? parent.zoom : b.zoom;
    b.webView.autoresizingMask = UIViewAutoresizingNone;
    b.webView.frame = CGRectMake(pf.origin.x + b.cssBounds.origin.x * z, pf.origin.y + b.cssBounds.origin.y * z,
                                 b.cssBounds.size.width * z, b.cssBounds.size.height * z);
    b.webView.hidden = !b.viewVisible || b.cssBounds.size.width <= 0 || b.cssBounds.size.height <= 0;
  } else {
    b.webView.frame = host.bounds;
    b.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
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
static void startWatchingPages(void) {
  static NSTimer *timer;
  if (timer) return;
  timer = [NSTimer timerWithTimeInterval:5 repeats:YES block:^(NSTimer *t) {
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
}

static void createSteamBrowser(uint32_t requestId, NSDictionary *msg) {
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
  if ([url isEqualToString:b.loadedURL]) return;   // Steam sends its first URL twice
  b.loadedURL = url;
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
  } else if ([name isEqualToString:@"LoadURL"] && args.count) {
    NSURL *url = [NSURL URLWithString:args[0]];
    if (url) [v.webView loadRequest:[NSURLRequest requestWithURL:url]];
  } else if ([name isEqualToString:@"Reload"]) {
    [v.webView reload];
  } else if ([name isEqualToString:@"GoBack"]) {
    [v.webView goBack];
  } else if ([name isEqualToString:@"GoForward"]) {
    [v.webView goForward];
  } else if ([name isEqualToString:@"SetFocus"]) {
    if ([args.firstObject boolValue]) [v.webView becomeFirstResponder];
  } else if ([name isEqualToString:@"PostMessage"]) {
    enqueue(v, @{ @"t": @"parent-message", @"a": args ?: @[] });
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
  if ([op isEqualToString:@"call"]) {
    AKWHSend(kAKWHJSMethodCall, b.handle, @{
      @"browser_handle": @(b.handle),
      @"owning_browser_handle": @(gMethodOwner ?: b.handle),
      @"name": m[@"name"] ?: @"",
      @"arguments": globalizeHandles(m[@"args"] ?: @[], b),
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
    AKWHLog(YES, @"BrowserView %u (browser %u) created in window %u", v.viewId, v.index, v.parent.index);
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
  NSDictionary *q = queryOf(url);
  NSString *name = @"";
  if (gPendingOpen && [gPendingOpen[@"url"] isEqualToString:url.absoluteString]) name = gPendingOpen[@"name"];
  gPendingOpen = nil;
  BOOL isView = [q[@"browserviewpopup"] isEqualToString:@"1"];
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

// WebKit's private input delegate: asked before a focused field starts a keyboard session.
// The answer stays WebKit's own (0, "automatic": only for focus the user caused); each
// request is logged so focus that keeps bouncing shows up in the log.
- (NSInteger)_webView:(WKWebView *)webView decidePolicyForFocusedElement:(id)info {
  static unsigned logged;
  if (++logged <= 200) {
    id type = nil, byUser = nil, placeholder = nil;
    @try {
      type = [info valueForKey:@"type"];
      byUser = [info valueForKey:@"userInitiated"];
      placeholder = [info valueForKey:@"placeholder"];
    } @catch (NSException *e) {
    }
    AKWHLog(YES, @"page %u: keyboard asked for a focused field (input type %@, by the user %@, placeholder \"%@\")",
            browserForWebView(webView).index, type, byUser, placeholder ?: @"");
  }
  return 0;
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

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
  NSString *scheme = action.request.URL.scheme.lowercaseString;
  if (scheme && ![@[ @"https", @"http", @"about", @"blob", @"data" ] containsObject:scheme]) {
    AKWHLog(YES, @"page %u: not following %@", browserForWebView(webView).index, action.request.URL);
    decisionHandler(WKNavigationActionPolicyCancel);
    return;
  }
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
  viewEvent(b, @"history-changed", @[ url ]);
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

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
  AKWHBrowser *b = browserForWebView(webView);
  AKWHLog(YES, @"page %u's web content process ended (out of memory, or a crash); reloading it", b.index);
  if (b.createdBySteam) [webView reload];
}

@end
