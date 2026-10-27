// AppKit globals and loose functions that aren't tied to one class.
#import "AppKitShim/AppKit.h"
#import <AudioToolbox/AudioToolbox.h>

// AppKit version on macOS 14; CEF reads it for feature gates. Reporting a recent
// version keeps it on modern code paths.
double NSAppKitVersionNumber = 2487.0;

void NSBeep(void) {
  AudioServicesPlaySystemSound(1057); // the iOS "Tink" alert
}
