// NSCell, NSControl, NSButton, NSTextField — AppKit's basic controls. The client creates a
// few (an alert's buttons, the odd text label) mostly as models: title, value, target and
// action. They are real NSViews; -performClick: sends the action through the responder
// chain like AppKit.
#import "NSView.h"

typedef NSInteger NSModalResponse;
static const NSModalResponse NSModalResponseOK = 1;
static const NSModalResponse NSModalResponseCancel = 0;
static const NSModalResponse NSModalResponseStop = -1000;
static const NSModalResponse NSModalResponseAbort = -1001;

typedef NS_ENUM(NSUInteger, NSButtonType) {
  NSButtonTypeMomentaryLight = 0, NSButtonTypePushOnPushOff = 1, NSButtonTypeToggle = 2,
  NSButtonTypeSwitch = 3, NSButtonTypeRadio = 4, NSButtonTypeMomentaryChange = 5,
};

@interface NSCell : NSObject <NSCopying>
- (instancetype)initTextCell:(NSString *)string;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *stringValue;
@property (nonatomic, assign) NSInteger integerValue;
@property (nonatomic, assign) NSInteger state;
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;
@property (nonatomic, assign) NSInteger tag;
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL action;
@property (nonatomic, strong) id representedObject;
@end

@interface NSControl : NSView
@property (nonatomic, strong) NSCell *cell;
@property (nonatomic, copy) NSString *stringValue;
@property (nonatomic, assign) NSInteger integerValue;
@property (nonatomic, assign) double doubleValue;
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;
@property (nonatomic, assign) NSInteger tag;
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL action;
- (BOOL)sendAction:(SEL)action to:(id)target;
- (void)sizeToFit;
@end

@interface NSButton : NSControl
+ (instancetype)buttonWithTitle:(NSString *)title target:(id)target action:(SEL)action;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *keyEquivalent;
@property (nonatomic, assign) NSInteger state;
- (void)setButtonType:(NSButtonType)type;
- (void)performClick:(id)sender;
@end

@interface NSTextField : NSControl
+ (instancetype)labelWithString:(NSString *)string;
+ (instancetype)textFieldWithString:(NSString *)string;
@property (nonatomic, copy) NSString *placeholderString;
@property (nonatomic, assign, getter=isEditable) BOOL editable;
@property (nonatomic, assign, getter=isSelectable) BOOL selectable;
@property (nonatomic, assign, getter=isBezeled) BOOL bezeled;
@property (nonatomic, assign) BOOL drawsBackground;
@end
