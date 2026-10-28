// Sound for the Mac games Steam starts. A Mac game plays through the default output audio unit
// (or the system or HAL output unit); iOS has none of them, only RemoteIO, which plays to the
// speaker or headphones the same way for a game that only plays sound (GameMaker logged
// "AudioComponentFindNext unable to find a default audio output device" and stayed silent). So
// a game's own lookups of those units find RemoteIO, and the app's audio session becomes a
// playback one: it sounds with the ring switch on silent too, as a Mac has no such switch.
#import "AKShimPrivate.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

// The Mac's output unit subtypes (not in the iOS SDK): 'def ', 'sys ', 'ahal'.
enum { kMacDefaultOutput = 0x64656620, kMacSystemOutput = 0x73797320, kMacHALOutput = 0x6168616c };

static void startPlaybackSession(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSError *error;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    if (![session setCategory:AVAudioSessionCategoryPlayback error:&error] || ![session setActive:YES error:&error])
      fprintf(stderr, "[AppKitShim] game audio: the audio session didn't start: %s\n", error.localizedDescription.UTF8String);
  });
}

static AudioComponent gameFindNext(AudioComponent after, const AudioComponentDescription *desc) {
  if (!desc || desc->componentType != kAudioUnitType_Output ||
      (desc->componentSubType != kMacDefaultOutput && desc->componentSubType != kMacSystemOutput &&
       desc->componentSubType != kMacHALOutput))
    return AudioComponentFindNext(after, desc);
  AudioComponentDescription io = *desc;
  io.componentSubType = kAudioUnitSubType_RemoteIO;
  io.componentManufacturer = kAudioUnitManufacturer_Apple;
  io.componentFlags = io.componentFlagsMask = 0;
  startPlaybackSession();
  AudioComponent found = AudioComponentFindNext(after, &io);
  static dispatch_once_t logged;
  dispatch_once(&logged, ^{
    fprintf(stderr, "[AppKitShim] game audio: its Mac output unit is iOS's RemoteIO%s\n", found ? "" : " (not found!)");
  });
  return found;
}

void AKGameBindAudio(const struct mach_header *header, intptr_t slide) {
  AKRebindImports(header, slide, ^void *(const char *symbol) {
    return strcmp(symbol, "_AudioComponentFindNext") == 0 ? (void *)gameFindNext : NULL;
  });
}
