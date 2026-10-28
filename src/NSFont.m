// NSFont for clients.
//
// On the Mac, NSFont is toll-free bridged to CTFontRef, and Chromium/CEF's font code relies
// on it (it casts NSFont * to CTFontRef). On iOS, UIFont has the same bridging, so the fonts
// this hands out are real UIFonts. The class is a UIFont subclass that adds the Mac-only
// class methods (+fontWithName:matrix:, +userFontOfSize:, ...).
//
// iOS already has an internal class named NSFont that isn't the Mac API — the Steam client's
// AppKit NSFont reference was resolving to it, and +fontWithName:matrix: aborted. So this
// class keeps its own runtime name (AKShimFont), and the Makefile exports it under the
// NSFont class symbols with a linker alias: a client that links AppKit's NSFont (routed to
// this shim, which the umbrella searches first) gets this class, and iOS keeps its own.
//
// The instances are UIFonts, so the Mac-only instance methods a client calls on them
// (-displayName, -maximumAdvancement, -set, -coveredCharacterSet) are added to UIFont — with
// class_addMethod, which only adds a method UIFont doesn't already have, so no iOS
// behaviour is overridden. The set of methods comes from the selectors the client's
// binaries reference (vgui2_s, CEF), less what UIFont already answers.
#import "AKShimPrivate.h"
#import <CoreText/CoreText.h>
#import <objc/runtime.h>

@interface AKShimFont : UIFont
@end

static CGFloat AKSizeOr(CGFloat size, CGFloat fallback) { return size > 0 ? size : fallback; }

@implementation AKShimFont

// The matrix is the font's 2D transform; for an upright font [0] and [3] are its point size
// (NSFontIdentityMatrix, all ones on the diagonal, means 1 pt — callers pass a scaled one).
+ (UIFont *)fontWithName:(NSString *)name matrix:(const CGFloat *)matrix {
  CGFloat size = matrix ? fabs(matrix[0] != 0 ? matrix[0] : matrix[3]) : 0;
  size = AKSizeOr(size, UIFont.systemFontSize);
  return [UIFont fontWithName:name size:size] ?: [UIFont systemFontOfSize:size];
}

// A client passes either the shim's NSFontDescriptor or the UIFontDescriptor a font returned.
+ (UIFont *)fontWithDescriptor:(id)descriptor size:(CGFloat)size {
  UIFontDescriptor *d = [descriptor isKindOfClass:UIFontDescriptor.class]
      ? descriptor
      : [UIFontDescriptor fontDescriptorWithFontAttributes:[descriptor fontAttributes] ?: @{}];
  return [UIFont fontWithDescriptor:d size:size];
}

// The Mac's role-specific system fonts; on iOS they are all the system font. Size 0 means
// "the default size for this role".
+ (UIFont *)userFontOfSize:(CGFloat)size           { return [UIFont systemFontOfSize:AKSizeOr(size, UIFont.systemFontSize)]; }
+ (UIFont *)messageFontOfSize:(CGFloat)size        { return [UIFont systemFontOfSize:AKSizeOr(size, UIFont.systemFontSize)]; }
+ (UIFont *)menuFontOfSize:(CGFloat)size           { return [UIFont systemFontOfSize:AKSizeOr(size, UIFont.systemFontSize)]; }
+ (UIFont *)menuBarFontOfSize:(CGFloat)size        { return [UIFont systemFontOfSize:AKSizeOr(size, UIFont.systemFontSize)]; }
+ (UIFont *)labelFontOfSize:(CGFloat)size          { return [UIFont systemFontOfSize:AKSizeOr(size, UIFont.labelFontSize)]; }
+ (UIFont *)controlContentFontOfSize:(CGFloat)size { return [UIFont systemFontOfSize:AKSizeOr(size, UIFont.systemFontSize)]; }
+ (UIFont *)titleBarFontOfSize:(CGFloat)size       { return [UIFont boldSystemFontOfSize:AKSizeOr(size, UIFont.systemFontSize)]; }
+ (UIFont *)paletteFontOfSize:(CGFloat)size        { return [UIFont systemFontOfSize:AKSizeOr(size, UIFont.smallSystemFontSize)]; }
+ (UIFont *)toolTipsFontOfSize:(CGFloat)size       { return [UIFont systemFontOfSize:AKSizeOr(size, UIFont.smallSystemFontSize)]; }
+ (UIFont *)userFixedPitchFontOfSize:(CGFloat)size {
  return [UIFont monospacedSystemFontOfSize:AKSizeOr(size, UIFont.systemFontSize) weight:UIFontWeightRegular];
}
+ (void)setUserFont:(UIFont *)font {}
+ (void)setUserFixedPitchFont:(UIFont *)font {}

@end

#pragma mark Mac instance methods, added to UIFont where missing

static NSString *AKFontDisplayName(UIFont *self, SEL _cmd) {
  return CFBridgingRelease(CTFontCopyDisplayName((__bridge CTFontRef)self));
}

// The widest advance of any glyph; Core Text's font bounding box is that width.
static CGSize AKFontMaximumAdvancement(UIFont *self, SEL _cmd) {
  return CGSizeMake(CTFontGetBoundingBox((__bridge CTFontRef)self).size.width, 0);
}

// Makes this the font for subsequent text drawing in the current graphics context. Text is
// drawn through attributed strings carrying their own font here, so there is nothing to set.
static void AKFontSet(UIFont *self, SEL _cmd) {}

static NSCharacterSet *AKFontCoveredCharacterSet(UIFont *self, SEL _cmd) {
  return CFBridgingRelease(CTFontCopyCharacterSet((__bridge CTFontRef)self));
}

__attribute__((constructor)) static void AKInstallFontMethods(void) {
  Class font = UIFont.class;
  class_addMethod(font, @selector(displayName), (IMP)AKFontDisplayName, "@@:");
  class_addMethod(font, @selector(maximumAdvancement), (IMP)AKFontMaximumAdvancement, "{CGSize=dd}@:");
  class_addMethod(font, @selector(set), (IMP)AKFontSet, "v@:");
  class_addMethod(font, @selector(coveredCharacterSet), (IMP)AKFontCoveredCharacterSet, "@@:");
}
