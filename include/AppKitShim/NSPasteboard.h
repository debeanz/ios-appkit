// NSPasteboard — the clipboard, backed by UIPasteboard. The general pasteboard is the
// system clipboard, so copy/paste works between Steam and other iPhone apps. The find and
// drag pasteboards are app-local, as iOS has no system-wide equivalents.
#import <Foundation/Foundation.h>

typedef NSString *NSPasteboardType NS_TYPED_EXTENSIBLE_ENUM;
typedef NSString *NSPasteboardName NS_TYPED_EXTENSIBLE_ENUM;

extern NSPasteboardType const NSPasteboardTypeString;
extern NSPasteboardType const NSPasteboardTypeURL;
extern NSPasteboardType const NSPasteboardTypeFileURL;
extern NSPasteboardType const NSPasteboardTypeHTML;
extern NSPasteboardType const NSPasteboardTypeRTF;
extern NSPasteboardType const NSPasteboardTypePNG;
extern NSPasteboardType const NSPasteboardTypeTIFF;

extern NSPasteboardName const NSPasteboardNameGeneral;
extern NSPasteboardName const NSPasteboardNameFind;
extern NSPasteboardName const NSPasteboardNameDrag;

@interface NSPasteboardItem : NSObject
@property (nonatomic, readonly, copy) NSArray<NSPasteboardType> *types;
- (BOOL)setString:(NSString *)string forType:(NSPasteboardType)type;
- (BOOL)setData:(NSData *)data forType:(NSPasteboardType)type;
- (NSString *)stringForType:(NSPasteboardType)type;
- (NSData *)dataForType:(NSPasteboardType)type;
@end

@interface NSPasteboard : NSObject
@property (class, readonly, strong) NSPasteboard *generalPasteboard;
+ (NSPasteboard *)pasteboardWithName:(NSPasteboardName)name;
+ (NSPasteboard *)pasteboardWithUniqueName;

@property (nonatomic, readonly, copy) NSPasteboardName name;
@property (nonatomic, readonly) NSInteger changeCount;
@property (nonatomic, readonly, copy) NSArray<NSPasteboardType> *types;
@property (nonatomic, readonly, copy) NSArray<NSPasteboardItem *> *pasteboardItems;

- (NSInteger)clearContents;
- (NSInteger)declareTypes:(NSArray<NSPasteboardType> *)types owner:(id)owner;
- (NSPasteboardType)availableTypeFromArray:(NSArray<NSPasteboardType> *)types;

- (BOOL)setString:(NSString *)string forType:(NSPasteboardType)type;
- (BOOL)setData:(NSData *)data forType:(NSPasteboardType)type;
- (NSString *)stringForType:(NSPasteboardType)type;
- (NSData *)dataForType:(NSPasteboardType)type;

// Accepts NSString, NSURL and NSPasteboardItem objects.
- (BOOL)writeObjects:(NSArray *)objects;
// Supports NSString and NSURL classes.
- (NSArray *)readObjectsForClasses:(NSArray<Class> *)classes options:(NSDictionary *)options;
@end
