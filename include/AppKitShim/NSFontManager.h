// NSFontManager / NSFontDescriptor — font enumeration and trait queries. UIKit has the fonts
// and NSFontDescriptor is toll-free-ish with UIFontDescriptor; the shim answers from there.
#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#import "NSGeometry.h"

typedef NS_OPTIONS(NSUInteger, NSFontTraitMask) {
  NSItalicFontMask      = 0x00000001,
  NSBoldFontMask        = 0x00000002,
  NSUnboldFontMask      = 0x00000004,
  NSNonStandardCharacterSetFontMask = 0x00000008,
  NSNarrowFontMask      = 0x00000010,
  NSExpandedFontMask    = 0x00000020,
  NSCondensedFontMask   = 0x00000040,
  NSSmallCapsFontMask   = 0x00000080,
  NSPosterFontMask      = 0x00000100,
  NSCompressedFontMask  = 0x00000200,
  NSFixedPitchFontMask  = 0x00000400,
  NSUnitalicFontMask    = 0x01000000,
};

@interface NSFontDescriptor : NSObject
+ (NSFontDescriptor *)fontDescriptorWithName:(NSString *)fontName size:(CGFloat)size;
+ (NSFontDescriptor *)fontDescriptorWithFontAttributes:(NSDictionary *)attributes;
@property (nonatomic, readonly, copy) NSString *postscriptName;
@property (nonatomic, readonly) CGFloat pointSize;
@property (nonatomic, readonly, copy) NSDictionary *fontAttributes;
@property (nonatomic, readonly) NSFontDescriptor *matchingFontDescriptor;
@property (nonatomic, readonly) uint32_t symbolicTraits;
- (NSFontDescriptor *)fontDescriptorByAddingAttributes:(NSDictionary *)attributes;
- (NSFontDescriptor *)fontDescriptorWithSize:(CGFloat)size;
@end

@interface NSFontManager : NSObject
@property (class, readonly, strong) NSFontManager *sharedFontManager;
@property (nonatomic, readonly, copy) NSArray<NSString *> *availableFonts;
@property (nonatomic, readonly, copy) NSArray<NSString *> *availableFontFamilies;
- (NSArray<NSString *> *)availableMembersOfFontFamily:(NSString *)family;
- (NSFontTraitMask)traitsOfFont:(id)font;
- (NSInteger)weightOfFont:(id)font;
- (BOOL)fontNamed:(NSString *)name hasTraits:(NSFontTraitMask)traits;
- (id)fontWithFamily:(NSString *)family traits:(NSFontTraitMask)traits weight:(NSInteger)weight size:(CGFloat)size;
- (id)convertFont:(id)font toHaveTrait:(NSFontTraitMask)trait;
@end
