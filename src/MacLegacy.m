// Older Mac APIs games still link, which iOS lacks entirely: Gestalt, garbage collection,
// panels, NSSound and the screen device-description keys.
#import "AKShimPrivate.h"
#import <AVFoundation/AVFoundation.h>

#pragma mark Device description keys

NSString *const NSDeviceResolution = @"NSDeviceResolution";
NSString *const NSDeviceColorSpaceName = @"NSDeviceColorSpaceName";
NSString *const NSDeviceBitsPerSample = @"NSDeviceBitsPerSample";
NSString *const NSDeviceIsScreen = @"NSDeviceIsScreen";
NSString *const NSDeviceIsPrinter = @"NSDeviceIsPrinter";
NSString *const NSDeviceSize = @"NSDeviceSize";

#pragma mark Gestalt

// The macOS version a Mac program asks for: the shim stands in for macOS 14 (Sonoma).
enum { AKGestaltUndefSelectorErr = -5551 };
static uint32_t fourCC(const char *s) { return (uint32_t)s[0] << 24 | (uint32_t)s[1] << 16 | (uint32_t)s[2] << 8 | (uint32_t)s[3]; }

int16_t Gestalt(uint32_t selector, int32_t *response) {
  if (!response) return -50;   // paramErr
  if (selector == fourCC("sys1")) { *response = 14; return 0; }        // major
  if (selector == fourCC("sys2")) { *response = 0; return 0; }         // minor
  if (selector == fourCC("sys3")) { *response = 0; return 0; }         // bug fix
  if (selector == fourCC("sysv")) { *response = 0x1099; return 0; }    // BCD, capped at 10.9.9 as on modern macOS
  return AKGestaltUndefSelectorErr;
}

#pragma mark Garbage collection

// Retired in macOS 10.8: no collector, as on every Mac since.
@interface NSGarbageCollector : NSObject
@end
@implementation NSGarbageCollector
+ (id)defaultCollector { return nil; }
- (BOOL)isEnabled { return NO; }
- (BOOL)isCollecting { return NO; }
- (void)collectIfNeeded {}
- (void)collectExhaustively {}
- (void)disable {}
- (void)enable {}
- (void)disableCollectorForPointer:(const void *)ptr {}
- (void)enableCollectorForPointer:(const void *)ptr {}
AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

#pragma mark Panels

// A window like any other here (full screen, one at a time); a panel's options are recorded.
@interface NSPanel : NSWindow
@property (nonatomic, assign, getter=isFloatingPanel) BOOL floatingPanel;
@property (nonatomic, assign) BOOL becomesKeyOnlyIfNeeded;
@property (nonatomic, assign) BOOL worksWhenModal;
@end
@implementation NSPanel
@end

#pragma mark NSSound

// A short sound, played with AVAudioPlayer.
@interface NSSound : NSObject <AVAudioPlayerDelegate>
@property (nonatomic, weak) id delegate;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) BOOL loops;
@property (nonatomic, assign) float volume;
@end

@implementation NSSound {
  AVAudioPlayer *_player;
}

+ (instancetype)soundNamed:(NSString *)name {
  static NSMutableDictionary<NSString *, NSSound *> *named;
  @synchronized (self) {
    if (!named) named = [NSMutableDictionary dictionary];
    if (named[name]) return named[name];
    NSBundle *bundle = NSBundle.mainBundle;
    NSURL *url = nil;
    for (NSString *ext in @[ @"aiff", @"aif", @"wav", @"caf", @"mp3", @"m4a" ])
      if ((url = [bundle URLForResource:name withExtension:ext])) break;
    NSSound *sound = url ? [[self alloc] initWithContentsOfURL:url byReference:YES] : nil;
    sound.name = name;
    if (sound) named[name] = sound;
    return sound;
  }
}

- (instancetype)initWithPlayer:(AVAudioPlayer *)player {
  if (!player || !(self = [super init])) return nil;
  _player = player;
  _player.delegate = self;
  _volume = 1;
  [_player prepareToPlay];
  return self;
}

- (instancetype)initWithContentsOfURL:(NSURL *)url byReference:(BOOL)byRef {
  return [self initWithPlayer:[[AVAudioPlayer alloc] initWithContentsOfURL:url error:nil]];
}
- (instancetype)initWithContentsOfFile:(NSString *)path byReference:(BOOL)byRef {
  return path ? [self initWithContentsOfURL:[NSURL fileURLWithPath:path] byReference:byRef] : nil;
}
- (instancetype)initWithData:(NSData *)data {
  return [self initWithPlayer:[[AVAudioPlayer alloc] initWithData:data error:nil]];
}

- (BOOL)play {
  _player.numberOfLoops = _loops ? -1 : 0;
  _player.volume = _volume;
  return [_player play];
}
- (BOOL)pause { [_player pause]; return YES; }
- (BOOL)resume { return [_player play]; }
- (BOOL)stop { [_player stop]; _player.currentTime = 0; return YES; }
- (BOOL)isPlaying { return _player.isPlaying; }
- (NSTimeInterval)duration { return _player.duration; }
- (NSTimeInterval)currentTime { return _player.currentTime; }
- (void)setCurrentTime:(NSTimeInterval)t { _player.currentTime = t; }
- (void)setVolume:(float)volume { _volume = volume; _player.volume = volume; }

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
  id delegate = self.delegate;
  SEL done = NSSelectorFromString(@"sound:didFinishPlaying:");
  if ([delegate respondsToSelector:done])
    ((void (*)(id, SEL, id, BOOL))[delegate methodForSelector:done])(delegate, done, self, flag);
}

AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end
