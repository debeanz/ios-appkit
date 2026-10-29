// The Safari-engine web helper's parts: WebHelper.m (Steam's side of the protocol and the
// connection), WebHelperWeb.m (the WKWebViews and the SteamClient bridge) and
// WebHelperLoopback.m (https://steamloopback.host and the other hosts Steam maps to files).
#import <Foundation/Foundation.h>

@class WKWebViewConfiguration;

// eHTMLCommands values used by the helper (data/htmlcommands.json has them all).
enum {
  kAKWHBrowserCreate = 3,
  kAKWHBrowserRemove = 6,
  kAKWHBrowserSetName = 8,
  kAKWHExecuteJavaScript = 18,
  kAKWHGoBack = 26,
  kAKWHGoForward = 27,
  kAKWHJSExecuteCallback = 33,
  kAKWHJSExecutePromise = 34,
  kAKWHJSRaiseException = 35,
  kAKWHJSRegisterMethod = 36,
  kAKWHOpenSteamURL = 41,
  kAKWHJSReleaseCallback = 37,
  kAKWHPopupCreated = 44,
  kAKWHPostURL = 45,
  kAKWHReload = 46,
  kAKWHSetBrowserViewDomainRequestMapping = 54,
  kAKWHBuildID = 55,
  kAKWHSetCookie = 56,
  kAKWHSetLocalFileRequestMapping = 60,
  kAKWHSetWindowVisibility = 73,
  kAKWHStopLoad = 79,
  kAKWHWasHidden = 83,
  kAKWHBrowserCreateResponse = 88,
  kAKWHBrowserReady = 90,
  kAKWHClose = 93,
  kAKWHFinishedRequest = 99,
  kAKWHJSMethodCall = 110,
  kAKWHPopupHTMLWindow = 122,
  kAKWHRenderProcessTerminated = 124,
  kAKWHSetHTMLTitle = 131,
  kAKWHTouchGesture = 143,
  kAKWHURLChanged = 144,
};

// Documents/web-helper.log (and the console when asked).
void AKWHLog(BOOL console, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
NSString *AKWHCommandName(uint32_t cmd);

// Send a command to Steam's client. Any thread.
BOOL AKWHSend(uint32_t cmd, uint32_t browser, NSDictionary *fields);

// End this helper as a crashed Steam Helper would, so Steam starts a new one (WebHelper.m).
void AKWHExitForRestart(void);

// A command from Steam, delivered on the main thread in the order Steam sent them.
void AKWHWebHandleCommand(uint32_t cmd, uint32_t browser, NSDictionary *msg);

// Serve https loads of web views made with this configuration through the app: mapped hosts
// from local files, everything else through NSURLSession. Main thread.
void AKWHLoopbackInstall(WKWebViewConfiguration *configuration);
void AKWHLoopbackMapHost(NSString *host, NSString *root, NSArray<NSDictionary *> *routes);
void AKWHLoopbackSetCookie(NSDictionary *cookie);

// Steam's encrypted interface fonts (WebHelperFonts.m): where clientui and the Steam Helper
// binary (which holds the key) are, and the font a /custom_fonts/*.uifont?<name> URL names.
void AKWHFontsSetPaths(NSString *clientUI, NSString *helperBinary);
NSData *AKWHFontForURL(NSURL *url);

// Controllers (WebHelperGamepad.m) and what they send the pages (WebHelperWeb.m): a button
// as SteamClient.Input's controller message (EGamepadButton code), and Steam's system keys
// (0 the Steam menu, 1 Quick Access) through the page's RegisterForSystemKeyEvents callback.
// Main thread.
void AKWHGamepadStart(void);
void AKWHSendControllerButton(uint32_t controller, uint32_t button, BOOL pressed);
void AKWHSendSystemKey(uint32_t key, uint32_t controller);
// WebHelperGamepad.m: one of Big Picture's popups shown or hidden (its menus over a game).
void AKWHGameOverlayMenu(NSString *name, BOOL visible);
