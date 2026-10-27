// Shim-specific input settings. Not AppKit API: these exist because an iPhone has an
// on-screen keyboard that a Mac doesn't, and the host app needs to decide when it shows.
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, AKShimSoftwareKeyboardPolicy) {
  // Show the iPhone keyboard while the focused view is editing text (its -inputContext is
  // non-nil, which is how Chromium signals a focused text field), hide it otherwise.
  AKShimSoftwareKeyboardAutomatic = 0,
  // Never show it: hardware keyboards still work. For UIs with their own on-screen keyboard.
  AKShimSoftwareKeyboardNever,
  // Always show it while a shim view is focused.
  AKShimSoftwareKeyboardAlways,
};

void AKShimSetSoftwareKeyboardPolicy(AKShimSoftwareKeyboardPolicy policy);
AKShimSoftwareKeyboardPolicy AKShimGetSoftwareKeyboardPolicy(void);

// Re-checks whether the keyboard should be showing. The shim calls this after every event
// and on a short timer (focus can change asynchronously after a click); hosts can call it too.
void AKShimUpdateSoftwareKeyboard(void);
