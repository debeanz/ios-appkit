// AVFoundation names macOS has and iOS lacks. A game's AVFoundation goes through the shim when
// it uses one (MacPrograms.m), and the umbrella forwards the rest to iOS's AVFoundation.
// iOS's headers declare these unavailable, so each takes its exported name from an asm label.
#import <Foundation/Foundation.h>

// Capture session presets (Unity's player lists them for webcams); a preset's value is its name.
extern NSString *const AKCaptureSessionPreset320x240 __asm__("_AVCaptureSessionPreset320x240");
extern NSString *const AKCaptureSessionPreset960x540 __asm__("_AVCaptureSessionPreset960x540");
NSString *const AKCaptureSessionPreset320x240 = @"AVCaptureSessionPreset320x240";
NSString *const AKCaptureSessionPreset960x540 = @"AVCaptureSessionPreset960x540";
