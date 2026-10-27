// Loose AppKit functions (see src/AppKitFunctions.m).
#import <Foundation/Foundation.h>
#import "NSGeometry.h"

void NSAccessibilityPostNotification(id element, NSString *notification);
void NSAccessibilityPostNotificationWithUserInfo(id element, NSString *notification, NSDictionary *userInfo);
NSString *NSAccessibilityRoleDescription(NSString *role, NSString *subrole);
NSString *NSAccessibilityActionDescription(NSString *action);
id NSAccessibilityUnignoredAncestor(id element);
NSArray *NSAccessibilityUnignoredChildren(NSArray *children);

// The Emacs-style kill ring behind Ctrl+K / Ctrl+Y in text fields.
void _NSInitializeKillRing(void);
void _NSAppendToKillRing(NSString *text);
void _NSNewKillRingSequence(void);
void _NSSetKillRingToYankedState(void);
NSString *_NSYankFromKillRing(void);

void NSRectFill(NSRect rect);
BOOL NSPerformService(NSString *itemName, id pboard);
NSInteger NSRunAlertPanel(NSString *title, NSString *format, NSString *defaultButton,
                          NSString *alternateButton, NSString *otherButton, ...) NS_FORMAT_FUNCTION(2, 6);
