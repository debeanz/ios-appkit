#import "AKShimPrivate.h"
#import "AppKitShim/NSFontManager.h"

// Fonts the client hands in may be any font object UIKit/CoreText can use (UIFont and
// CTFont are toll-free bridged). Returns a UIFont the caller holds while it uses the CTFont.
static UIFont *AKUIFont(id font) {
  if (!font) return nil;
  if ([font isKindOfClass:UIFont.class]) return font;
  if ([font respondsToSelector:@selector(fontName)] && [font respondsToSelector:@selector(pointSize)])
    return [UIFont fontWithName:[font fontName] size:[font pointSize]];
  return nil;
}

static NSFontTraitMask AKMaskFromSymbolic(CTFontSymbolicTraits t) {
  NSFontTraitMask m = 0;
  if (t & kCTFontTraitItalic)    m |= NSItalicFontMask;
  if (t & kCTFontTraitBold)      m |= NSBoldFontMask;
  if (t & kCTFontTraitExpanded)  m |= NSExpandedFontMask;
  if (t & kCTFontTraitCondensed) m |= NSCondensedFontMask;
  if (t & kCTFontTraitMonoSpace) m |= NSFixedPitchFontMask;
  return m;
}

static UIFontDescriptorSymbolicTraits AKSymbolicFromMask(NSFontTraitMask m) {
  UIFontDescriptorSymbolicTraits t = 0;
  if (m & NSItalicFontMask)     t |= UIFontDescriptorTraitItalic;
  if (m & NSBoldFontMask)       t |= UIFontDescriptorTraitBold;
  if (m & NSExpandedFontMask)   t |= UIFontDescriptorTraitExpanded;
  if (m & NSCondensedFontMask)  t |= UIFontDescriptorTraitCondensed;
  if (m & NSFixedPitchFontMask) t |= UIFontDescriptorTraitMonoSpace;
  return t;
}

@implementation NSFontDescriptor {
  UIFontDescriptor *_d;
}

- (instancetype)initWithUIDescriptor:(UIFontDescriptor *)d { if ((self = [super init])) _d = d; return self; }

+ (NSFontDescriptor *)fontDescriptorWithName:(NSString *)fontName size:(CGFloat)size {
  return [[self alloc] initWithUIDescriptor:[UIFontDescriptor fontDescriptorWithName:fontName size:size]];
}

+ (NSFontDescriptor *)fontDescriptorWithFontAttributes:(NSDictionary *)attributes {
  return [[self alloc] initWithUIDescriptor:[UIFontDescriptor fontDescriptorWithFontAttributes:attributes ?: @{}]];
}

- (NSString *)postscriptName { return _d.postscriptName; }
- (CGFloat)pointSize { return _d.pointSize; }
- (NSDictionary *)fontAttributes { return _d.fontAttributes; }
- (uint32_t)symbolicTraits { return _d.symbolicTraits; }

- (NSFontDescriptor *)matchingFontDescriptor {
  UIFont *f = [UIFont fontWithDescriptor:_d size:_d.pointSize];
  return f ? [[NSFontDescriptor alloc] initWithUIDescriptor:f.fontDescriptor] : nil;
}

- (NSFontDescriptor *)fontDescriptorByAddingAttributes:(NSDictionary *)attributes {
  return [[NSFontDescriptor alloc] initWithUIDescriptor:[_d fontDescriptorByAddingAttributes:attributes ?: @{}]];
}

- (NSFontDescriptor *)fontDescriptorWithSize:(CGFloat)size {
  return [[NSFontDescriptor alloc] initWithUIDescriptor:[_d fontDescriptorWithSize:size]];
}

// The bold/italic/... variant. NSFontDescriptorSymbolicTraits and UIFontDescriptorSymbolicTraits
// are both Core Text's trait bits, so the value passes straight through. AppKit returns nil
// when no font has those traits; so does UIKit.
- (NSFontDescriptor *)fontDescriptorWithSymbolicTraits:(uint32_t)traits {
  UIFontDescriptor *d = [_d fontDescriptorWithSymbolicTraits:(UIFontDescriptorSymbolicTraits)traits];
  return d ? [[NSFontDescriptor alloc] initWithUIDescriptor:d] : nil;
}

- (id)objectForKey:(NSString *)attribute { return [_d objectForKey:attribute]; }

- (NSFontDescriptor *)fontDescriptorWithFamily:(NSString *)family {
  return [[NSFontDescriptor alloc] initWithUIDescriptor:[_d fontDescriptorWithFamily:family]];
}
- (NSFontDescriptor *)fontDescriptorWithFace:(NSString *)face {
  return [[NSFontDescriptor alloc] initWithUIDescriptor:[_d fontDescriptorWithFace:face]];
}

// The rest of the Mac descriptor API matches UIFontDescriptor's by name, so anything not
// defined above goes to the wrapped descriptor; what neither answers is logged and returns
// zero (AK_UNIMPLEMENTED_FORWARDER) rather than aborting.
- (id)forwardingTargetForSelector:(SEL)sel { return [_d respondsToSelector:sel] ? _d : nil; }

AK_UNIMPLEMENTED_FORWARDER

@end

@implementation NSFontManager

+ (NSFontManager *)sharedFontManager {
  static NSFontManager *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [NSFontManager new]; });
  return shared;
}

- (NSArray<NSString *> *)availableFontFamilies {
  return [UIFont.familyNames sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (NSArray<NSString *> *)availableFonts {
  NSMutableArray *names = [NSMutableArray array];
  for (NSString *family in UIFont.familyNames) [names addObjectsFromArray:[UIFont fontNamesForFamilyName:family]];
  return [names sortedArrayUsingSelector:@selector(compare:)];
}

// AppKit's member entries: @[postscript name, style name, weight (0-15, 5 = regular), traits].
- (NSArray<NSArray *> *)availableMembersOfFontFamily:(NSString *)family {
  NSMutableArray *members = [NSMutableArray array];
  for (NSString *name in [UIFont fontNamesForFamilyName:family]) {
    UIFont *f = [UIFont fontWithName:name size:12];
    if (!f) continue;
    CTFontRef ct = (__bridge CTFontRef)f;
    CFStringRef style = CTFontCopyName(ct, kCTFontStyleNameKey);
    [members addObject:@[ name, style ? CFBridgingRelease(style) : @"Regular",
                          @([self weightOfFont:f]), @([self traitsOfFont:f]) ]];
  }
  return members;
}

- (NSFontTraitMask)traitsOfFont:(id)font {
  UIFont *f = AKUIFont(font);
  return f ? AKMaskFromSymbolic(CTFontGetSymbolicTraits((__bridge CTFontRef)f)) : 0;
}

// CoreText weights run -1..1 (0 = regular); AppKit's run 0..15 (5 = regular, 9 = bold).
- (NSInteger)weightOfFont:(id)font {
  UIFont *f = AKUIFont(font);
  if (!f) return 5;
  NSDictionary *traits = CFBridgingRelease(CTFontCopyTraits((__bridge CTFontRef)f));
  double w = [traits[(__bridge NSString *)kCTFontWeightTrait] doubleValue];
  NSInteger appkit = (NSInteger)lround(5 + w * 6.25);
  return MAX(0, MIN(15, appkit));
}

- (BOOL)fontNamed:(NSString *)name hasTraits:(NSFontTraitMask)traits {
  UIFont *f = [UIFont fontWithName:name size:12];
  return f && ([self traitsOfFont:f] & traits) == traits;
}

- (id)fontWithFamily:(NSString *)family traits:(NSFontTraitMask)traits weight:(NSInteger)weight size:(CGFloat)size {
  if (weight >= 9) traits |= NSBoldFontMask;
  UIFontDescriptor *d = [UIFontDescriptor fontDescriptorWithFontAttributes:@{ UIFontDescriptorFamilyAttribute: family ?: @"" }];
  UIFontDescriptor *styled = [d fontDescriptorWithSymbolicTraits:AKSymbolicFromMask(traits)] ?: d;
  UIFont *f = [UIFont fontWithDescriptor:styled size:size];
  // An unknown family falls back to a different font; AppKit returns nil instead.
  return [f.familyName isEqualToString:family] ? f : nil;
}

- (id)convertFont:(id)font toHaveTrait:(NSFontTraitMask)trait {
  UIFont *f = AKUIFont(font);
  if (!f) return font;
  UIFontDescriptorSymbolicTraits t = f.fontDescriptor.symbolicTraits | AKSymbolicFromMask(trait);
  if (trait & NSUnboldFontMask) t &= ~UIFontDescriptorTraitBold;
  if (trait & NSUnitalicFontMask) t &= ~UIFontDescriptorTraitItalic;
  UIFontDescriptor *d = [f.fontDescriptor fontDescriptorWithSymbolicTraits:t];
  return d ? [UIFont fontWithDescriptor:d size:f.pointSize] : font;
}

- (id)convertFont:(id)font toSize:(CGFloat)size {
  UIFont *f = AKUIFont(font);
  return f ? [f fontWithSize:size] : font;
}

AK_UNIMPLEMENTED_FORWARDER

@end
