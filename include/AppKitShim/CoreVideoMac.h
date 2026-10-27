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
CV_EXPORT CVReturn CVDisplayLinkStart(CVDisplayLinkRef displayLink);
CV_EXPORT CVReturn CVDisplayLinkStop(CVDisplayLinkRef displayLink);
CV_EXPORT Boolean CVDisplayLinkIsRunning(CVDisplayLinkRef displayLink);

CV_EXPORT CGDirectDisplayID CVDisplayLinkGetCurrentCGDisplay(CVDisplayLinkRef displayLink);
CV_EXPORT CVReturn CVDisplayLinkSetCurrentCGDisplay(CVDisplayLinkRef displayLink, CGDirectDisplayID displayID);
// OpenGL contexts don't exist here; accepted and ignored so callers keep working.
CV_EXPORT CVReturn CVDisplayLinkSetCurrentCGDisplayFromOpenGLContext(CVDisplayLinkRef displayLink, void *cglContext, void *cglPixelFormat);

CV_EXPORT CVReturn CVDisplayLinkGetCurrentTime(CVDisplayLinkRef displayLink, CVTimeStamp *outTime);
CV_EXPORT CVTime CVDisplayLinkGetNominalOutputVideoRefreshPeriod(CVDisplayLinkRef displayLink);
