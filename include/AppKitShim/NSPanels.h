// NSOpenPanel / NSSavePanel — file choosers. Open uses the iOS document picker (Files app),
// so a web page's file upload lets you pick from iCloud Drive, On My iPhone, etc. Save hands
// back a URL in this app's Documents folder, which the Files app shows under the app's name.
#import <Foundation/Foundation.h>
#import "NSControls.h"

@class NSWindow;

@interface NSSavePanel : NSObject
+ (instancetype)savePanel;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, copy) NSString *prompt;
@property (nonatomic, copy) NSString *nameFieldStringValue;
@property (nonatomic, copy) NSURL *directoryURL;
@property (nonatomic, copy) NSArray<NSString *> *allowedFileTypes;
@property (nonatomic, copy) NSArray *allowedContentTypes; // UTType objects
@property (nonatomic, assign) BOOL canCreateDirectories;
@property (nonatomic, readonly, copy) NSURL *URL;
- (NSModalResponse)runModal;
- (void)beginWithCompletionHandler:(void (^)(NSModalResponse result))handler;
- (void)beginSheetModalForWindow:(NSWindow *)window completionHandler:(void (^)(NSModalResponse result))handler;
@end

@interface NSOpenPanel : NSSavePanel
+ (NSOpenPanel *)openPanel;
@property (nonatomic, assign) BOOL canChooseFiles;
@property (nonatomic, assign) BOOL canChooseDirectories;
@property (nonatomic, assign) BOOL allowsMultipleSelection;
@property (nonatomic, assign) BOOL resolvesAliases;
@property (nonatomic, readonly, copy) NSArray<NSURL *> *URLs;
@end
