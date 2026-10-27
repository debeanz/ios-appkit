// NSTextInputContext / NSTextInputClient — how AppKit delivers typed text and editing
// commands to a text-editing view. Chromium's view adopts NSTextInputClient; when a key
// arrives, its -keyDown: hands the event to its input context, which calls back with
// -insertText:replacementRange: for text or -doCommandBySelector: for keys like Delete.
//
// Composition (marked text, used by CJK input methods) is part of the protocol and is
// passed through, but the shim does not drive it yet: the iPhone keyboard delivers
// committed text only.
#import <Foundation/Foundation.h>
#import "NSGeometry.h"

@class NSEvent;

@protocol NSTextInputClient
@required
- (void)insertText:(id)string replacementRange:(NSRange)replacementRange;
- (void)doCommandBySelector:(SEL)selector;
- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange;
- (void)unmarkText;
- (NSRange)selectedRange;
- (NSRange)markedRange;
- (BOOL)hasMarkedText;
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange;
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText;
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange;
- (NSUInteger)characterIndexForPoint:(NSPoint)point;
@end

extern NSNotificationName const NSTextInputContextKeyboardSelectionDidChangeNotification;
extern NSAttributedStringKey const NSTextInputReplacementRangeAttributeName;

@interface NSTextInputContext : NSObject
// The input context of the key window's first responder, if it has one.
@property (class, readonly) NSTextInputContext *currentInputContext;

- (instancetype)initWithClient:(id<NSTextInputClient>)client;
@property (nonatomic, readonly, unsafe_unretained) id<NSTextInputClient> client;
@property (nonatomic, assign) BOOL acceptsGlyphInfo;
@property (nonatomic, copy) NSArray<NSString *> *allowedInputSourceLocales;

- (void)activate;
- (void)deactivate;
- (BOOL)handleEvent:(NSEvent *)event;
- (void)discardMarkedText;
- (void)invalidateCharacterCoordinates;

@property (nonatomic, readonly, copy) NSArray<NSString *> *keyboardInputSources;
@property (nonatomic, copy) NSString *selectedKeyboardInputSource;
+ (NSString *)localizedNameForInputSource:(NSString *)inputSourceIdentifier;
@end

// NSInputManager is the pre-10.6 predecessor of NSTextInputContext. The client still
// references the class, so it exists, but nothing uses it.
@interface NSInputManager : NSObject
+ (NSInputManager *)currentInputManager;
@end
