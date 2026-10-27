// NSGraphicsContext, NSColorSpace, NSAppearance, NSBezierPath, NSImage, NSBitmapImageRep:
// the AppKit drawing layer, mapped onto CoreGraphics, UIKit and ImageIO. These are what the
// client uses to rasterise icons, build cursors and images, and draw into contexts.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "NSGeometry.h"

@class NSColor;

#pragma mark NSGraphicsContext

@interface NSGraphicsContext : NSObject
// Wraps a CGContext. The current context is a thread-local stack, as in AppKit; UIKit's
// UIGraphicsGetCurrentContext feeds into the same stack while a UIKit draw is in progress.
@property (class, strong) NSGraphicsContext *currentContext;
+ (NSGraphicsContext *)graphicsContextWithCGContext:(CGContextRef)ctx flipped:(BOOL)flipped;
+ (void)saveGraphicsState;
+ (void)restoreGraphicsState;
@property (nonatomic, readonly) CGContextRef CGContext;
@property (nonatomic, readonly, getter=isFlipped) BOOL flipped;
@property (nonatomic, assign) BOOL shouldAntialias;
- (void)saveGraphicsState;
- (void)restoreGraphicsState;
- (void)flushGraphics;
@end

#pragma mark NSColorSpace

typedef NS_ENUM(NSInteger, NSColorSpaceModel) {
  NSColorSpaceModelUnknown = -1, NSColorSpaceModelGray = 0, NSColorSpaceModelRGB = 1,
  NSColorSpaceModelCMYK = 2, NSColorSpaceModelLAB = 3, NSColorSpaceModelDeviceN = 4,
  NSColorSpaceModelIndexed = 5, NSColorSpaceModelPatterned = 6,
};

@interface NSColorSpace : NSObject
- (instancetype)initWithCGColorSpace:(CGColorSpaceRef)cgColorSpace;
@property (class, readonly, strong) NSColorSpace *sRGBColorSpace;
@property (class, readonly, strong) NSColorSpace *deviceRGBColorSpace;
@property (class, readonly, strong) NSColorSpace *genericRGBColorSpace;
@property (class, readonly, strong) NSColorSpace *displayP3ColorSpace;
@property (class, readonly, strong) NSColorSpace *genericGrayColorSpace;
@property (nonatomic, readonly) CGColorSpaceRef CGColorSpace;
@property (nonatomic, readonly) NSColorSpaceModel colorSpaceModel;
@property (nonatomic, readonly) NSInteger numberOfColorComponents;
@property (nonatomic, readonly, copy) NSString *localizedName;
@end

#pragma mark NSAppearance

typedef NSString *NSAppearanceName;

@interface NSAppearance : NSObject
- (instancetype)initWithAppearanceNamed:(NSAppearanceName)name bundle:(NSBundle *)bundle;
+ (NSAppearance *)appearanceNamed:(NSAppearanceName)name;
@property (class, strong) NSAppearance *currentAppearance; // follows the trait collection
@property (nonatomic, readonly, copy) NSAppearanceName name;
// Returns whichever of `names` best matches; the shim resolves light vs. dark.
- (NSAppearanceName)bestMatchFromAppearancesWithNames:(NSArray<NSAppearanceName> *)names;
- (void)performAsCurrentDrawingAppearance:(void (^)(void))block;
@end

#pragma mark NSBezierPath

typedef NS_ENUM(NSUInteger, NSBezierPathElement) {
  NSBezierPathElementMoveTo, NSBezierPathElementLineTo, NSBezierPathElementCurveTo, NSBezierPathElementClosePath,
  NSBezierPathElementCubicCurveTo = NSBezierPathElementCurveTo, NSBezierPathElementQuadraticCurveTo = 4,
};
typedef NS_ENUM(NSUInteger, NSLineCapStyle) { NSLineCapStyleButt, NSLineCapStyleRound, NSLineCapStyleSquare };
typedef NS_ENUM(NSUInteger, NSLineJoinStyle) { NSLineJoinStyleMiter, NSLineJoinStyleRound, NSLineJoinStyleBevel };
typedef NS_ENUM(NSUInteger, NSWindingRule) { NSWindingRuleNonZero, NSWindingRuleEvenOdd };

@interface NSBezierPath : NSObject <NSCopying>
+ (NSBezierPath *)bezierPath;
+ (NSBezierPath *)bezierPathWithRect:(NSRect)rect;
+ (NSBezierPath *)bezierPathWithOvalInRect:(NSRect)rect;
+ (NSBezierPath *)bezierPathWithRoundedRect:(NSRect)rect xRadius:(CGFloat)xRadius yRadius:(CGFloat)yRadius;
+ (void)fillRect:(NSRect)rect;
+ (void)strokeRect:(NSRect)rect;

@property (nonatomic, assign) CGFloat lineWidth;
@property (nonatomic, assign) NSLineCapStyle lineCapStyle;
@property (nonatomic, assign) NSLineJoinStyle lineJoinStyle;
@property (nonatomic, assign) NSWindingRule windingRule;
@property (nonatomic, readonly) BOOL isEmpty;
@property (nonatomic, readonly) NSRect bounds;
@property (nonatomic, readonly) NSPoint currentPoint;
@property (nonatomic, readonly) CGPathRef CGPath;

- (void)moveToPoint:(NSPoint)point;
- (void)lineToPoint:(NSPoint)point;
- (void)curveToPoint:(NSPoint)endPoint controlPoint1:(NSPoint)c1 controlPoint2:(NSPoint)c2;
- (void)closePath;
- (void)removeAllPoints;
- (void)appendBezierPathWithRect:(NSRect)rect;
- (void)appendBezierPathWithOvalInRect:(NSRect)rect;
- (void)fill;
- (void)stroke;
- (void)addClip;
- (void)setClip;
- (BOOL)containsPoint:(NSPoint)point;
@end

#pragma mark NSImage and NSBitmapImageRep

typedef NSString *NSImageName;
typedef NS_ENUM(NSUInteger, NSBitmapImageFileType) {
  NSBitmapImageFileTypeTIFF, NSBitmapImageFileTypeBMP, NSBitmapImageFileTypeGIF,
  NSBitmapImageFileTypeJPEG, NSBitmapImageFileTypePNG, NSBitmapImageFileTypeJPEG2000,
};
typedef NS_ENUM(NSUInteger, NSBitmapFormat) {
  NSBitmapFormatAlphaFirst = 1 << 0, NSBitmapFormatAlphaNonpremultiplied = 1 << 1, NSBitmapFormatFloatingPointSamples = 1 << 2,
};

@interface NSImageRep : NSObject
@property (nonatomic, assign) NSInteger pixelsWide;
@property (nonatomic, assign) NSInteger pixelsHigh;
@property (nonatomic, assign) NSSize size;
- (BOOL)drawInRect:(NSRect)rect;
@end

@interface NSBitmapImageRep : NSImageRep
- (instancetype)initWithCGImage:(CGImageRef)cgImage;
- (instancetype)initWithData:(NSData *)data;
- (instancetype)initWithBitmapDataPlanes:(unsigned char **)planes
                              pixelsWide:(NSInteger)width
                              pixelsHigh:(NSInteger)height
                           bitsPerSample:(NSInteger)bps
                         samplesPerPixel:(NSInteger)spp
                                hasAlpha:(BOOL)alpha
                                isPlanar:(BOOL)isPlanar
                          colorSpaceName:(NSString *)colorSpaceName
                            bitmapFormat:(NSBitmapFormat)bitmapFormat
                             bytesPerRow:(NSInteger)rowBytes
                            bitsPerPixel:(NSInteger)pixelBits;
@property (nonatomic, readonly) unsigned char *bitmapData;
@property (nonatomic, readonly) NSInteger bytesPerRow;
@property (nonatomic, readonly) NSInteger bitsPerPixel;
@property (nonatomic, readonly) NSInteger samplesPerPixel;
@property (nonatomic, readonly) CGImageRef CGImage;
- (NSData *)representationUsingType:(NSBitmapImageFileType)type properties:(NSDictionary *)properties;
@end

@interface NSImage : NSObject <NSCopying>
- (instancetype)initWithSize:(NSSize)size;
- (instancetype)initWithData:(NSData *)data;
- (instancetype)initWithContentsOfFile:(NSString *)fileName;
- (instancetype)initWithCGImage:(CGImageRef)cgImage size:(NSSize)size;
+ (NSImage *)imageNamed:(NSImageName)name;
+ (NSImage *)imageWithSize:(NSSize)size flipped:(BOOL)flipped drawingHandler:(BOOL (^)(NSRect dstRect))handler;

@property (nonatomic, assign) NSSize size;
@property (nonatomic, readonly) BOOL isValid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSColor *backgroundColor;
@property (nonatomic, readonly, copy) NSArray<NSImageRep *> *representations;
- (void)addRepresentation:(NSImageRep *)imageRep;
- (void)lockFocus;
- (void)unlockFocus;
- (void)drawInRect:(NSRect)rect;
- (void)drawInRect:(NSRect)rect fromRect:(NSRect)fromRect operation:(NSInteger)op fraction:(CGFloat)delta;
- (void)drawAtPoint:(NSPoint)point fromRect:(NSRect)fromRect operation:(NSInteger)op fraction:(CGFloat)delta;
- (NSData *)TIFFRepresentation;
- (CGImageRef)CGImageForProposedRect:(NSRect *)proposedDestRect context:(NSGraphicsContext *)context hints:(NSDictionary *)hints;
@end
