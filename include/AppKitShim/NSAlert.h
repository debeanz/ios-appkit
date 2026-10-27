// NSAlert — shown as a UIAlertController. -runModal blocks the caller (by running the run
// loop, as AppKit does) and returns which button was chosen; the sheet variant calls back.
#import <Foundation/Foundation.h>
#import "NSControls.h"

@class NSWindow, NSImage;

typedef NS_ENUM(NSUInteger, NSAlertStyle) {
  NSAlertStyleWarning = 0, NSAlertStyleInformational = 1, NSAlertStyleCritical = 2,
};

static const NSModalResponse NSAlertFirstButtonReturn = 1000;
static const NSModalResponse NSAlertSecondButtonReturn = 1001;
static const NSModalResponse NSAlertThirdButtonReturn = 1002;

@interface NSAlert : NSObject
@property (nonatomic, copy) NSString *messageText;
@property (nonatomic, copy) NSString *informativeText;
@property (nonatomic, assign) NSAlertStyle alertStyle;
@property (nonatomic, strong) NSImage *icon;
@property (nonatomic, assign) BOOL showsSuppressionButton;
@property (nonatomic, readonly, copy) NSArray<NSButton *> *buttons;
@property (nonatomic, strong) NSView *accessoryView;

- (NSButton *)addButtonWithTitle:(NSString *)title;
- (NSModalResponse)runModal;
- (void)beginSheetModalForWindow:(NSWindow *)window completionHandler:(void (^)(NSModalResponse returnCode))handler;
@end
