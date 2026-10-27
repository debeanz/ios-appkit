// System-service classes, each bridged to its iOS counterpart where one exists:
// NSSpellChecker -> UITextChecker, NSSpeechSynthesizer -> AVSpeechSynthesizer,
// NSPopover -> a UIKit popover, NSColorPanel -> UIColorPickerViewController,
// NSSharingService(Picker) -> the share sheet. NSStatusBar, NSToolbar and printing have no
// iPhone equivalent and keep their model without showing anything.
#import <Foundation/Foundation.h>
#import "NSGeometry.h"
#import "NSControls.h"

@class NSView, NSViewController, NSColor, NSWindow, NSImage;

#pragma mark Spelling

@interface NSSpellChecker : NSObject
@property (class, readonly, strong) NSSpellChecker *sharedSpellChecker;
@property (class, readonly) BOOL sharedSpellCheckerExists;
@property (class, readonly) BOOL isAutomaticTextReplacementEnabled;
@property (class, readonly) BOOL isAutomaticSpellingCorrectionEnabled;
@property (nonatomic, readonly, copy) NSArray<NSString *> *availableLanguages;
@property (nonatomic, readonly, copy) NSString *language; // set with -setLanguage:, which returns BOOL
@property (nonatomic) BOOL automaticallyIdentifiesLanguages;
+ (NSInteger)uniqueSpellDocumentTag;
- (void)closeSpellDocumentWithTag:(NSInteger)tag;
- (NSRange)checkSpellingOfString:(NSString *)string startingAt:(NSInteger)startingOffset;
- (NSRange)checkSpellingOfString:(NSString *)string startingAt:(NSInteger)startingOffset language:(NSString *)language
                            wrap:(BOOL)wrapFlag inSpellDocumentWithTag:(NSInteger)tag wordCount:(NSInteger *)wordCount;
- (NSArray<NSString *> *)guessesForWordRange:(NSRange)range inString:(NSString *)string language:(NSString *)language
                       inSpellDocumentWithTag:(NSInteger)tag;
- (void)learnWord:(NSString *)word;
- (void)unlearnWord:(NSString *)word;
- (BOOL)hasLearnedWord:(NSString *)word;
- (void)ignoreWord:(NSString *)word inSpellDocumentWithTag:(NSInteger)tag;
- (BOOL)setLanguage:(NSString *)language;
@end

#pragma mark Speech

@class NSSpeechSynthesizer;
@protocol NSSpeechSynthesizerDelegate <NSObject>
@optional
- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender didFinishSpeaking:(BOOL)finishedSpeaking;
@end

@interface NSSpeechSynthesizer : NSObject
@property (class, readonly, copy) NSArray<NSString *> *availableVoices;
@property (class, readonly, copy) NSString *defaultVoice;
@property (class, readonly, getter=isAnyApplicationSpeaking) BOOL anyApplicationSpeaking;
- (instancetype)initWithVoice:(NSString *)voice;
@property (nonatomic, weak) id<NSSpeechSynthesizerDelegate> delegate;
@property (nonatomic, readonly, getter=isSpeaking) BOOL speaking;
@property (nonatomic) float rate;   // words per minute, as on the Mac
@property (nonatomic) float volume; // 0..1
- (NSString *)voice;
- (BOOL)setVoice:(NSString *)voice;
- (BOOL)startSpeakingString:(NSString *)string;
- (void)stopSpeaking;
@end

#pragma mark Popover

typedef NS_ENUM(NSInteger, NSPopoverBehavior) {
  NSPopoverBehaviorApplicationDefined = 0, NSPopoverBehaviorTransient = 1, NSPopoverBehaviorSemitransient = 2,
};

@interface NSPopover : NSResponder
@property (nonatomic, strong) NSViewController *contentViewController;
@property (nonatomic) NSPopoverBehavior behavior;
@property (nonatomic) NSSize contentSize;
@property (nonatomic) BOOL animates;
@property (nonatomic, readonly, getter=isShown) BOOL shown;
@property (nonatomic, weak) id delegate;
- (void)showRelativeToRect:(NSRect)positioningRect ofView:(NSView *)positioningView preferredEdge:(NSRectEdge)preferredEdge;
- (void)performClose:(id)sender;
- (void)close;
@end

#pragma mark Colour

@interface NSColorPanel : NSObject
@property (class, readonly, strong) NSColorPanel *sharedColorPanel;
@property (class, readonly) BOOL sharedColorPanelExists;
@property (nonatomic, strong) NSColor *color;
@property (nonatomic) BOOL showsAlpha;
@property (nonatomic, getter=isContinuous) BOOL continuous;
@property (nonatomic, readonly, getter=isVisible) BOOL visible;
- (void)setTarget:(id)target;
- (void)setAction:(SEL)action;
- (void)orderFront:(id)sender;
- (void)close;
@end

@interface NSColorSampler : NSObject
// Sampling screen pixels from other apps isn't possible on iOS: the handler gets nil.
- (void)showSamplerWithSelectionHandler:(void (^)(NSColor *selectedColor))selectionHandler;
@end

#pragma mark Sharing

typedef NSString *NSSharingServiceName;

@interface NSSharingService : NSObject
+ (NSSharingService *)sharingServiceNamed:(NSSharingServiceName)serviceName;
@property (nonatomic, weak) id delegate;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, copy) NSString *subject;
@property (nonatomic, copy) NSArray<NSString *> *recipients;
- (BOOL)canPerformWithItems:(NSArray *)items;
- (void)performWithItems:(NSArray *)items;
@end

@interface NSSharingServicePicker : NSObject
- (instancetype)initWithItems:(NSArray *)items;
@property (nonatomic, weak) id delegate;
- (void)showRelativeToRect:(NSRect)rect ofView:(NSView *)view preferredEdge:(NSRectEdge)preferredEdge;
- (void)close;
@end

#pragma mark Menu bar, toolbar, printing

@interface NSStatusItem : NSObject
@property (nonatomic) CGFloat length;
@property (nonatomic, strong) id menu;
@property (nonatomic, getter=isVisible) BOOL visible;
@end

@interface NSStatusBar : NSObject
@property (class, readonly, strong) NSStatusBar *systemStatusBar;
@property (nonatomic, readonly) CGFloat thickness;
@property (nonatomic, readonly, getter=isVertical) BOOL vertical;
- (NSStatusItem *)statusItemWithLength:(CGFloat)length;
- (void)removeStatusItem:(NSStatusItem *)item;
@end

@interface NSToolbar : NSObject
- (instancetype)initWithIdentifier:(NSString *)identifier;
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, weak) id delegate;
@property (nonatomic, getter=isVisible) BOOL visible;
@property (nonatomic) BOOL allowsUserCustomization;
@property (nonatomic) BOOL autosavesConfiguration;
@property (nonatomic, readonly, copy) NSArray *items;
- (void)insertItemWithItemIdentifier:(NSString *)itemIdentifier atIndex:(NSInteger)index;
- (void)removeItemAtIndex:(NSInteger)index;
@end

typedef NS_ENUM(NSInteger, NSPaperOrientation) { NSPaperOrientationPortrait = 0, NSPaperOrientationLandscape = 1 };

@interface NSPrintInfo : NSObject <NSCopying>
@property (class, strong) NSPrintInfo *sharedPrintInfo;
- (instancetype)initWithDictionary:(NSDictionary *)attributes;
@property (nonatomic, readonly) NSMutableDictionary *dictionary;
@property (nonatomic) NSSize paperSize;
@property (nonatomic) NSPaperOrientation orientation;
@property (nonatomic) CGFloat topMargin, bottomMargin, leftMargin, rightMargin;
@property (nonatomic, readonly) NSRect imageablePageBounds;
@property (nonatomic, copy) NSString *jobDisposition;
@end

@interface NSPrintPanel : NSObject
+ (NSPrintPanel *)printPanel;
- (NSInteger)runModal;
- (NSInteger)runModalWithPrintInfo:(NSPrintInfo *)printInfo;
@end
