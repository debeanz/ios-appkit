#import "AKShimPrivate.h"
#import "AppKitShim/NSTextInputContext.h"
#import "AppKitShim/AKShimInput.h"

NSNotificationName const NSTextInputContextKeyboardSelectionDidChangeNotification =
    @"NSTextInputContextKeyboardSelectionDidChangeNotification";
NSAttributedStringKey const NSTextInputReplacementRangeAttributeName = @"NSTextInputReplacementRangeAttributeName";

static NSString *const AKUSInputSource = @"com.apple.keylayout.US";

@implementation NSTextInputContext

+ (NSTextInputContext *)currentInputContext {
  NSResponder *r = NSApp.keyWindow.firstResponder;
  return [r isKindOfClass:NSView.class] ? ((NSView *)r).inputContext : nil;
}

- (instancetype)initWithClient:(id<NSTextInputClient>)client {
  if ((self = [super init])) {
    _client = client;
    _selectedKeyboardInputSource = AKUSInputSource;
  }
  return self;
}

// Activation follows focus; the software keyboard follows activation.
- (void)activate   { AKShimUpdateSoftwareKeyboard(); }
- (void)deactivate { AKShimUpdateSoftwareKeyboard(); }

- (BOOL)handleEvent:(NSEvent *)event {
  if (event.type != NSEventTypeKeyDown) return NO;

  SEL command = AKCommandSelectorForKeyEvent(event);
  if (command) {
    [_client doCommandBySelector:command];
    return YES;
  }
  // Command/Control chords are shortcuts (key equivalents), not text.
  if (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) return NO;

  NSString *text = event.characters;
  if (text.length == 0) return NO;
  unichar first = [text characterAtIndex:0];
  if (first >= 0xF700 && first <= 0xF8FF) return NO; // function keys with no binding
  if (first < 0x20 || first == 0x7F) return NO;      // other control characters

  [_client insertText:text replacementRange:NSMakeRange(NSNotFound, 0)];
  return YES;
}

- (void)discardMarkedText {
  if ([_client hasMarkedText]) [_client unmarkText];
}

- (void)invalidateCharacterCoordinates {
  // Would reposition an IME candidate window; the iPhone keyboard has none to move.
}

- (NSArray<NSString *> *)keyboardInputSources { return @[ AKUSInputSource ]; }

+ (NSString *)localizedNameForInputSource:(NSString *)inputSourceIdentifier {
  return [inputSourceIdentifier isEqualToString:AKUSInputSource] ? @"U.S." : inputSourceIdentifier;
}

@end

@implementation NSInputManager
+ (NSInputManager *)currentInputManager { return nil; }
@end
