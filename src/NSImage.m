#import "AKShimPrivate.h"
#import "AppKitShim/NSGraphics.h"
#import "AppKitShim/NSColor.h"
#import <ImageIO/ImageIO.h>

@implementation NSImageRep
- (BOOL)drawInRect:(NSRect)rect { return NO; }

AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

@implementation NSBitmapImageRep {
  CGImageRef _cg;
  NSMutableData *_backing; // owns bitmapData when the client created one
  NSInteger _bytesPerRow, _bitsPerPixel, _samplesPerPixel;
}

- (instancetype)initWithCGImage:(CGImageRef)cg {
  if ((self = [super init]) && cg) {
    _cg = CGImageRetain(cg);
    self.pixelsWide = CGImageGetWidth(cg);
    self.pixelsHigh = CGImageGetHeight(cg);
    self.size = NSMakeSize(self.pixelsWide, self.pixelsHigh);
    _bitsPerPixel = CGImageGetBitsPerPixel(cg);
    _bytesPerRow = CGImageGetBytesPerRow(cg);
    _samplesPerPixel = _bitsPerPixel / MAX(1, (NSInteger)CGImageGetBitsPerComponent(cg));
  }
  return self;
}

- (instancetype)initWithData:(NSData *)data {
  CGImageSourceRef src = data ? CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL) : NULL;
  CGImageRef cg = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
  self = [self initWithCGImage:cg];
  if (cg) CGImageRelease(cg);
  if (src) CFRelease(src);
  return _cg ? self : nil;
}

- (instancetype)initWithBitmapDataPlanes:(unsigned char **)planes
                              pixelsWide:(NSInteger)width pixelsHigh:(NSInteger)height
                           bitsPerSample:(NSInteger)bps samplesPerPixel:(NSInteger)spp
                                hasAlpha:(BOOL)alpha isPlanar:(BOOL)isPlanar
                          colorSpaceName:(NSString *)colorSpaceName bitmapFormat:(NSBitmapFormat)format
                             bytesPerRow:(NSInteger)rowBytes bitsPerPixel:(NSInteger)pixelBits {
  if (!(self = [super init])) return nil;
  self.pixelsWide = width;
  self.pixelsHigh = height;
  self.size = NSMakeSize(width, height);
  _samplesPerPixel = spp;
  _bitsPerPixel = pixelBits ?: bps * spp;
  _bytesPerRow = rowBytes ?: (_bitsPerPixel * width + 7) / 8;
  _backing = [NSMutableData dataWithLength:_bytesPerRow * height];
  if (planes) *planes = _backing.mutableBytes; // the client draws into this, then reads CGImage
  return self;
}

- (void)dealloc { if (_cg) CGImageRelease(_cg); }

- (unsigned char *)bitmapData { return _backing.mutableBytes; }
- (NSInteger)bytesPerRow { return _bytesPerRow; }
- (NSInteger)bitsPerPixel { return _bitsPerPixel; }
- (NSInteger)samplesPerPixel { return _samplesPerPixel; }

// Build a CGImage from the client's pixel buffer the first time it is read.
- (CGImageRef)CGImage {
  if (_cg || !_backing) return _cg;
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGBitmapInfo info = kCGBitmapByteOrderDefault | kCGImageAlphaPremultipliedLast;
  CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)_backing);
  _cg = CGImageCreate(self.pixelsWide, self.pixelsHigh, 8, _bitsPerPixel, _bytesPerRow, cs, info,
                      provider, NULL, false, kCGRenderingIntentDefault);
  CGDataProviderRelease(provider);
  CGColorSpaceRelease(cs);
  return _cg;
}

+ (instancetype)imageRepWithData:(NSData *)data { return [[self alloc] initWithData:data]; }
+ (NSArray<NSImageRep *> *)imageRepsWithData:(NSData *)data {
  NSBitmapImageRep *rep = [self imageRepWithData:data];
  return rep ? @[ rep ] : @[];
}

- (NSColorSpace *)colorSpace { return NSColorSpace.sRGBColorSpace; }

- (BOOL)drawInRect:(NSRect)rect {
  CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
  if (!ctx || !self.CGImage) return NO;
  CGContextDrawImage(ctx, rect, self.CGImage);
  return YES;
}

// Draw the part `from` of the image (the whole image when it is empty) into `rect`, at
// opacity `fraction`. AppKit rects have a bottom-left origin; a CGImage crop is top-left.
- (BOOL)drawInRect:(NSRect)rect fromRect:(NSRect)from operation:(NSInteger)op
          fraction:(CGFloat)fraction respectFlipped:(BOOL)respectFlipped hints:(NSDictionary *)hints {
  CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
  CGImageRef image = self.CGImage;
  if (!ctx || !image) return NO;
  CGImageRef part = NULL;
  if (!NSIsEmptyRect(from)) {
    CGFloat h = CGImageGetHeight(image);
    part = CGImageCreateWithImageInRect(image, CGRectMake(from.origin.x, h - NSMaxY(from), from.size.width, from.size.height));
  }
  CGContextSaveGState(ctx);
  CGContextSetAlpha(ctx, fraction);
  CGContextDrawImage(ctx, rect, part ?: image);
  CGContextRestoreGState(ctx);
  if (part) CGImageRelease(part);
  return YES;
}

static CFStringRef AKUTTypeForFileType(NSBitmapImageFileType type) {
  switch (type) {
    case NSBitmapImageFileTypePNG: return CFSTR("public.png");
    case NSBitmapImageFileTypeJPEG: return CFSTR("public.jpeg");
    case NSBitmapImageFileTypeGIF: return CFSTR("com.compuserve.gif");
    case NSBitmapImageFileTypeBMP: return CFSTR("com.microsoft.bmp");
    default: return CFSTR("public.tiff");
  }
}

- (NSData *)representationUsingType:(NSBitmapImageFileType)type properties:(NSDictionary *)properties {
  if (!self.CGImage) return nil;
  NSMutableData *data = [NSMutableData data];
  CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, AKUTTypeForFileType(type), 1, NULL);
  if (!dest) return nil;
  CGImageDestinationAddImage(dest, self.CGImage, NULL);
  BOOL ok = CGImageDestinationFinalize(dest);
  CFRelease(dest);
  return ok ? data : nil;
}

@end

@implementation NSImage {
  NSMutableArray<NSImageRep *> *_reps;
  CGImageRef _focusImage; // the CGImage lockFocus draws into
  CGContextRef _focusContext;
}

- (instancetype)initWithSize:(NSSize)size {
  if ((self = [super init])) { _size = size; _reps = [NSMutableArray array]; }
  return self;
}

- (instancetype)initWithData:(NSData *)data {
  NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:data];
  if (!rep) return nil;
  self = [self initWithSize:rep.size];
  [self addRepresentation:rep];
  return self;
}

- (instancetype)initWithContentsOfFile:(NSString *)file {
  return [self initWithData:[NSData dataWithContentsOfFile:file]];
}

- (instancetype)initWithCGImage:(CGImageRef)cg size:(NSSize)size {
  if (!cg) return nil;
  NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cg];
  self = [self initWithSize:NSEqualSizes(size, NSZeroSize) ? rep.size : size];
  [self addRepresentation:rep];
  return self;
}

// Named images: look in the bundle, otherwise nil (the Mac's named system images don't exist).
+ (NSImage *)imageNamed:(NSImageName)name {
  UIImage *ui = [UIImage imageNamed:name];
  return ui.CGImage ? [[NSImage alloc] initWithCGImage:ui.CGImage size:ui.size] : nil;
}

+ (NSImage *)imageWithSize:(NSSize)size flipped:(BOOL)flipped drawingHandler:(BOOL (^)(NSRect))handler {
  NSImage *image = [[NSImage alloc] initWithSize:size];
  if (!handler) return image;
  UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
  fmt.opaque = NO;
  UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
  UIImage *ui = [r imageWithActions:^(UIGraphicsImageRendererContext *rc) {
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:rc.CGContext flipped:YES];
    [NSGraphicsContext setCurrentContext:gc];
    handler((NSRect){ .size = size });
    [NSGraphicsContext setCurrentContext:nil];
  }];
  if (ui.CGImage) [image addRepresentation:[[NSBitmapImageRep alloc] initWithCGImage:ui.CGImage]];
  return image;
}

- (id)copyWithZone:(NSZone *)zone {
  NSImage *copy = [[NSImage allocWithZone:zone] initWithSize:_size];
  copy->_name = [_name copy];
  [copy->_reps addObjectsFromArray:_reps];
  return copy;
}

- (BOOL)isValid { return _reps.count > 0 || _focusContext != NULL; }
- (NSArray<NSImageRep *> *)representations { return [_reps copy]; }
- (void)addRepresentation:(NSImageRep *)rep { if (rep) [_reps addObject:rep]; }

- (CGImageRef)CGImageForProposedRect:(NSRect *)rect context:(NSGraphicsContext *)context hints:(NSDictionary *)hints {
  for (NSImageRep *rep in _reps)
    if ([rep isKindOfClass:NSBitmapImageRep.class]) return [(NSBitmapImageRep *)rep CGImage];
  return NULL;
}

// Off-screen drawing: lockFocus makes a bitmap context current; unlockFocus turns what was
// drawn into a representation.
- (void)lockFocus {
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  _focusContext = CGBitmapContextCreate(NULL, MAX(1, (size_t)_size.width), MAX(1, (size_t)_size.height),
                                        8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(cs);
  [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:_focusContext flipped:NO]];
}

- (void)unlockFocus {
  if (!_focusContext) return;
  CGImageRef cg = CGBitmapContextCreateImage(_focusContext);
  if (cg) { [self addRepresentation:[[NSBitmapImageRep alloc] initWithCGImage:cg]]; CGImageRelease(cg); }
  [NSGraphicsContext setCurrentContext:nil];
  CGContextRelease(_focusContext);
  _focusContext = NULL;
}

- (void)drawInRect:(NSRect)rect {
  [self drawInRect:rect fromRect:NSZeroRect operation:0 fraction:1.0];
}

- (void)drawInRect:(NSRect)rect fromRect:(NSRect)fromRect operation:(NSInteger)op fraction:(CGFloat)delta {
  CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
  CGImageRef cg = [self CGImageForProposedRect:&rect context:nil hints:nil];
  if (!ctx || !cg) return;
  CGContextSaveGState(ctx);
  CGContextSetAlpha(ctx, delta);
  CGContextDrawImage(ctx, rect, cg);
  CGContextRestoreGState(ctx);
}

- (void)drawAtPoint:(NSPoint)point fromRect:(NSRect)fromRect operation:(NSInteger)op fraction:(CGFloat)delta {
  [self drawInRect:(NSRect){ point, _size } fromRect:fromRect operation:op fraction:delta];
}

- (NSData *)TIFFRepresentation {
  for (NSImageRep *rep in _reps)
    if ([rep isKindOfClass:NSBitmapImageRep.class])
      return [(NSBitmapImageRep *)rep representationUsingType:NSBitmapImageFileTypeTIFF properties:@{}];
  return nil;
}


AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end
