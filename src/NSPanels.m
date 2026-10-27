#import "AKShimPrivate.h"
#import "AppKitShim/NSPanels.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface NSSavePanel ()
@property (nonatomic, readwrite, copy) NSURL *URL;
- (void)_runWithCompletion:(void (^)(NSModalResponse))done;
@end

@implementation NSSavePanel

+ (instancetype)savePanel { return [self new]; }

- (instancetype)init {
  if ((self = [super init])) { _nameFieldStringValue = @"Untitled"; _canCreateDirectories = YES; }
  return self;
}

// There's no save dialog to show: the file goes to Documents/<name> (or the requested
// directory if it's inside this app's container), which the Files app exposes.
- (void)_runWithCompletion:(void (^)(NSModalResponse))done {
  NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
  NSURL *dir = docs;
  if (_directoryURL.isFileURL && [_directoryURL.path hasPrefix:NSHomeDirectory()]) dir = _directoryURL;
  [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
  self.URL = [dir URLByAppendingPathComponent:_nameFieldStringValue.lastPathComponent ?: @"Untitled"];
  done(NSModalResponseOK);
}

- (NSModalResponse)runModal {
  __block NSModalResponse result = NSModalResponseCancel;
  __block BOOL finished = NO;
  [self _runWithCompletion:^(NSModalResponse r) { result = r; finished = YES; }];
  AKRunModalUntil(^BOOL { return finished; });
  return result;
}

- (void)beginWithCompletionHandler:(void (^)(NSModalResponse))handler {
  [self _runWithCompletion:^(NSModalResponse r) { if (handler) handler(r); }];
}

- (void)beginSheetModalForWindow:(NSWindow *)window completionHandler:(void (^)(NSModalResponse))handler {
  [self beginWithCompletionHandler:handler];
}

@end

// The document picker's delegate; holds itself alive until the picker finishes.
@interface AKDocumentPickerDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, copy) void (^finish)(NSArray<NSURL *> *urls);
@property (nonatomic, strong) AKDocumentPickerDelegate *keepAlive;
@end

@implementation AKDocumentPickerDelegate
- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  self.finish(urls);
  self.keepAlive = nil;
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)picker {
  self.finish(@[]);
  self.keepAlive = nil;
}
@end

@interface NSOpenPanel ()
@property (nonatomic, readwrite, copy) NSArray<NSURL *> *URLs;
@end

@implementation NSOpenPanel

+ (NSOpenPanel *)openPanel { return [self new]; }

- (instancetype)init {
  if ((self = [super init])) { _canChooseFiles = YES; _resolvesAliases = YES; _URLs = @[]; }
  return self;
}

- (NSURL *)URL { return self.URLs.firstObject; }

// What the picker may offer: the client's UTTypes, or ones built from file extensions,
// or anything (folders only when only directories were asked for).
- (NSArray<UTType *> *)_contentTypes {
  NSMutableArray<UTType *> *types = [NSMutableArray array];
  for (id t in self.allowedContentTypes) if ([t isKindOfClass:UTType.class]) [types addObject:t];
  for (NSString *ext in self.allowedFileTypes) {
    UTType *t = [UTType typeWithFilenameExtension:ext] ?: [UTType typeWithIdentifier:ext];
    if (t) [types addObject:t];
  }
  if (!_canChooseFiles && _canChooseDirectories) return @[ UTTypeFolder ];
  return types.count ? types : @[ UTTypeItem ];
}

- (void)_runWithCompletion:(void (^)(NSModalResponse))done {
  UIViewController *top = AKTopViewController();
  if (!top) { self.URLs = @[]; done(NSModalResponseCancel); return; }
  UIDocumentPickerViewController *picker =
      [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:[self _contentTypes] asCopy:YES];
  picker.allowsMultipleSelection = _allowsMultipleSelection;
  AKDocumentPickerDelegate *delegate = [AKDocumentPickerDelegate new];
  delegate.keepAlive = delegate;
  __weak typeof(self) weakSelf = self;
  delegate.finish = ^(NSArray<NSURL *> *urls) {
    weakSelf.URLs = urls;
    done(urls.count ? NSModalResponseOK : NSModalResponseCancel);
  };
  picker.delegate = delegate;
  [top presentViewController:picker animated:YES completion:nil];
}

@end
