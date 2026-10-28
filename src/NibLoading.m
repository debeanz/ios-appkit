// Interface Builder nibs, for the Mac games Steam starts: AppKit's nib loading over the shim's
// classes. A compiled Mac nib is a keyed archive (root "IB.objectdata") or a NIBArchive file;
// either decodes into the IB objects below — an NSIBObjectData listing every object with its
// parent, the connections, and the windows visible at launch — which then become the real
// thing as in AppKit: custom objects made, window templates made into windows, outlets and
// actions connected, -awakeFromNib sent, windows shown. A class with no archive support here
// (cells, fonts, colors, menus) decodes as the nearest class up its hierarchy that has it, else
// as a stand-in that comes out of the nib as nil.
#import "AKShimPrivate.h"
#import <objc/message.h>
#import <objc/runtime.h>

static void nibLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void nibLog(NSString *fmt, ...) {
  va_list ap; va_start(ap, fmt);
  NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  fprintf(stderr, "[AppKitShim] nib: %s\n", line.UTF8String);
}

static NSArray *arrayOf(id value) {
  if ([value isKindOfClass:NSArray.class]) return value;
  if ([value isKindOfClass:NSSet.class]) return [value allObjects];
  if ([value isKindOfClass:NSOrderedSet.class]) return [value array];
  return @[];
}

static NSString *stringOf(id value) { return [value isKindOfClass:NSString.class] ? value : nil; }

static BOOL rectOf(id value, NSRect *rect) {
  if ([value isKindOfClass:NSString.class]) { *rect = CGRectFromString(value); return YES; }
  if ([value isKindOfClass:NSValue.class] && strcmp([value objCType], @encode(CGRect)) == 0) { *rect = [value CGRectValue]; return YES; }
  return NO;
}

NSRect AKNibDecodeFrame(NSCoder *coder) {
  NSRect frame = NSZeroRect;
  if (rectOf([coder decodeObjectForKey:@"NSFrame"], &frame)) return frame;
  id size = [coder decodeObjectForKey:@"NSFrameSize"];
  if ([size isKindOfClass:NSString.class]) frame.size = CGSizeFromString(size);
  else if ([size isKindOfClass:NSValue.class] && strcmp([size objCType], @encode(CGSize)) == 0) frame.size = [size CGSizeValue];
  return frame;
}

#pragma mark The archived objects

// A class with no archive support here: nothing decoded, nil once the nib is loaded.
@interface AKNibStandIn : NSObject
@end
@implementation AKNibStandIn
- (instancetype)initWithCoder:(NSCoder *)coder { return [super init]; }
@end

@interface AKNibObjectData : NSObject
@property (nonatomic, readonly) id root;   // File's Owner
@property (nonatomic, readonly) NSArray *objects, *parents, *connections, *visibleWindows;
@end
@implementation AKNibObjectData
- (instancetype)initWithCoder:(NSCoder *)coder {
  if (!(self = [super init])) return nil;
  _root = [coder decodeObjectForKey:@"NSRoot"];
  _objects = arrayOf([coder decodeObjectForKey:@"NSObjectsKeys"]);
  _parents = arrayOf([coder decodeObjectForKey:@"NSObjectsValues"]);
  _connections = arrayOf([coder decodeObjectForKey:@"NSConnections"]);
  _visibleWindows = arrayOf([coder decodeObjectForKey:@"NSVisibleWindows"]);
  return self;
}
@end

// An object of a class the nib names (the app delegate, a controller), made when it loads.
@interface AKNibCustomObject : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@end
@implementation AKNibCustomObject
- (instancetype)initWithCoder:(NSCoder *)coder {
  if ((self = [super init])) _name = stringOf([coder decodeObjectForKey:@"NSClassName"]);
  return self;
}
@end

// The view class a nib names, or nil.
static Class viewClass(NSString *name) {
  Class c = name ? NSClassFromString(name) : Nil;
  return [c isSubclassOfClass:NSView.class] ? c : Nil;
}

// A view of the app's own class: made with -initWithFrame:, as AppKit does, then given the
// archived flags and subviews.
@interface AKNibCustomView : NSObject
@end
@implementation AKNibCustomView
- (id)initWithCoder:(NSCoder *)coder {
  NSString *name = stringOf([coder decodeObjectForKey:@"NSClassName"]);
  Class c = viewClass(name) ?: viewClass(stringOf([coder decodeObjectForKey:@"NSExtension"])) ?: NSView.class;
  if (!viewClass(name)) nibLog(@"no view class %@ here; an %s stands in", name, class_getName(c));
  NSView *view = [[c alloc] initWithFrame:AKNibDecodeFrame(coder)];
  [view _ak_applyNibCoder:coder];
  return (id)view;   // the view stands in for this placeholder, as AppKit's does
}
@end

static Class decodingClass(NSString *name);

// An object of the app's subclass of an AppKit class, archived as that class: made from the
// same archived values with the subclass when it exists.
@interface AKNibClassSwapper : NSObject
@property (nonatomic, readonly) id instance;
@end
@implementation AKNibClassSwapper
- (id)initWithCoder:(NSCoder *)coder {
  NSString *name = stringOf([coder decodeObjectForKey:@"NSClassName"]);
  NSString *original = stringOf([coder decodeObjectForKey:@"NSOriginalClassName"]);
  Class c = decodingClass(name);
  if (!c) {
    c = decodingClass(original) ?: AKNibStandIn.class;
    nibLog(@"no class %@ here; %s stands in", name, class_getName(c));
  }
  _instance = [[c alloc] initWithCoder:coder];
  return _instance;
}
@end

@interface AKNibWindowTemplate : NSObject
@property (nonatomic, readonly) NSWindow *window;
@end
@implementation AKNibWindowTemplate {
  NSRect _rect;
  NSWindowStyleMask _style;
  NSInteger _backing;
  uint32_t _flags;
  NSString *_title, *_windowClass;
  id _view;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
  if (!(self = [super init])) return nil;
  rectOf([coder decodeObjectForKey:@"NSWindowRect"], &_rect);
  _style = (NSWindowStyleMask)[coder decodeInt64ForKey:@"NSWindowStyleMask"];
  _backing = (NSInteger)[coder decodeInt64ForKey:@"NSWindowBacking"];
  _flags = (uint32_t)[coder decodeInt64ForKey:@"NSWTFlags"];
  _title = stringOf([coder decodeObjectForKey:@"NSWindowTitle"]);
  _windowClass = stringOf([coder decodeObjectForKey:@"NSWindowClass"]);
  _view = [coder decodeObjectForKey:@"NSWindowView"];
  return self;
}

@synthesize window = _window;

- (NSWindow *)window {
  if (_window) return _window;
  Class c = _windowClass ? NSClassFromString(_windowClass) : Nil;
  if (![c isSubclassOfClass:NSWindow.class]) c = NSWindow.class;
  BOOL defer = (_flags & 0x20000000) != 0;
  _window = [[c alloc] initWithContentRect:_rect styleMask:_style backing:(NSBackingStoreType)_backing defer:defer];
  if (_title) _window.title = _title;
  if ([_view isKindOfClass:NSView.class]) _window.contentView = _view;
  return _window;
}
@end

@interface AKNibConnector : NSObject
@property (nonatomic, readonly) id source, destination;
@property (nonatomic, readonly, copy) NSString *label;   // the outlet, or the action's selector
@end
@implementation AKNibConnector
- (instancetype)initWithCoder:(NSCoder *)coder {
  if (!(self = [super init])) return nil;
  _source = [coder decodeObjectForKey:@"NSSource"];
  _destination = [coder decodeObjectForKey:@"NSDestination"];
  _label = stringOf([coder decodeObjectForKey:@"NSLabel"]);
  return self;
}
@end
@interface AKNibOutletConnector : AKNibConnector
@end
@implementation AKNibOutletConnector
@end
@interface AKNibControlConnector : AKNibConnector
@end
@implementation AKNibControlConnector
@end

#pragma mark Which class decodes what

static NSDictionary<NSString *, Class> *nibClasses(void) {
  static NSDictionary *classes;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    classes = @{
      @"NSIBObjectData": AKNibObjectData.class,
      @"NSCustomObject": AKNibCustomObject.class,
      @"NSCustomView": AKNibCustomView.class,
      @"NSClassSwapper": AKNibClassSwapper.class,
      @"NSWindowTemplate": AKNibWindowTemplate.class,
      @"NSNibOutletConnector": AKNibOutletConnector.class,
      @"NSNibControlConnector": AKNibControlConnector.class,
    };
  });
  return classes;
}

// Foundation's own archives read the same here as on a Mac.
static NSSet<NSString *> *foundationValues(void) {
  static NSSet *names;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    names = [NSSet setWithArray:@[
      @"NSString", @"NSMutableString", @"NSArray", @"NSMutableArray", @"NSDictionary", @"NSMutableDictionary",
      @"NSSet", @"NSMutableSet", @"NSOrderedSet", @"NSMutableOrderedSet", @"NSNumber", @"NSData", @"NSMutableData",
      @"NSValue", @"NSDate", @"NSURL", @"NSNull", @"NSUUID", @"NSAttributedString", @"NSMutableAttributedString",
    ]];
  });
  return names;
}

// The class that decodes an archived `name` here, or Nil: the nib's own objects, Foundation's
// values, views and pixel formats, and classes of the app's own that decode themselves. System
// classes are left out (iOS's NSLayoutConstraint or NSParagraphStyle read a Mac archive wrong).
static Class decodingClass(NSString *name) {
  if (![name isKindOfClass:NSString.class]) return Nil;
  Class c = nibClasses()[name];
  if (c) return c;
  if (!(c = NSClassFromString(name))) return Nil;
  if ([foundationValues() containsObject:name]) return c;
  if (![c instancesRespondToSelector:@selector(initWithCoder:)]) return Nil;
  if ([c isSubclassOfClass:NSView.class] || [c isSubclassOfClass:NSOpenGLPixelFormat.class]) return c;
  return AKAddressIsInGame((const void *)class_getMethodImplementation(c, @selector(initWithCoder:))) ? c : Nil;
}

// For a class and its superclasses (most derived first): the first that decodes here. Notes the
// ones decoded as something else.
static Class classForArchived(NSArray *hierarchy, NSMutableSet<NSString *> *standIns) {
  NSString *name = hierarchy.firstObject;
  for (id each in hierarchy) {
    Class c = decodingClass(each);
    if (!c) continue;
    if (each != name) [standIns addObject:[NSString stringWithFormat:@"%@ (as %@)", name, each]];
    return c;
  }
  if (name) [standIns addObject:name];
  return AKNibStandIn.class;
}

#pragma mark Keyed archives

@interface AKNibUnarchiverDelegate : NSObject <NSKeyedUnarchiverDelegate>
@property (nonatomic, strong) NSMutableSet<NSString *> *standIns;
@end
@implementation AKNibUnarchiverDelegate
- (Class)unarchiver:(NSKeyedUnarchiver *)unarchiver cannotDecodeObjectOfClassName:(NSString *)name originalClasses:(NSArray<NSString *> *)classNames {
  return classForArchived(classNames.count ? classNames : @[ name ], _standIns);
}
@end

static id decodeKeyedArchive(NSData *bytes, NSMutableSet<NSString *> *standIns) {
  NSError *error;
  NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:bytes error:&error];
  if (!unarchiver) { nibLog(@"not a keyed archive: %@", error.localizedDescription); return nil; }
  unarchiver.requiresSecureCoding = NO;
  AKNibUnarchiverDelegate *delegate = [AKNibUnarchiverDelegate new];
  delegate.standIns = standIns;
  unarchiver.delegate = delegate;
  // Every class the archive names, mapped up front: one found here that can't read it
  // (the shim's NSColor, NSMenu) would otherwise be asked to.
  NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:NULL error:NULL];
  NSArray *objects = [plist isKindOfClass:NSDictionary.class] ? arrayOf(plist[@"$objects"]) : @[];
  for (NSDictionary *o in objects) {
    if (![o isKindOfClass:NSDictionary.class] || !stringOf(o[@"$classname"])) continue;
    NSString *name = o[@"$classname"];
    NSArray *hierarchy = [o[@"$classes"] isKindOfClass:NSArray.class] && [o[@"$classes"] count] ? o[@"$classes"] : @[ name ];
    Class c = classForArchived(hierarchy, standIns);
    if (c != NSClassFromString(name)) [unarchiver setClass:c forClassName:name];
  }
  id root = nil;
  @try {
    root = [unarchiver decodeObjectForKey:@"IB.objectdata"];
  } @catch (NSException *e) {
    nibLog(@"it doesn't decode: %@ (%@)", e.name, e.reason);
  }
  [unarchiver finishDecoding];
  return root;
}

#pragma mark NIBArchive files

// The binary nib format Xcode also writes: a header, then tables of objects (class, first
// value, value count), keys, values (key, type, data) and class names (with fallback classes).
// Numbers are varints whose last byte has its top bit set.
typedef struct { uint32_t classIndex, firstValue, valueCount; } AKNibArchiveObject;
typedef struct { uint32_t key; uint8_t type; uint32_t length; const uint8_t *bytes; } AKNibArchiveValue;
enum { kNibInt8, kNibInt16, kNibInt32, kNibInt64, kNibTrue, kNibFalse, kNibFloat, kNibDouble, kNibData, kNibNil, kNibObject };

typedef struct { const uint8_t *p, *end; BOOL bad; } AKNibReader;

static uint64_t readVarint(AKNibReader *r) {
  uint64_t v = 0;
  for (int shift = 0; r->p < r->end && shift < 64; shift += 7) {
    uint8_t b = *r->p++;
    v |= (uint64_t)(b & 0x7F) << shift;
    if (b & 0x80) return v;
  }
  r->bad = YES;
  return 0;
}

static const uint8_t *readBytes(AKNibReader *r, uint64_t n) {
  if (r->bad || (uint64_t)(r->end - r->p) < n) { r->bad = YES; return NULL; }
  const uint8_t *b = r->p;
  r->p += n;
  return b;
}

@interface AKNibArchiveDecoder : NSCoder
- (instancetype)initWithData:(NSData *)data standIns:(NSMutableSet<NSString *> *)standIns;
- (id)decodeRoot;
@end

@implementation AKNibArchiveDecoder {
  NSData *_data;
  AKNibArchiveObject *_objects;
  uint32_t _objectCount;
  NSArray<NSString *> *_keys;
  AKNibArchiveValue *_values;
  uint32_t _valueCount;
  NSArray<NSArray<NSString *> *> *_classes;   // each: the class, then its fallbacks
  NSMutableArray *_decoded;                    // per object, NSNull until made
  uint8_t *_state;                             // 0 not yet, 1 being decoded, 2 done
  uint32_t _current;                           // the object whose values are being read
  NSMutableSet<NSString *> *_standIns;
}

- (instancetype)initWithData:(NSData *)data standIns:(NSMutableSet<NSString *> *)standIns {
  if (!(self = [super init])) return nil;
  _data = data;
  _standIns = standIns;
  _current = UINT32_MAX;
  const uint8_t *base = data.bytes;
  uint64_t size = data.length;
  if (size < 50 || memcmp(base, "NIBArchive", 10) != 0) return nil;
  uint32_t h[8];
  memcpy(h, base + 18, sizeof h);
  for (int i = 1; i < 8; i += 2) if (h[i] > size || h[i - 1] > size) return nil;

  AKNibReader r = { base + h[1], base + size, NO };
  _objectCount = h[0];
  _objects = calloc(_objectCount ?: 1, sizeof *_objects);
  for (uint32_t i = 0; i < _objectCount && !r.bad; i++) {
    _objects[i].classIndex = (uint32_t)readVarint(&r);
    _objects[i].firstValue = (uint32_t)readVarint(&r);
    _objects[i].valueCount = (uint32_t)readVarint(&r);
  }

  r = (AKNibReader){ base + h[3], base + size, r.bad };
  NSMutableArray *keys = [NSMutableArray arrayWithCapacity:h[2]];
  for (uint32_t i = 0; i < h[2] && !r.bad; i++) {
    uint64_t n = readVarint(&r);
    const uint8_t *b = readBytes(&r, n);
    [keys addObject:(b ? [[NSString alloc] initWithBytes:b length:n encoding:NSUTF8StringEncoding] : nil) ?: @""];
  }
  _keys = keys;

  r = (AKNibReader){ base + h[5], base + size, r.bad };
  _valueCount = h[4];
  _values = calloc(_valueCount ?: 1, sizeof *_values);
  static const uint8_t fixed[] = { 1, 2, 4, 8, 0, 0, 4, 8, 0, 0, 4 };
  for (uint32_t i = 0; i < _valueCount && !r.bad; i++) {
    AKNibArchiveValue *v = &_values[i];
    v->key = (uint32_t)readVarint(&r);
    const uint8_t *type = readBytes(&r, 1);
    if (!type || *type > kNibObject) { r.bad = YES; break; }
    v->type = *type;
    v->length = v->type == kNibData ? (uint32_t)readVarint(&r) : fixed[v->type];
    v->bytes = readBytes(&r, v->length);
  }

  r = (AKNibReader){ base + h[7], base + size, r.bad };
  NSMutableArray *classes = [NSMutableArray arrayWithCapacity:h[6]];
  NSMutableArray<NSArray<NSNumber *> *> *fallbacks = [NSMutableArray arrayWithCapacity:h[6]];
  for (uint32_t i = 0; i < h[6] && !r.bad; i++) {
    uint64_t n = readVarint(&r), extra = readVarint(&r);
    const uint8_t *more = readBytes(&r, extra * 4), *b = readBytes(&r, n);
    if (!b) break;
    NSMutableArray *others = [NSMutableArray array];
    for (uint64_t k = 0; k < extra; k++) { int32_t idx; memcpy(&idx, more + k * 4, 4); [others addObject:@(idx)]; }
    while (n && b[n - 1] == 0) n--;
    [classes addObject:[[NSString alloc] initWithBytes:b length:n encoding:NSUTF8StringEncoding] ?: @""];
    [fallbacks addObject:others];
  }
  if (r.bad) return nil;
  // Each class with its fallbacks, by name.
  NSMutableArray *named = [NSMutableArray arrayWithCapacity:classes.count];
  for (NSUInteger i = 0; i < classes.count; i++) {
    NSMutableArray *chain = [NSMutableArray arrayWithObject:classes[i]];
    for (NSNumber *idx in fallbacks[i]) if (idx.unsignedIntegerValue < classes.count) [chain addObject:classes[idx.unsignedIntegerValue]];
    [named addObject:chain];
  }
  _classes = named;
  for (uint32_t i = 0; i < _objectCount; i++)
    if (_objects[i].classIndex >= _classes.count || (uint64_t)_objects[i].firstValue + _objects[i].valueCount > _valueCount) return nil;
  for (uint32_t i = 0; i < _valueCount; i++) if (_values[i].key >= _keys.count) return nil;

  _decoded = [NSMutableArray arrayWithCapacity:_objectCount];
  for (uint32_t i = 0; i < _objectCount; i++) [_decoded addObject:NSNull.null];
  _state = calloc(_objectCount ?: 1, 1);
  return self;
}

- (void)dealloc {
  free(_objects);
  free(_values);
  free(_state);
}

- (BOOL)allowsKeyedCoding { return YES; }
- (BOOL)requiresSecureCoding { return NO; }
- (NSInteger)versionForClassName:(NSString *)name { return 0; }

- (const AKNibArchiveValue *)valueForKey_:(NSString *)key {
  if (_current >= _objectCount) return NULL;
  AKNibArchiveObject o = _objects[_current];
  for (uint32_t i = 0; i < o.valueCount; i++) {
    const AKNibArchiveValue *v = &_values[o.firstValue + i];
    if ([_keys[v->key] isEqualToString:key]) return v;
  }
  return NULL;
}

static NSNumber *numberOf(const AKNibArchiveValue *v) {
  if (!v) return nil;
  switch (v->type) {
    case kNibInt8: return @(*(const int8_t *)v->bytes);
    case kNibInt16: { int16_t x; memcpy(&x, v->bytes, 2); return @(x); }
    case kNibInt32: { int32_t x; memcpy(&x, v->bytes, 4); return @(x); }
    case kNibInt64: { int64_t x; memcpy(&x, v->bytes, 8); return @(x); }
    case kNibTrue: return @YES;
    case kNibFalse: return @NO;
    case kNibFloat: { float x; memcpy(&x, v->bytes, 4); return @(x); }
    case kNibDouble: { double x; memcpy(&x, v->bytes, 8); return @(x); }
    default: return nil;
  }
}

- (id)objectOf_:(const AKNibArchiveValue *)v {
  if (!v) return nil;
  if (v->type == kNibObject) { uint32_t ref; memcpy(&ref, v->bytes, 4); return [self object_:ref]; }
  if (v->type == kNibData) return [NSData dataWithBytes:v->bytes length:v->length];
  return numberOf(v);
}

- (BOOL)containsValueForKey:(NSString *)key { return [self valueForKey_:key] != NULL; }
- (id)decodeObjectForKey:(NSString *)key { return [self objectOf_:[self valueForKey_:key]]; }
- (id)decodeObjectOfClass:(Class)c forKey:(NSString *)key { return [self decodeObjectForKey:key]; }
- (id)decodeObjectOfClasses:(NSSet<Class> *)classes forKey:(NSString *)key { return [self decodeObjectForKey:key]; }
- (BOOL)decodeBoolForKey:(NSString *)key { return [numberOf([self valueForKey_:key]) boolValue]; }
- (int)decodeIntForKey:(NSString *)key { return [numberOf([self valueForKey_:key]) intValue]; }
- (int32_t)decodeInt32ForKey:(NSString *)key { return [numberOf([self valueForKey_:key]) intValue]; }
- (int64_t)decodeInt64ForKey:(NSString *)key { return [numberOf([self valueForKey_:key]) longLongValue]; }
- (NSInteger)decodeIntegerForKey:(NSString *)key { return [numberOf([self valueForKey_:key]) integerValue]; }
- (float)decodeFloatForKey:(NSString *)key { return [numberOf([self valueForKey_:key]) floatValue]; }
- (double)decodeDoubleForKey:(NSString *)key { return [numberOf([self valueForKey_:key]) doubleValue]; }

- (const uint8_t *)decodeBytesForKey:(NSString *)key returnedLength:(NSUInteger *)length {
  const AKNibArchiveValue *v = [self valueForKey_:key];
  BOOL data = v && v->type == kNibData;
  if (length) *length = data ? v->length : 0;
  return data ? v->bytes : NULL;
}

// The values of the current object under the nib encoder's empty key: a collection's items.
- (NSArray *)items_ {
  NSMutableArray *items = [NSMutableArray array];
  AKNibArchiveObject o = _objects[_current];
  for (uint32_t i = 0; i < o.valueCount; i++) {
    const AKNibArchiveValue *v = &_values[o.firstValue + i];
    if (![_keys[v->key] isEqualToString:@"UINibEncoderEmptyKey"]) continue;
    id item = [self objectOf_:v];
    if (item) [items addObject:item];
  }
  return items;
}

- (id)make_:(uint32_t)index {
  NSArray<NSString *> *chain = _classes[_objects[index].classIndex];
  NSString *name = chain.firstObject;
  // Foundation's strings and collections, as the nib encoder writes them.
  if ([name isEqualToString:@"NSString"] || [name isEqualToString:@"NSMutableString"]) {
    NSData *utf8 = [self decodeObjectForKey:@"NS.bytes"];
    NSString *s = [utf8 isKindOfClass:NSData.class] ? [[NSString alloc] initWithData:utf8 encoding:NSUTF8StringEncoding] : @"";
    return [name isEqualToString:@"NSString"] ? s : [s mutableCopy];
  }
  if ([name hasSuffix:@"Array"] && [name hasPrefix:@"NS"]) return [name hasPrefix:@"NSMutable"] ? [[self items_] mutableCopy] : [self items_];
  if ([name isEqualToString:@"NSSet"] || [name isEqualToString:@"NSMutableSet"]) return [NSMutableSet setWithArray:[self items_]];
  if ([name isEqualToString:@"NSOrderedSet"] || [name isEqualToString:@"NSMutableOrderedSet"]) return [NSMutableOrderedSet orderedSetWithArray:[self items_]];
  if ([name isEqualToString:@"NSDictionary"] || [name isEqualToString:@"NSMutableDictionary"]) {
    NSArray *items = [self items_];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i + 1 < items.count; i += 2) if ([items[i] conformsToProtocol:@protocol(NSCopying)]) d[items[i]] = items[i + 1];
    return d;
  }
  if ([name isEqualToString:@"NSData"] || [name isEqualToString:@"NSMutableData"]) return [self decodeObjectForKey:@"NS.bytes"];
  if ([name isEqualToString:@"NSNumber"]) {
    AKNibArchiveObject o = _objects[index];
    for (uint32_t i = 0; i < o.valueCount; i++) { NSNumber *n = numberOf(&_values[o.firstValue + i]); if (n) return n; }
    return nil;
  }

  Class c = classForArchived(chain, _standIns);
  id object = [c alloc];
  _decoded[index] = object;   // what a reference back to it gets while it decodes
  object = [object initWithCoder:self];
  return [object awakeAfterUsingCoder:self];
}

- (id)object_:(uint32_t)index {
  if (index >= _objectCount) return nil;
  if (_state[index]) { id o = _decoded[index]; return o == NSNull.null ? nil : o; }
  _state[index] = 1;
  uint32_t outer = _current;
  _current = index;
  id object = [self make_:index];
  _current = outer;
  _decoded[index] = object ?: NSNull.null;
  _state[index] = 2;
  return object;
}

// A Mac nib's first object holds its NSIBObjectData under IB.objectdata, as the keyed archive's
// root does; otherwise it is the object data itself.
- (id)decodeRoot {
  if (!_objectCount) return nil;
  _current = 0;
  id data = [self decodeObjectForKey:@"IB.objectdata"];
  _current = UINT32_MAX;
  if (data) return data;
  id root = [self object_:0];
  if (![root isKindOfClass:AKNibObjectData.class]) {
    NSMutableArray *keys = [NSMutableArray array];
    for (uint32_t i = 0; i < _objects[0].valueCount; i++) [keys addObject:_keys[_values[_objects[0].firstValue + i].key]];
    nibLog(@"its first object is a %@ with %@, not Interface Builder's object data",
           _classes[_objects[0].classIndex].firstObject, [keys componentsJoinedByString:@", "]);
  }
  return root;
}
@end

#pragma mark Loading

// What an archived object is once the nib is loaded: the owner for File's Owner (and NSApp for
// the application), the object made for a custom object or window template, nil for the first
// responder and stand-ins.
static id realObject(id archived, AKNibObjectData *data, id owner, NSMapTable *made, NSMutableSet<NSString *> *missing) {
  if (!archived || [archived isKindOfClass:AKNibStandIn.class]) return nil;
  if (archived == data.root) return owner;
  id cached = [made objectForKey:archived];
  if (cached) return cached == NSNull.null ? nil : cached;
  id real = archived;
  if ([archived isKindOfClass:AKNibCustomObject.class]) {
    NSString *name = [(AKNibCustomObject *)archived name];
    Class c = name ? NSClassFromString(name) : Nil;
    if ([name isEqualToString:@"NSApplication"] || [c isSubclassOfClass:NSApplication.class]) real = NSApp;
    else if ([name isEqualToString:@"FirstResponder"]) real = nil;
    else if (c == NSFontManager.class) real = NSFontManager.sharedFontManager;
    else if (!c) { real = nil; [missing addObject:name ?: @"(unnamed)"]; }
    else real = [[c alloc] init];
  } else if ([archived isKindOfClass:AKNibWindowTemplate.class]) {
    real = [(AKNibWindowTemplate *)archived window];
  } else if ([archived isKindOfClass:AKNibClassSwapper.class]) {
    real = [(AKNibClassSwapper *)archived instance];   // if the unarchiver kept the swapper itself
  }
  [made setObject:real ?: NSNull.null forKey:archived];
  return real;
}

static NSMutableArray *gKeptNibObjects;   // top-level objects of nibs loaded without an array for them

static BOOL instantiate(AKNibObjectData *data, id owner, NSString *label, NSSet<NSString *> *standIns, NSArray **topLevelObjects) {
  NSMapTable *made = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
                                           valueOptions:NSPointerFunctionsStrongMemory];
  NSMutableSet<NSString *> *missing = [NSMutableSet set];
  id (^real)(id) = ^id(id archived) { return realObject(archived, data, owner, made, missing); };

  // Everything made first (custom objects, windows), then connected, as AppKit does.
  NSMutableArray *all = [NSMutableArray array], *topLevel = [NSMutableArray array];
  NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality];
  NSMutableArray<NSString *> *custom = [NSMutableArray array], *views = [NSMutableArray array];
  NSUInteger windows = 0;
  for (NSUInteger i = 0; i < data.objects.count; i++) {
    id archived = data.objects[i];
    id object = real(archived);
    if (!object || object == owner || [seen containsObject:object]) continue;
    [seen addObject:object];
    [all addObject:object];
    if (i < data.parents.count && data.parents[i] == data.root) [topLevel addObject:object];
    if ([object isKindOfClass:NSWindow.class]) windows++;
    else if ([archived isKindOfClass:AKNibCustomObject.class]) [custom addObject:@(class_getName([object class]))];
    else if ([object isKindOfClass:NSView.class] && [object class] != NSView.class) [views addObject:@(class_getName([object class]))];
  }

  NSUInteger outlets = 0, actions = 0;
  NSMutableArray<NSString *> *failed = [NSMutableArray array];
  for (AKNibConnector *connector in data.connections) {
    if (![connector isKindOfClass:AKNibConnector.class] || !connector.label.length) continue;
    id source = real(connector.source), destination = real(connector.destination);
    if (!source) continue;   // from something not made here (a menu item)
    if ([connector isKindOfClass:AKNibOutletConnector.class]) {
      if (!destination) continue;
      @try {
        [source setValue:destination forKey:connector.label];
        outlets++;
      } @catch (NSException *e) {
        [failed addObject:[NSString stringWithFormat:@"%s.%@", object_getClassName(source), connector.label]];
      }
    } else if ([connector isKindOfClass:AKNibControlConnector.class]) {
      if (![source respondsToSelector:@selector(setAction:)]) continue;
      ((void (*)(id, SEL, SEL))objc_msgSend)(source, @selector(setAction:), NSSelectorFromString(connector.label));
      if ([source respondsToSelector:@selector(setTarget:)]) ((void (*)(id, SEL, id))objc_msgSend)(source, @selector(setTarget:), destination);
      actions++;
    }
  }

  for (id object in all) if ([object respondsToSelector:@selector(awakeFromNib)]) [object awakeFromNib];
  if ([owner respondsToSelector:@selector(awakeFromNib)]) [owner awakeFromNib];

  NSUInteger shown = 0;
  for (id template in data.visibleWindows) {
    NSWindow *window = real(template);
    if (![window isKindOfClass:NSWindow.class]) continue;
    [window makeKeyAndOrderFront:nil];
    shown++;
  }

  if (topLevelObjects) *topLevelObjects = topLevel;
  else {
    if (!gKeptNibObjects) gKeptNibObjects = [NSMutableArray array];
    [gKeptNibObjects addObjectsFromArray:topLevel];
  }

  nibLog(@"%@ loaded: %lu objects; %lu window%s (%lu shown); made %@; views %@; %lu outlets and %lu actions connected%@%@%@",
         label, (unsigned long)all.count, (unsigned long)windows, windows == 1 ? "" : "s", (unsigned long)shown,
         custom.count ? [custom componentsJoinedByString:@", "] : @"nothing",
         views.count ? [views componentsJoinedByString:@", "] : @"plain only", (unsigned long)outlets, (unsigned long)actions,
         failed.count ? [NSString stringWithFormat:@"; outlets that didn't take: %@", [failed componentsJoinedByString:@", "]] : @"",
         missing.count ? [NSString stringWithFormat:@"; classes not found: %@", [missing.allObjects componentsJoinedByString:@", "]] : @"",
         standIns.count ? [NSString stringWithFormat:@"; stood in for: %@", [[standIns.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]] : @"");
  return YES;
}

// The nib file for `name`: localized copies included, and in a nib bundle (a folder) its
// keyedobjects.nib or the newest per-OS-version one.
static NSString *nibFile(NSString *name, NSBundle *bundle) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *base = name.stringByDeletingPathExtension;
  NSString *path = name.isAbsolutePath ? name : [bundle pathForResource:base ofType:@"nib"];
  if (!path && !name.isAbsolutePath && bundle.resourcePath) {
    NSString *file = [base.lastPathComponent stringByAppendingPathExtension:@"nib"];
    for (NSString *dir in @[ @"Base.lproj", @"en.lproj", @"English.lproj" ]) {
      NSString *p = [[bundle.resourcePath stringByAppendingPathComponent:dir] stringByAppendingPathComponent:file];
      if ([fm fileExistsAtPath:p]) { path = p; break; }
    }
    for (NSString *dir in path ? @[] : [fm contentsOfDirectoryAtPath:bundle.resourcePath error:nil]) {
      NSString *p = [[bundle.resourcePath stringByAppendingPathComponent:dir] stringByAppendingPathComponent:file];
      if ([dir.pathExtension isEqualToString:@"lproj"] && [fm fileExistsAtPath:p]) { path = p; break; }
    }
  }
  BOOL folder = NO;
  if (!path || ![fm fileExistsAtPath:path isDirectory:&folder]) return nil;
  if (!folder) return path;
  NSString *plain = [path stringByAppendingPathComponent:@"keyedobjects.nib"];
  if ([fm fileExistsAtPath:plain]) return plain;
  NSString *best;
  for (NSString *f in [fm contentsOfDirectoryAtPath:path error:nil])
    if ([f hasPrefix:@"keyedobjects"] && [f.pathExtension isEqualToString:@"nib"] && (!best || [f compare:best options:NSNumericSearch] == NSOrderedDescending)) best = f;
  return best ? [path stringByAppendingPathComponent:best] : nil;
}

static BOOL loadNibData(NSData *bytes, NSString *label, id owner, NSArray **topLevelObjects) {
  NSMutableSet<NSString *> *standIns = [NSMutableSet set];
  id root = nil;
  if (bytes.length >= 10 && memcmp(bytes.bytes, "NIBArchive", 10) == 0) {
    AKNibArchiveDecoder *decoder = [[AKNibArchiveDecoder alloc] initWithData:bytes standIns:standIns];
    if (!decoder) nibLog(@"%@: its NIBArchive tables don't read", label);
    @try {
      root = [decoder decodeRoot];
    } @catch (NSException *e) {
      nibLog(@"%@ doesn't decode: %@ (%@)", label, e.name, e.reason);
    }
  } else {
    root = decodeKeyedArchive(bytes, standIns);
  }
  if (![root isKindOfClass:AKNibObjectData.class]) {
    nibLog(@"%@: no Interface Builder objects in it (%s)", label, root ? object_getClassName(root) : "nothing decoded");
    return NO;
  }
  return instantiate(root, owner, label, standIns, topLevelObjects);
}

BOOL AKLoadNib(NSString *name, NSBundle *bundle, id owner, NSArray **topLevelObjects) {
  if (!name.length) return NO;
  bundle = bundle ?: NSBundle.mainBundle;
  NSString *path = nibFile(name, bundle);
  if (!path) { nibLog(@"%@: not in %@", name, bundle.bundlePath.lastPathComponent); return NO; }
  NSData *bytes = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
  if (!bytes) { nibLog(@"%@: can't read %@", name, path); return NO; }
  return loadNibData(bytes, name.lastPathComponent.stringByDeletingPathExtension, owner, topLevelObjects);
}

#pragma mark AppKit's entry points

@interface NSBundle (AKShimNibLoading)
- (BOOL)loadNibNamed:(NSString *)name owner:(id)owner topLevelObjects:(NSArray **)topLevelObjects;
+ (BOOL)loadNibNamed:(NSString *)name owner:(id)owner;
@end

@implementation NSBundle (AKShimNibLoading)
- (BOOL)loadNibNamed:(NSString *)name owner:(id)owner topLevelObjects:(NSArray **)topLevelObjects {
  return AKLoadNib(name, self, owner, topLevelObjects);
}
+ (BOOL)loadNibNamed:(NSString *)name owner:(id)owner { return AKLoadNib(name, NSBundle.mainBundle, owner, NULL); }
@end

@interface NSNib : NSObject
- (instancetype)initWithNibNamed:(NSString *)name bundle:(NSBundle *)bundle;
- (instancetype)initWithNibData:(NSData *)data bundle:(NSBundle *)bundle;
- (BOOL)instantiateWithOwner:(id)owner topLevelObjects:(NSArray **)topLevelObjects;
@end

@implementation NSNib {
  NSData *_bytes;
  NSString *_label;
}

- (instancetype)initWithNibNamed:(NSString *)name bundle:(NSBundle *)bundle {
  NSString *path = nibFile(name, bundle ?: NSBundle.mainBundle);
  NSData *bytes = path ? [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL] : nil;
  if (!bytes) { nibLog(@"%@: not in %@", name, (bundle ?: NSBundle.mainBundle).bundlePath.lastPathComponent); return nil; }
  if ((self = [super init])) { _bytes = bytes; _label = name.lastPathComponent.stringByDeletingPathExtension; }
  return self;
}

- (instancetype)initWithNibData:(NSData *)data bundle:(NSBundle *)bundle {
  if (!data || !(self = [super init])) return nil;
  _bytes = data;
  _label = @"nib data";
  return self;
}

- (BOOL)instantiateWithOwner:(id)owner topLevelObjects:(NSArray **)topLevelObjects {
  return loadNibData(_bytes, _label, owner, topLevelObjects);
}

- (BOOL)instantiateNibWithOwner:(id)owner topLevelObjects:(NSArray **)topLevelObjects {
  return [self instantiateWithOwner:owner topLevelObjects:topLevelObjects];
}
@end
