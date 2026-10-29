// CVDisplayLink — the macOS vsync clock (iOS CoreVideo has the types, not the link). The
// shim runs a CADisplayLink on a dedicated thread and calls the output callback there, as
// macOS does, with timestamps in the same units. For 120 Hz on ProMotion iPhones the host
// app's Info.plist needs CADisableMinimumFrameDurationOnPhone = YES.
#import <CoreVideo/CoreVideo.h>
#import "CoreGraphicsMac.h"

typedef struct __CVDisplayLink *CVDisplayLinkRef;

typedef CVReturn (*CVDisplayLinkOutputCallback)(CVDisplayLinkRef displayLink,
                                                const CVTimeStamp *inNow,
                                                const CVTimeStamp *inOutputTime,
                                                CVOptionFlags flagsIn,
                                                CVOptionFlags *flagsOut,
                                                void *displayLinkContext);

CV_EXPORT CVReturn CVDisplayLinkCreateWithActiveCGDisplays(CVDisplayLinkRef *displayLinkOut);
CV_EXPORT CVReturn CVDisplayLinkCreateWithCGDisplay(CGDirectDisplayID displayID, CVDisplayLinkRef *displayLinkOut);
CV_EXPORT CVDisplayLinkRef CVDisplayLinkRetain(CVDisplayLinkRef displayLink);
CV_EXPORT void CVDisplayLinkRelease(CVDisplayLinkRef displayLink);

CV_EXPORT CVReturn CVDisplayLinkSetOutputCallback(CVDisplayLinkRef displayLink, CVDisplayLinkOutputCallback callback, void *userInfo);
typedef CVReturn (^CVDisplayLinkOutputHandler)(CVDisplayLinkRef displayLink, const CVTimeStamp *inNow, const CVTimeStamp *inOutputTime,
                                               CVOptionFlags flagsIn, CVOptionFlags *flagsOut);
CV_EXPORT CVReturn CVDisplayLinkSetOutputHandler(CVDisplayLinkRef displayLink, CVDisplayLinkOutputHandler handler);
CV_EXPORT CVReturn CVDisplayLinkStart(CVDisplayLinkRef displayLink);
CV_EXPORT CVReturn CVDisplayLinkStop(CVDisplayLinkRef displayLink);
CV_EXPORT Boolean CVDisplayLinkIsRunning(CVDisplayLinkRef displayLink);

CV_EXPORT CGDirectDisplayID CVDisplayLinkGetCurrentCGDisplay(CVDisplayLinkRef displayLink);
CV_EXPORT CVReturn CVDisplayLinkSetCurrentCGDisplay(CVDisplayLinkRef displayLink, CGDirectDisplayID displayID);
// OpenGL contexts don't exist here; accepted and ignored so callers keep working.
CV_EXPORT CVReturn CVDisplayLinkSetCurrentCGDisplayFromOpenGLContext(CVDisplayLinkRef displayLink, void *cglContext, void *cglPixelFormat);

CV_EXPORT CVReturn CVDisplayLinkGetCurrentTime(CVDisplayLinkRef displayLink, CVTimeStamp *outTime);
CV_EXPORT CVTime CVDisplayLinkGetNominalOutputVideoRefreshPeriod(CVDisplayLinkRef displayLink);

// OpenGL texture caches (video frames as OpenGL textures): there's no path from CoreVideo into
// the OpenGL here, so creating one fails with kCVReturnUnsupported (Unity's player, which links
// them, plays video through Metal).
typedef struct __CVOpenGLTextureCache *CVOpenGLTextureCacheRef;
typedef CVImageBufferRef CVOpenGLTextureRef;
CV_EXPORT CVReturn CVOpenGLTextureCacheCreate(CFAllocatorRef allocator, CFDictionaryRef cacheAttributes, void *cglContext,
                                              void *cglPixelFormat, CFDictionaryRef textureAttributes, CVOpenGLTextureCacheRef *cacheOut);
CV_EXPORT CVReturn CVOpenGLTextureCacheCreateTextureFromImage(CFAllocatorRef allocator, CVOpenGLTextureCacheRef cache, CVImageBufferRef image,
                                                              CFDictionaryRef attributes, CVOpenGLTextureRef *textureOut);
CV_EXPORT void CVOpenGLTextureCacheFlush(CVOpenGLTextureCacheRef cache, CVOptionFlags options);
CV_EXPORT void CVOpenGLTextureCacheRelease(CVOpenGLTextureCacheRef cache);
CV_EXPORT uint32_t CVOpenGLTextureGetName(CVOpenGLTextureRef texture);
CV_EXPORT uint32_t CVOpenGLTextureGetTarget(CVOpenGLTextureRef texture);
