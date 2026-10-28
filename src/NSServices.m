#import "AKShimPrivate.h"
#import "AppKitShim/NSServices.h"
#import "AppKitShim/NSViewController.h"
#import <AVFoundation/AVFoundation.h>

#pragma mark Spelling (UITextChecker)

@implementation NSSpellChecker {
  UITextChecker *_checker;
  NSMutableDictionary<NSNumber *, NSMutableSet<NSString *> *> *_ignored; // per spell document
}

+ (NSSpellChecker *)sharedSpellChecker {
  static NSSpellChecker *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [NSSpellChecker new]; });
  return shared;
}

+ (BOOL)sharedSpellCheckerExists { return YES; }
+ (BOOL)isAutomaticTextReplacementEnabled { return NO; }
+ (BOOL)isAutomaticSpellingCorrectionEnabled { return NO; }

- (instancetype)init {
  if ((self = [super init])) {
    _checker = [UITextChecker new];
    _ignored = [NSMutableDictionary dictionary];
    _language = NSLocale.preferredLanguages.firstObject ?: @"en_US";
  }
  return self;
}

- (NSArray<NSString *> *)availableLanguages { return UITextChecker.availableLanguages; }
- (BOOL)setLanguage:(NSString *)language { _language = [language copy]; return YES; }

// UITextChecker wants a language it knows ("en_US"); map "en-US" / "en" onto one.
- (NSString *)_checkerLanguage:(NSString *)requested {
  NSArray<NSString *> *known = UITextChecker.availableLanguages;
  NSString *lang = [requested ?: _language stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
  if ([known containsObject:lang]) return lang;
  for (NSString *k in known) if ([k hasPrefix:[lang componentsSeparatedByString:@"_"].firstObject]) return k;
  return known.firstObject;
}

+ (NSInteger)uniqueSpellDocumentTag {
  static NSInteger next = 1;
  @synchronized (self) { return next++; }
}

- (void)closeSpellDocumentWithTag:(NSInteger)tag { [_ignored removeObjectForKey:@(tag)]; }

- (void)ignoreWord:(NSString *)word inSpellDocumentWithTag:(NSInteger)tag {
  if (!word) return;
  NSMutableSet *set = _ignored[@(tag)] ?: (_ignored[@(tag)] = [NSMutableSet set]);
  [set addObject:word];
}

- (NSRange)checkSpellingOfString:(NSString *)string startingAt:(NSInteger)start {
  return [self checkSpellingOfString:string startingAt:start language:nil wrap:NO inSpellDocumentWithTag:0 wordCount:NULL];
}

- (NSRange)checkSpellingOfString:(NSString *)string startingAt:(NSInteger)start language:(NSString *)language
                            wrap:(BOOL)wrap inSpellDocumentWithTag:(NSInteger)tag wordCount:(NSInteger *)wordCount {
  if (wordCount) *wordCount = -1; // not counted
  if (string.length == 0 || start < 0 || (NSUInteger)start > string.length) return NSMakeRange(NSNotFound, 0);
  NSString *lang = [self _checkerLanguage:language];
  if (!lang) return NSMakeRange(NSNotFound, 0); // no dictionaries installed
  NSSet *ignored = _ignored[@(tag)];
  NSInteger from = start;
  // Skip words ignored for this document; UITextChecker doesn't know about them.
  for (;;) {
    NSRange r = [_checker rangeOfMisspelledWordInString:string range:NSMakeRange(0, string.length)
                                             startingAt:from wrap:wrap language:lang];
    if (r.location == NSNotFound) return r;
    if (![ignored containsObject:[string substringWithRange:r]]) return r;
    from = (NSInteger)NSMaxRange(r);
    if ((NSUInteger)from >= string.length) return NSMakeRange(NSNotFound, 0);
  }
}

- (NSArray<NSString *> *)guessesForWordRange:(NSRange)range inString:(NSString *)string language:(NSString *)language
                       inSpellDocumentWithTag:(NSInteger)tag {
  NSString *lang = [self _checkerLanguage:language];
  if (!lang || NSMaxRange(range) > string.length) return @[];
  return [_checker guessesForWordRange:range inString:string language:lang] ?: @[];
}

- (void)learnWord:(NSString *)word { if (word) [UITextChecker learnWord:word]; }
- (void)unlearnWord:(NSString *)word { if (word) [UITextChecker unlearnWord:word]; }
- (BOOL)hasLearnedWord:(NSString *)word { return word && [UITextChecker hasLearnedWord:word]; }


AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

#pragma mark Speech (AVSpeechSynthesizer)

@interface NSSpeechSynthesizer () <AVSpeechSynthesizerDelegate>
@end

@implementation NSSpeechSynthesizer {
  AVSpeechSynthesizer *_synth;
  NSString *_voice;
}

+ (NSArray<NSString *> *)availableVoices {
  NSMutableArray *ids = [NSMutableArray array];
  for (AVSpeechSynthesisVoice *v in AVSpeechSynthesisVoice.speechVoices) [ids addObject:v.identifier];
  return ids;
}

+ (NSString *)defaultVoice {
  return [AVSpeechSynthesisVoice voiceWithLanguage:AVSpeechSynthesisVoice.currentLanguageCode].identifier;
}

+ (BOOL)isAnyApplicationSpeaking { return NO; }

- (instancetype)init { return [self initWithVoice:nil]; }

- (instancetype)initWithVoice:(NSString *)voice {
  if ((self = [super init])) {
    _synth = [AVSpeechSynthesizer new];
    _synth.delegate = self;
    _voice = [voice copy] ?: NSSpeechSynthesizer.defaultVoice;
    _rate = 180;   // macOS's default speaking rate, in words per minute
    _volume = 1;
  }
  return self;
}

- (NSString *)voice { return _voice; }
- (BOOL)setVoice:(NSString *)voice {
  if (voice && ![AVSpeechSynthesisVoice voiceWithIdentifier:voice]) return NO;
  _voice = [voice copy] ?: NSSpeechSynthesizer.defaultVoice;
  return YES;
}

- (BOOL)isSpeaking { return _synth.isSpeaking; }

- (BOOL)startSpeakingString:(NSString *)string {
  if (string.length == 0) return NO;
  AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:string];
  u.voice = [AVSpeechSynthesisVoice voiceWithIdentifier:_voice];
  // Map words per minute onto AVSpeech's 0..1 scale, where the default (0.5) is ~180 wpm.
  float r = AVSpeechUtteranceDefaultSpeechRate * (_rate / 180.0f);
  u.rate = MAX(AVSpeechUtteranceMinimumSpeechRate, MIN(AVSpeechUtteranceMaximumSpeechRate, r));
  u.volume = MAX(0, MIN(1, _volume));
  [_synth speakUtterance:u];
  return YES;
}

- (void)stopSpeaking { [_synth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate]; }

- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didFinishSpeechUtterance:(AVSpeechUtterance *)u {
  if ([_delegate respondsToSelector:@selector(speechSynthesizer:didFinishSpeaking:)]) [_delegate speechSynthesizer:self didFinishSpeaking:YES];
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didCancelSpeechUtterance:(AVSpeechUtterance *)u {
  if ([_delegate respondsToSelector:@selector(speechSynthesizer:didFinishSpeaking:)]) [_delegate speechSynthesizer:self didFinishSpeaking:NO];
}


AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

#pragma mark Popover

@interface NSPopover () <UIPopoverPresentationControllerDelegate>
@property (nonatomic, readwrite, getter=isShown) BOOL shown;
@end

@implementation NSPopover {
  UIViewController *_host;
}

- (instancetype)init {
  if ((self = [super init])) { _animates = YES; _behavior = NSPopoverBehaviorApplicationDefined; }
  return self;
}

// The content view controller's NSView is hosted in a UIViewController shown as an iOS
// popover anchored to the positioning view (a sheet on compact-width iPhones).
- (void)showRelativeToRect:(NSRect)rect ofView:(NSView *)view preferredEdge:(NSRectEdge)edge {
  UIViewController *top = AKTopViewController();
  NSView *content = _contentViewController.view;
  if (!top || !content || _shown) return;
  UIViewController *host = [UIViewController new];
  host.view = content.backingView;
  NSSize size = NSEqualSizes(_contentSize, NSZeroSize) ? content.frame.size : _contentSize;
  host.preferredContentSize = size;
  host.modalPresentationStyle = UIModalPresentationPopover;
  UIPopoverPresentationController *pop = host.popoverPresentationController;
  pop.sourceView = view.backingView ?: top.view;
  pop.sourceRect = view ? rect : CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
  pop.delegate = self;
  _host = host;
  self.shown = YES;
  [top presentViewController:host animated:_animates completion:nil];
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)controller {
  _host = nil;
  self.shown = NO;
}

- (void)close {
  if (!_host) return;
  [_host dismissViewControllerAnimated:_animates completion:nil];
  _host = nil;
  self.shown = NO;
}

- (void)performClose:(id)sender { [self close]; }

@end

#pragma mark Colour (UIColorPickerViewController)

@interface NSColorPanel () <UIColorPickerViewControllerDelegate>
@property (nonatomic, readwrite, getter=isVisible) BOOL visible;
@end

@implementation NSColorPanel {
  __weak id _target;
  SEL _action;
  UIColorPickerViewController *_picker;
}

+ (NSColorPanel *)sharedColorPanel {
  static NSColorPanel *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [NSColorPanel new]; shared.color = NSColor.whiteColor; shared.showsAlpha = YES; });
  return shared;
}

+ (BOOL)sharedColorPanelExists { return YES; }

- (void)setTarget:(id)target { _target = target; }
- (void)setAction:(SEL)action { _action = action; }

- (void)orderFront:(id)sender {
  UIViewController *top = AKTopViewController();
  if (!top || _picker) return;
  _picker = [UIColorPickerViewController new];
  _picker.supportsAlpha = _showsAlpha;
  _picker.selectedColor = [UIColor colorWithCGColor:_color.CGColor];
  _picker.delegate = self;
  self.visible = YES;
  [top presentViewController:_picker animated:YES completion:nil];
}

// Each colour change sends the panel's action to its target, as AppKit's panel does.
- (void)colorPickerViewController:(UIColorPickerViewController *)vc didSelectColor:(UIColor *)color continuously:(BOOL)continuously {
  self.color = [[NSColor alloc] initWithUIColor:color];
  id target = _target;
  if (target && _action && [target respondsToSelector:_action]) {
    ((void (*)(id, SEL, id))[target methodForSelector:_action])(target, _action, self);
  }
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)vc {
  _picker = nil;
  self.visible = NO;
}

- (void)close {
  [_picker dismissViewControllerAnimated:YES completion:nil];
  _picker = nil;
  self.visible = NO;
}


AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

@implementation NSColorSampler
- (void)showSamplerWithSelectionHandler:(void (^)(NSColor *))handler {
  if (handler) dispatch_async(dispatch_get_main_queue(), ^{ handler(nil); });
}

AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

#pragma mark Sharing (share sheet)

static void AKPresentShareSheet(NSArray *items, NSView *anchor, NSRect rect) {
  UIViewController *top = AKTopViewController();
  if (!top || items.count == 0) return;
  UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
  UIPopoverPresentationController *pop = sheet.popoverPresentationController; // iPad
  pop.sourceView = anchor.backingView ?: top.view;
  pop.sourceRect = anchor ? rect : CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
  [top presentViewController:sheet animated:YES completion:nil];
}

@implementation NSSharingService {
  NSString *_name;
}

+ (NSSharingService *)sharingServiceNamed:(NSSharingServiceName)serviceName {
  NSSharingService *s = [NSSharingService new];
  s->_name = [serviceName copy];
  return s;
}

- (NSString *)title { return _name ?: @"Share"; }
- (BOOL)canPerformWithItems:(NSArray *)items { return items.count > 0; }
// Every named service goes through the share sheet, which lists Mail, Reading List and the rest.
- (void)performWithItems:(NSArray *)items { AKPresentShareSheet(items, nil, NSZeroRect); }


AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

@implementation NSSharingServicePicker {
  NSArray *_items;
}

- (instancetype)initWithItems:(NSArray *)items {
  if ((self = [super init])) _items = [items copy];
  return self;
}

- (void)showRelativeToRect:(NSRect)rect ofView:(NSView *)view preferredEdge:(NSRectEdge)edge {
  AKPresentShareSheet(_items, view, rect);
}

- (void)close {}


AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

#pragma mark Menu bar, toolbar, printing

@implementation NSStatusItem

AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

@implementation NSStatusBar

+ (NSStatusBar *)systemStatusBar {
  static NSStatusBar *bar;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ bar = [NSStatusBar new]; });
  return bar;
}

- (CGFloat)thickness { return 0; } // no menu bar on iOS
- (BOOL)isVertical { return NO; }

- (NSStatusItem *)statusItemWithLength:(CGFloat)length {
  NSStatusItem *item = [NSStatusItem new];
  item.length = length;
  item.visible = NO; // nowhere to show it
  return item;
}

- (void)removeStatusItem:(NSStatusItem *)item {}


AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

@implementation NSToolbar {
  NSMutableArray<NSString *> *_itemIdentifiers;
}

- (instancetype)initWithIdentifier:(NSString *)identifier {
  if ((self = [super init])) { _identifier = [identifier copy]; _itemIdentifiers = [NSMutableArray array]; _visible = YES; }
  return self;
}

- (NSArray *)items { return [_itemIdentifiers copy]; }

- (void)insertItemWithItemIdentifier:(NSString *)itemIdentifier atIndex:(NSInteger)index {
  if (!itemIdentifier) return;
  [_itemIdentifiers insertObject:itemIdentifier atIndex:(NSUInteger)MAX(0, MIN(index, (NSInteger)_itemIdentifiers.count))];
}

- (void)removeItemAtIndex:(NSInteger)index {
  if (index >= 0 && index < (NSInteger)_itemIdentifiers.count) [_itemIdentifiers removeObjectAtIndex:(NSUInteger)index];
}


AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

@implementation NSPrintInfo

static NSPrintInfo *gSharedPrintInfo;

+ (NSPrintInfo *)sharedPrintInfo {
  static dispatch_once_t once;
  dispatch_once(&once, ^{ if (!gSharedPrintInfo) gSharedPrintInfo = [NSPrintInfo new]; });
  return gSharedPrintInfo;
}

+ (void)setSharedPrintInfo:(NSPrintInfo *)info { gSharedPrintInfo = info; }

- (instancetype)init { return [self initWithDictionary:nil]; }

// US Letter with AppKit's default margins (72pt left/right, 90pt top/bottom).
- (instancetype)initWithDictionary:(NSDictionary *)attributes {
  if ((self = [super init])) {
    _dictionary = [attributes mutableCopy] ?: [NSMutableDictionary dictionary];
    _paperSize = NSMakeSize(612, 792);
    _leftMargin = _rightMargin = 72;
    _topMargin = _bottomMargin = 90;
    _jobDisposition = @"NSPrintSpoolJob";
  }
  return self;
}

- (NSRect)imageablePageBounds { return NSMakeRect(0, 0, _paperSize.width, _paperSize.height); }

- (id)copyWithZone:(NSZone *)zone {
  NSPrintInfo *c = [[NSPrintInfo alloc] initWithDictionary:_dictionary];
  c.paperSize = _paperSize;
  c.orientation = _orientation;
  c.topMargin = _topMargin; c.bottomMargin = _bottomMargin;
  c.leftMargin = _leftMargin; c.rightMargin = _rightMargin;
  c.jobDisposition = _jobDisposition;
  return c;
}


AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

// The Mac print dialog prints a view; without a document to hand UIPrintInteractionController,
// there is nothing to print here, so the dialog reports Cancel.
@implementation NSPrintPanel
+ (NSPrintPanel *)printPanel { return [NSPrintPanel new]; }
- (NSInteger)runModal { return NSModalResponseCancel; }
- (NSInteger)runModalWithPrintInfo:(NSPrintInfo *)printInfo { return NSModalResponseCancel; }

AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end
