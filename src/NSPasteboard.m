#import "AppKitShim/NSPasteboard.h"
#import <UIKit/UIKit.h>

// The same UTIs AppKit uses, which are also what UIPasteboard stores.
NSPasteboardType const NSPasteboardTypeString  = @"public.utf8-plain-text";
NSPasteboardType const NSPasteboardTypeURL     = @"public.url";
NSPasteboardType const NSPasteboardTypeFileURL = @"public.file-url";
NSPasteboardType const NSPasteboardTypeHTML    = @"public.html";
NSPasteboardType const NSPasteboardTypeRTF     = @"public.rtf";
NSPasteboardType const NSPasteboardTypePNG     = @"public.png";
NSPasteboardType const NSPasteboardTypeTIFF    = @"public.tiff";

NSPasteboardName const NSPasteboardNameGeneral = @"Apple CFPasteboard general";
NSPasteboardName const NSPasteboardNameFind    = @"Apple CFPasteboard find";
NSPasteboardName const NSPasteboardNameDrag    = @"Apple CFPasteboard drag";

static NSString *AKStringFromValue(id value) {
  if ([value isKindOfClass:NSString.class]) return value;
  if ([value isKindOfClass:NSURL.class]) return [value absoluteString];
  if ([value isKindOfClass:NSData.class]) return [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
  return nil;
}

static NSData *AKDataFromValue(id value) {
  if ([value isKindOfClass:NSData.class]) return value;
  NSString *s = AKStringFromValue(value);
  return [s dataUsingEncoding:NSUTF8StringEncoding];
}

@interface NSPasteboardItem ()
- (instancetype)initWithValues:(NSDictionary *)values;
- (NSDictionary *)_values;
@end

@implementation NSPasteboardItem {
  NSMutableDictionary<NSPasteboardType, id> *_values;
}

- (instancetype)init { return [self initWithValues:@{}]; }

- (instancetype)initWithValues:(NSDictionary *)values {
  if ((self = [super init])) _values = [values mutableCopy];
  return self;
}

- (NSDictionary *)_values { return [_values copy]; }
- (NSArray<NSPasteboardType> *)types { return _values.allKeys; }
- (BOOL)setString:(NSString *)string forType:(NSPasteboardType)type { if (!string) return NO; _values[type] = string; return YES; }
- (BOOL)setData:(NSData *)data forType:(NSPasteboardType)type { if (!data) return NO; _values[type] = data; return YES; }
- (NSString *)stringForType:(NSPasteboardType)type { return AKStringFromValue(_values[type]); }
- (NSData *)dataForType:(NSPasteboardType)type { return AKDataFromValue(_values[type]); }

@end

@implementation NSPasteboard {
  UIPasteboard *_pb;
}

- (instancetype)initWithName:(NSPasteboardName)name pasteboard:(UIPasteboard *)pb {
  if ((self = [super init])) { _name = [name copy]; _pb = pb; }
  return self;
}

+ (NSPasteboard *)generalPasteboard { return [self pasteboardWithName:NSPasteboardNameGeneral]; }

+ (NSPasteboard *)pasteboardWithName:(NSPasteboardName)name {
  static NSMutableDictionary<NSString *, NSPasteboard *> *byName;
  @synchronized (self) {
    if (!byName) byName = [NSMutableDictionary dictionary];
    NSPasteboard *existing = byName[name];
    if (existing) return existing;
    UIPasteboard *pb = [name isEqualToString:NSPasteboardNameGeneral]
        ? UIPasteboard.generalPasteboard
        : [UIPasteboard pasteboardWithName:name create:YES];
    return byName[name] = [[NSPasteboard alloc] initWithName:name pasteboard:pb];
  }
}

+ (NSPasteboard *)pasteboardWithUniqueName {
  UIPasteboard *pb = [UIPasteboard pasteboardWithUniqueName];
  return [[NSPasteboard alloc] initWithName:pb.name pasteboard:pb];
}

- (NSInteger)changeCount { return _pb.changeCount; }

// Type queries use metadata only. Reading contents another app copied makes iOS show its
// "Allow Paste" prompt, so contents are read only when the client asks for a value.
- (NSArray<NSPasteboardType> *)types {
  NSMutableArray *types = [_pb.pasteboardTypes mutableCopy];
  if (_pb.hasStrings && ![types containsObject:NSPasteboardTypeString]) [types addObject:NSPasteboardTypeString];
  if (_pb.hasURLs && ![types containsObject:NSPasteboardTypeURL]) [types addObject:NSPasteboardTypeURL];
  return types;
}

- (NSArray<NSPasteboardItem *> *)pasteboardItems {
  NSMutableArray *items = [NSMutableArray array];
  for (NSDictionary *values in _pb.items) [items addObject:[[NSPasteboardItem alloc] initWithValues:values]];
  return items;
}

- (NSInteger)clearContents {
  _pb.items = @[];
  return _pb.changeCount;
}

- (NSInteger)declareTypes:(NSArray<NSPasteboardType> *)types owner:(id)owner { return [self clearContents]; }

- (NSPasteboardType)availableTypeFromArray:(NSArray<NSPasteboardType> *)types {
  NSArray *have = self.types;
  for (NSPasteboardType t in types) if ([have containsObject:t]) return t;
  return nil;
}

// Writes merge into the first item, so declareTypes: + several setX:forType: calls build
// one multi-representation item, as on the Mac.
- (void)_mergeValue:(id)value forType:(NSPasteboardType)type {
  NSMutableDictionary *item = [_pb.items.firstObject mutableCopy] ?: [NSMutableDictionary dictionary];
  item[type] = value;
  _pb.items = @[item];
}

- (BOOL)setString:(NSString *)string forType:(NSPasteboardType)type {
  if (!string) return NO;
  [self _mergeValue:string forType:type];
  return YES;
}

- (BOOL)setData:(NSData *)data forType:(NSPasteboardType)type {
  if (!data) return NO;
  [self _mergeValue:data forType:type];
  return YES;
}

- (NSString *)stringForType:(NSPasteboardType)type {
  if ([type isEqualToString:NSPasteboardTypeString]) return _pb.string; // any text flavour
  if ([type isEqualToString:NSPasteboardTypeURL]) return _pb.URL.absoluteString;
  return AKStringFromValue([_pb valueForPasteboardType:type]);
}

- (NSData *)dataForType:(NSPasteboardType)type {
  NSData *d = [_pb dataForPasteboardType:type];
  if (!d && [type isEqualToString:NSPasteboardTypeString]) d = [_pb.string dataUsingEncoding:NSUTF8StringEncoding];
  return d;
}

- (BOOL)writeObjects:(NSArray *)objects {
  NSMutableArray *items = [NSMutableArray array];
  for (id obj in objects) {
    if ([obj isKindOfClass:NSString.class]) {
      [items addObject:@{ NSPasteboardTypeString: obj }];
    } else if ([obj isKindOfClass:NSURL.class]) {
      NSURL *url = obj;
      NSMutableDictionary *item = [@{ NSPasteboardTypeURL: url } mutableCopy];
      if (url.isFileURL) item[NSPasteboardTypeFileURL] = url.absoluteString;
      [items addObject:item];
    } else if ([obj isKindOfClass:NSPasteboardItem.class]) {
      [items addObject:[(NSPasteboardItem *)obj _values]];
    } else {
      return NO;
    }
  }
  _pb.items = items;
  return YES;
}

- (NSArray *)readObjectsForClasses:(NSArray<Class> *)classes options:(NSDictionary *)options {
  NSMutableArray *out = [NSMutableArray array];
  for (Class c in classes) {
    if (c == NSURL.class && _pb.hasURLs) [out addObjectsFromArray:_pb.URLs ?: @[]];
    else if (c == NSString.class && _pb.hasStrings) [out addObjectsFromArray:_pb.strings ?: @[]];
  }
  return out;
}

@end
