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
  kAKWHJSReleaseCallback = 37,
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
  kAKWHFinishedRequest = 99,
  kAKWHJSMethodCall = 110,
  kAKWHSetHTMLTitle = 131,
  kAKWHURLChanged = 144,
};

// Documents/web-helper.log (and the console when asked).
void AKWHLog(BOOL console, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
NSString *AKWHCommandName(uint32_t cmd);

// Send a command to Steam's client. Any thread.
BOOL AKWHSend(uint32_t cmd, uint32_t browser, NSDictionary *fields);

// A command from Steam, delivered on the main thread in the order Steam sent them.
void AKWHWebHandleCommand(uint32_t cmd, uint32_t browser, NSDictionary *msg);

// Serve https loads of web views made with this configuration through the app: mapped hosts
// from local files, everything else through NSURLSession. Main thread.
void AKWHLoopbackInstall(WKWebViewConfiguration *configuration);
void AKWHLoopbackMapHost(NSString *host, NSString *root, NSArray<NSDictionary *> *routes);
void AKWHLoopbackSetCookie(NSDictionary *cookie);
