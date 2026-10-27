// macOS desktop OpenGL: the CGL context layer and the few immediate-mode calls the client
// imports. iOS has no desktop OpenGL (and GLES lacks immediate mode), so no pixel format is
// ever available: CGLChoosePixelFormat finds none, as it does on a Mac without a matching
// renderer, there is never a current context, and GL calls without a context do nothing.
// Callers fall back to Metal, which Chromium uses anyway.
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>

typedef struct _CGLPixelFormatObject *CGLPixelFormatObj;
typedef struct _CGLContextObject *CGLContextObj;
typedef int32_t CGLPixelFormatAttribute;
typedef int32_t CGLContextParameter;
typedef int32_t CGLContextEnable;
typedef int32_t CGLError;
typedef uint32_t AKGLenum;
typedef int32_t AKGLint;
typedef uint32_t AKGLuint;
typedef int32_t AKGLsizei;
typedef float AKGLfloat;

enum {
  kCGLNoError = 0, kCGLBadAttribute = 10000, kCGLBadProperty = 10001, kCGLBadPixelFormat = 10002,
  kCGLBadRendererInfo = 10003, kCGLBadContext = 10004, kCGLBadDrawable = 10005, kCGLBadDisplay = 10006,
  kCGLBadState = 10007, kCGLBadValue = 10008, kCGLBadMatch = 10009, kCGLBadEnumeration = 10010,
  kCGLBadOffScreen = 10011, kCGLBadFullScreen = 10012, kCGLBadWindow = 10013, kCGLBadAddress = 10014,
  kCGLBadCodeModule = 10015, kCGLBadAlloc = 10016, kCGLBadConnection = 10017,
};

extern CGLError CGLChoosePixelFormat(const CGLPixelFormatAttribute *attribs, CGLPixelFormatObj *pix, AKGLint *npix);
extern void CGLReleasePixelFormat(CGLPixelFormatObj pix);
extern const char *CGLErrorString(CGLError error);
extern CGLContextObj CGLGetCurrentContext(void);
extern CGLError CGLSetCurrentContext(CGLContextObj ctx);
extern CGLError CGLFlushDrawable(CGLContextObj ctx);
extern CGLError CGLGetParameter(CGLContextObj ctx, CGLContextParameter pname, AKGLint *params);
extern CGLError CGLIsEnabled(CGLContextObj ctx, CGLContextEnable pname, AKGLint *enable);
extern CGLError CGLGetSurface(CGLContextObj ctx, void **conn, void **win, void **srf);
extern CGLError CGLTexImageIOSurface2D(CGLContextObj ctx, AKGLenum target, AKGLenum internalFormat,
                                       AKGLsizei width, AKGLsizei height, AKGLenum format, AKGLenum type,
                                       IOSurfaceRef ioSurface, AKGLuint plane);

// Immediate-mode drawing and Apple's swap; with no current context they do nothing.
extern void glBegin(AKGLenum mode);
extern void glEnd(void);
extern void glVertex2f(AKGLfloat x, AKGLfloat y);
extern void glTexCoord2i(AKGLint s, AKGLint t);
extern void glSwapAPPLE(void);
