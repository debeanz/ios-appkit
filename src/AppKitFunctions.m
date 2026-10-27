// Loose AppKit functions the client imports: accessibility helpers, the text-editing kill
// ring, simple drawing, and two legacy calls.
#import "AKShimPrivate.h"
#import "AppKitShim/AppKitFunctions.h"

#pragma mark Accessibility

// Element notifications have no direct UIKit equivalent here (Chromium's accessibility tree
// is not bridged to VoiceOver yet), so they are accepted and dropped. Announcements are the
// exception: those map one-to-one onto VoiceOver announcements.
void NSAccessibilityPostNotification(id element, NSString *notification) {}

void NSAccessibilityPostNotificationWithUserInfo(id element, NSString *notification, NSDictionary *userInfo) {
  if (![notification isEqualToString:NSAccessibilityAnnouncementRequestedNotification]) return;
  id text = userInfo[NSAccessibilityAnnouncementKey];
  if (![text isKindOfClass:NSString.class] && ![text isKindOfClass:NSAttributedString.class]) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, text);
  });
}

// "AXPopUpButton" -> "pop up button": AppKit's role descriptions are the role name in words.
static NSString *AKWordsFromAXName(NSString *name) {
  if ([name hasPrefix:@"AX"]) name = [name substringFromIndex:2];
  NSMutableString *out = [NSMutableString string];
  for (NSUInteger i = 0; i < name.length; i++) {
    unichar c = [name characterAtIndex:i];
    BOOL upper = c >= 'A' && c <= 'Z';
    if (upper && i > 0) [out appendString:@" "];
    unichar lower = upper ? (unichar)(c - 'A' + 'a') : c;
    [out appendFormat:@"%C", lower];
  }
  return out;
}

NSString *NSAccessibilityRoleDescription(NSString *role, NSString *subrole) {
  return role ? AKWordsFromAXName(subrole.length ? subrole : role) : nil;
}

NSString *NSAccessibilityActionDescription(NSString *action) {
  return action ? AKWordsFromAXName(action) : nil;
}

// Without an ignored-element model every element is its own unignored ancestor.
id NSAccessibilityUnignoredAncestor(id element) { return element; }
NSArray *NSAccessibilityUnignoredChildren(NSArray *children) { return children; }

#pragma mark Kill ring

// AppKit's Emacs-style kill ring: Ctrl+K kills to the end of the line, consecutive kills
// join into one entry, Ctrl+Y yanks the latest. Chromium's text fields call these directly.
static NSMutableArray<NSMutableString *> *gKillRing;
static BOOL gKillSequenceOpen;
static const NSUInteger AKKillRingSize = 10;

void _NSInitializeKillRing(void) {
  if (!gKillRing) gKillRing = [NSMutableArray array];
}

void _NSAppendToKillRing(NSString *text) {
  _NSInitializeKillRing();
  if (!gKillSequenceOpen || gKillRing.count == 0) {
    [gKillRing addObject:[NSMutableString string]];
    if (gKillRing.count > AKKillRingSize) [gKillRing removeObjectAtIndex:0];
    gKillSequenceOpen = YES;
  }
  if (text) [gKillRing.lastObject appendString:text];
}

void _NSNewKillRingSequence(void) { gKillSequenceOpen = NO; }
void _NSSetKillRingToYankedState(void) { gKillSequenceOpen = NO; }

NSString *_NSYankFromKillRing(void) {
  _NSInitializeKillRing();
  return [gKillRing.lastObject copy] ?: @"";
}

#pragma mark Drawing

// Fills with the current context's fill colour, like AppKit's NSRectFill.
void NSRectFill(NSRect rect) {
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  if (ctx) CGContextFillRect(ctx, rect);
}

#pragma mark Legacy

// Services menu: iOS has no Services, so nothing can be performed.
BOOL NSPerformService(NSString *itemName, id pboard) { return NO; }

// A modal alert on the Mac. iOS alerts can't block the caller, so this shows the alert and
// returns NSAlertDefaultReturn (1) immediately, as if the default button were chosen.
NSInteger NSRunAlertPanel(NSString *title, NSString *format, NSString *defaultButton,
                          NSString *alternateButton, NSString *otherButton, ...) {
  NSString *message = @"";
  if (format) {
    va_list ap;
    va_start(ap, otherButton);
    message = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    UIViewController *root = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
      if ([scene isKindOfClass:UIWindowScene.class]) { root = ((UIWindowScene *)scene).windows.firstObject.rootViewController; break; }
    }
    while (root.presentedViewController) root = root.presentedViewController;
    if (!root) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:defaultButton ?: @"OK" style:UIAlertActionStyleDefault handler:nil]];
    [root presentViewController:alert animated:YES completion:nil];
  });
  return 1; // NSAlertDefaultReturn
}
