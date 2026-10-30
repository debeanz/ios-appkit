// The app's side of the Quick Access additions (WebHelperDeck.js, in Steam's interface page):
// Steam's Performance state (GameProfiles.m), the Plugins tab's built-ins (Display: brightness and
// keeping the screen on; Logs: every log, zipped, to the share sheet) and the user's plugins in
// Documents/plugins. WebHelperWeb.m passes the page's calls here and sends the replies back.
#import <UIKit/UIKit.h>
#import "AKShimPrivate.h"
#import "WebHelper.h"

static void (^gPush)(NSString *event, id value);

void AKWHDeckSetPush(void (^push)(NSString *event, id value)) { gPush = [push copy]; }

static NSString *documents(void) {
  return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

#pragma mark Display

// Keeping the screen on: "playing" (while a game runs: a controller's input doesn't count as a
// touch, so the phone would lock itself mid-game), "always", or "off" (iOS's own auto-lock).
static NSString *keepAwakeMode(void) {
  NSString *mode = [NSUserDefaults.standardUserDefaults stringForKey:@"AKKeepAwake"];
  return [@[ @"playing", @"always", @"off" ] containsObject:mode] ? mode : @"playing";
}

static void applyKeepAwake(void) {
  NSString *mode = keepAwakeMode();
  BOOL on = [mode isEqualToString:@"always"] || ([mode isEqualToString:@"playing"] && AKGameIsRunning());
  if (UIApplication.sharedApplication.idleTimerDisabled != on) UIApplication.sharedApplication.idleTimerDisabled = on;
}

static NSDictionary *displayState(void) {
  return @{ @"brightness": @(UIScreen.mainScreen.brightness), @"keepAwake": keepAwakeMode() };
}

// Steam's Performance state changed (settings, or a game started or ended): to the page, and the
// screen's keep-awake follows the game.
void AKWHPerfStateChanged(void) {
  applyKeepAwake();
  if (gPush) gPush(@"perf-state", AKPerfState());
}

#pragma mark Logs

// Every log the app and Steam write: the app's in Documents (launch, Steam's console, the web
// helper, crashes, games), Steam's own folders (Documents/steam-logs, and logs/ under Steam's data
// root), copied into one folder and zipped the way the Files app zips a folder for sharing.
static NSArray<NSURL *> *logFiles(void) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSMutableArray<NSURL *> *files = [NSMutableArray array];
  NSURL *docs = [NSURL fileURLWithPath:documents()];
  for (NSURL *url in [fm contentsOfDirectoryAtURL:docs includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL]) {
    NSString *ext = url.pathExtension.lowercaseString;
    NSNumber *isDir;
    [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:NULL];
    if (!isDir.boolValue && ([ext isEqualToString:@"log"] || [ext isEqualToString:@"txt"] || [ext isEqualToString:@"ips"])) [files addObject:url];
  }
  NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
  for (NSString *dir in @[ [documents() stringByAppendingPathComponent:@"steam-logs"], [support stringByAppendingPathComponent:@"Steam/logs"] ]) {
    for (NSURL *url in [fm enumeratorAtURL:[NSURL fileURLWithPath:dir] includingPropertiesForKeys:@[ NSURLIsRegularFileKey ] options:0 errorHandler:nil]) {
      NSNumber *regular;
      [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:NULL];
      if (regular.boolValue) [files addObject:url];
    }
  }
  return files;
}

static UIViewController *topController(void) {
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    for (UIWindow *w in ((UIWindowScene *)scene).windows) {
      UIViewController *c = w.rootViewController;
      while (c.presentedViewController) c = c.presentedViewController;
      if (c) return c;
    }
  }
  return nil;
}

static void shareLogs(void (^reply)(id)) {
  NSArray<NSURL *> *files = logFiles();
  if (!files.count) { reply(@{ @"ok": @NO, @"error": @"there are no logs yet" }); return; }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd HH.mm.ss";
    NSString *name = [NSString stringWithFormat:@"Steam logs %@", [f stringFromDate:NSDate.date]];
    NSString *work = [NSTemporaryDirectory() stringByAppendingPathComponent:@"logs-share"];
    [fm removeItemAtPath:work error:NULL];
    NSString *folder = [work stringByAppendingPathComponent:name];
    [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *docs = [documents() stringByAppendingString:@"/"];
    NSString *support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingString:@"/"];
    unsigned long long bytes = 0;
    NSUInteger copied = 0;
    for (NSURL *url in files) {
      NSString *path = url.path, *rel = path.lastPathComponent;
      if ([path hasPrefix:docs]) rel = [path substringFromIndex:docs.length];
      else if ([path hasPrefix:support]) rel = [path substringFromIndex:support.length];
      NSString *to = [folder stringByAppendingPathComponent:rel];
      [fm createDirectoryAtPath:to.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
      if ([fm copyItemAtPath:path toPath:to error:NULL]) {
        copied++;
        bytes += [[fm attributesOfItemAtPath:to error:NULL] fileSize];
      }
    }
    __block NSURL *zip = nil;
    NSError *error = nil;
    NSString *zipPath = [work stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"zip"]];
    [[NSFileCoordinator new] coordinateReadingItemAtURL:[NSURL fileURLWithPath:folder] options:NSFileCoordinatorReadingForUploading
                                                  error:&error byAccessor:^(NSURL *zipped) {
      if ([fm copyItemAtPath:zipped.path toPath:zipPath error:NULL]) zip = [NSURL fileURLWithPath:zipPath];
    }];
    NSString *size = [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!zip) { reply(@{ @"ok": @NO, @"error": error.localizedDescription ?: @"zipping failed" }); return; }
      UIViewController *top = topController();
      if (!top) { reply(@{ @"ok": @NO, @"error": @"no window to show the share sheet in" }); return; }
      UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[ zip ] applicationActivities:nil];
      sheet.popoverPresentationController.sourceView = top.view;
      sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
      sheet.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *e) {
        [NSFileManager.defaultManager removeItemAtPath:work error:NULL];
      };
      [top presentViewController:sheet animated:YES completion:nil];
      AKWHLog(YES, @"sharing %lu log files (%@) as %@", (unsigned long)copied, size, zip.lastPathComponent);
      reply(@{ @"ok": @YES, @"files": @(copied), @"size": size });
    });
  });
}

#pragma mark Plugins

static NSString *pluginsFolder(void) {
  NSString *dir = [documents() stringByAppendingPathComponent:@"plugins"];
  NSFileManager *fm = NSFileManager.defaultManager;
  if (![fm fileExistsAtPath:dir]) [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
  NSString *readme = [dir stringByAppendingPathComponent:@"README.txt"];
  if (![fm fileExistsAtPath:readme]) {
    NSString *text =
      @"Plugins for Steam's Quick Access menu (the plug tab)\n"
       "=====================================================\n\n"
       "Each plugin is a folder here with two files:\n\n"
       "  plugin.json   {\"name\": \"My plugin\", \"version\": \"1.0\", \"author\": \"me\",\n"
       "                 \"description\": \"What it does\", \"main\": \"index.js\"}\n"
       "  index.js      the plugin's script (\"main\" names it; index.js if left out)\n\n"
       "The script runs inside Steam's interface with these names:\n"
       "  plugin     plugin.id, plugin.name, plugin.log(...), plugin.storage.get(key) and\n"
       "             plugin.storage.set(key, value) (promises; values kept by the app), plugin.define(def)\n"
       "  React      Steam's own React\n"
       "  ui         Steam's components: PanelSection, PanelSectionRow, ButtonItem, ToggleField,\n"
       "             SliderField, DropdownItem, Field, Focusable, DialogButton (the same ones\n"
       "             Decky's @decky/ui gives plugins)\n"
       "  AKPlugins  webpack (findModule, findModuleExport, ...), patcher (afterPatch, beforePatch,\n"
       "             replacePatch), react (findInReactTree, getReactRoot, createReactTreePatcher)\n\n"
       "It returns (or passes to plugin.define) what the menu shows:\n"
       "  { name, icon (an element), content (an element) or Content (a component), onDismount() }\n\n"
       "Example (index.js):\n\n"
       "  const { PanelSection, PanelSectionRow, ToggleField } = ui;\n"
       "  function Panel() {\n"
       "    const [on, setOn] = React.useState(false);\n"
       "    React.useEffect(() => { plugin.storage.get('on').then((v) => setOn(!!v)); }, []);\n"
       "    return React.createElement(PanelSection, { title: 'Hello' },\n"
       "      React.createElement(PanelSectionRow, null,\n"
       "        React.createElement(ToggleField, { label: 'A switch', checked: on,\n"
       "          onChange: (v) => { setOn(v); plugin.storage.set('on', v); } })));\n"
       "  }\n"
       "  return { Content: Panel };\n\n"
       "Turn plugins on and off, or reload them after editing, under Plugins > Manage plugins.\n"
       "Errors go to web-helper.log (lines with \"plugin\").\n";
    [text writeToFile:readme atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  }
  return dir;
}

static NSSet<NSString *> *disabledPlugins(void) {
  return [NSSet setWithArray:[NSUserDefaults.standardUserDefaults stringArrayForKey:@"AKDisabledPlugins"] ?: @[]];
}

static NSDictionary *pluginList(void) {
  NSString *dir = pluginsFolder();
  NSFileManager *fm = NSFileManager.defaultManager;
  NSSet *disabled = disabledPlugins();
  NSMutableArray *out = [NSMutableArray array];
  NSArray *names = [[fm contentsOfDirectoryAtPath:dir error:NULL] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
  for (NSString *name in names) {
    NSString *folder = [dir stringByAppendingPathComponent:name];
    BOOL isDir = NO;
    if ([name hasPrefix:@"."] || ![fm fileExistsAtPath:folder isDirectory:&isDir] || !isDir) continue;
    NSMutableDictionary *p = [@{ @"id": name, @"name": name, @"enabled": @(![disabled containsObject:name]) } mutableCopy];
    NSData *json = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"plugin.json"]];
    NSDictionary *manifest = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL] : nil;
    if (json && ![manifest isKindOfClass:NSDictionary.class]) {
      p[@"error"] = @"plugin.json isn't valid JSON";
      [out addObject:p];
      continue;
    }
    for (NSString *key in @[ @"name", @"version", @"author", @"description" ])
      if ([manifest[key] isKindOfClass:NSString.class]) p[key] = manifest[key];
    NSString *main = [manifest[@"main"] isKindOfClass:NSString.class] ? manifest[@"main"] : @"index.js";
    NSString *script = [[folder stringByAppendingPathComponent:main] stringByStandardizingPath];
    p[@"main"] = main;
    unsigned long long size = [[fm attributesOfItemAtPath:script error:NULL] fileSize];
    if (![script hasPrefix:[folder.stringByStandardizingPath stringByAppendingString:@"/"]]) p[@"error"] = @"its main script is outside its folder";
    else if (![fm fileExistsAtPath:script]) p[@"error"] = [NSString stringWithFormat:@"%@ is missing", main];
    else if (size > 4 * 1024 * 1024) p[@"error"] = @"its script is over 4 MB";
    else if ([p[@"enabled"] boolValue]) {
      NSString *source = [NSString stringWithContentsOfFile:script encoding:NSUTF8StringEncoding error:NULL];
      if (source) p[@"source"] = source;
      else p[@"error"] = @"its script isn't UTF-8 text";
    }
    [out addObject:p];
  }
  return @{ @"folder": @"Documents/plugins", @"plugins": out };
}

static void setPluginEnabled(NSString *pluginID, BOOL enabled) {
  NSMutableSet *disabled = [disabledPlugins() mutableCopy];
  if (enabled) [disabled removeObject:pluginID];
  else [disabled addObject:pluginID];
  [NSUserDefaults.standardUserDefaults setObject:disabled.allObjects forKey:@"AKDisabledPlugins"];
  AKWHLog(YES, @"plugin %@ turned %@", pluginID, enabled ? @"on" : @"off");
}

// A plugin's own values (plugin.storage), kept as JSON-safe values per plugin.
static id pluginStorage(NSDictionary *args) {
  NSString *pluginID = [args[@"id"] isKindOfClass:NSString.class] ? args[@"id"] : nil;
  NSString *key = [args[@"key"] isKindOfClass:NSString.class] ? args[@"key"] : nil;
  if (!pluginID || !key) return NSNull.null;
  NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
  NSMutableDictionary *all = [[d dictionaryForKey:@"AKPluginStorage"] mutableCopy] ?: [NSMutableDictionary dictionary];
  NSMutableDictionary *mine = [all[pluginID] mutableCopy] ?: [NSMutableDictionary dictionary];
  if (![args[@"set"] boolValue]) return mine[key] ?: NSNull.null;
  id value = args[@"value"];
  if (!value || value == NSNull.null) [mine removeObjectForKey:key];
  else if ([NSJSONSerialization isValidJSONObject:@[ value ]]) mine[key] = value;
  else return @NO;
  all[pluginID] = mine;
  [d setObject:all forKey:@"AKPluginStorage"];
  return @YES;
}

#pragma mark Calls from the page

void AKWHDeckCall(NSString *name, id args, void (^reply)(id result)) {
  NSDictionary *a = [args isKindOfClass:NSDictionary.class] ? args : @{};
  if ([name isEqualToString:@"perf-state"]) {
    reply(AKPerfState());
  } else if ([name isEqualToString:@"perf-update"]) {
    reply(AKPerfUpdate(a));
  } else if ([name isEqualToString:@"perf-app-setting"]) {
    reply([a[@"key"] isKindOfClass:NSString.class] ? AKPerfSetAppSetting(a[@"key"], a[@"value"]) : AKPerfState());
  } else if ([name isEqualToString:@"display"]) {
    applyKeepAwake();
    reply(displayState());
  } else if ([name isEqualToString:@"display-set"]) {
    if ([a[@"brightness"] isKindOfClass:NSNumber.class]) UIScreen.mainScreen.brightness = MAX(0, MIN(1, [a[@"brightness"] doubleValue]));
    if ([a[@"keepAwake"] isKindOfClass:NSString.class]) {
      [NSUserDefaults.standardUserDefaults setObject:a[@"keepAwake"] forKey:@"AKKeepAwake"];
      applyKeepAwake();
    }
    reply(displayState());
  } else if ([name isEqualToString:@"share-logs"]) {
    shareLogs(reply);
  } else if ([name isEqualToString:@"plugins"]) {
    reply(pluginList());
  } else if ([name isEqualToString:@"plugin-enable"]) {
    if ([a[@"id"] isKindOfClass:NSString.class]) setPluginEnabled(a[@"id"], [a[@"enabled"] boolValue]);
    reply(@YES);
  } else if ([name isEqualToString:@"plugin-storage"]) {
    reply(pluginStorage(a));
  } else if ([name isEqualToString:@"log"]) {
    AKWHLog(NO, @"[quick access] %@", [args isKindOfClass:NSString.class] ? args : [args description]);
    reply(nil);
  } else {
    AKWHLog(NO, @"[quick access] unknown call %@", name);
    reply(nil);
  }
}
