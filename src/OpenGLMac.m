// See OpenGLMac.h: no desktop GL renderer exists, so no pixel format matches and there is
// never a current context.
#import "AKShimPrivate.h"
#import "AppKitShim/OpenGLMac.h"

CGLError CGLChoosePixelFormat(const CGLPixelFormatAttribute *attribs, CGLPixelFormatObj *pix, AKGLint *npix) {
  if (!pix) return kCGLBadAddress;
  *pix = NULL; // no renderer matches; CGL reports that with a NULL format, not an error
  if (npix) *npix = 0;
  return kCGLNoError;
}

void CGLReleasePixelFormat(CGLPixelFormatObj pix) {}

const char *CGLErrorString(CGLError error) {
  switch (error) {
    case kCGLNoError:         return "no error";
    case kCGLBadAttribute:    return "invalid pixel format attribute";
    case kCGLBadProperty:     return "invalid renderer property";
    case kCGLBadPixelFormat:  return "invalid pixel format";
    case kCGLBadRendererInfo: return "invalid renderer info";
    case kCGLBadContext:      return "invalid context";
    case kCGLBadDrawable:     return "invalid drawable";
    case kCGLBadDisplay:      return "invalid graphics device";
    case kCGLBadState:        return "invalid context state";
    case kCGLBadValue:        return "invalid numerical value";
    case kCGLBadMatch:        return "invalid share context";
    case kCGLBadEnumeration:  return "invalid enumerant";
    case kCGLBadOffScreen:    return "invalid offscreen drawable";
    case kCGLBadFullScreen:   return "invalid fullscreen drawable";
    case kCGLBadWindow:       return "invalid window";
    case kCGLBadAddress:      return "invalid pointer";
    case kCGLBadCodeModule:   return "invalid code module";
    case kCGLBadAlloc:        return "invalid memory allocation";
    case kCGLBadConnection:   return "invalid CoreGraphics connection";
    default:                  return "unknown error";
  }
}

CGLContextObj CGLGetCurrentContext(void) { return NULL; }

// Clearing the current context always works; making one current can't, as none can exist.
CGLError CGLSetCurrentContext(CGLContextObj ctx) { return ctx ? kCGLBadContext : kCGLNoError; }

CGLError CGLFlushDrawable(CGLContextObj ctx) { return kCGLBadContext; }
CGLError CGLGetParameter(CGLContextObj ctx, CGLContextParameter pname, AKGLint *params) { return kCGLBadContext; }
CGLError CGLIsEnabled(CGLContextObj ctx, CGLContextEnable pname, AKGLint *enable) {
  if (enable) *enable = 0;
  return kCGLBadContext;
}
CGLError CGLGetSurface(CGLContextObj ctx, void **conn, void **win, void **srf) {
  if (conn) *conn = NULL;
  if (win) *win = NULL;
  if (srf) *srf = NULL;
  return kCGLBadContext;
}
CGLError CGLTexImageIOSurface2D(CGLContextObj ctx, AKGLenum target, AKGLenum internalFormat, AKGLsizei width,
                                AKGLsizei height, AKGLenum format, AKGLenum type, IOSurfaceRef ioSurface, AKGLuint plane) {
  return kCGLBadContext;
}

void glBegin(AKGLenum mode) {}
void glEnd(void) {}
void glVertex2f(AKGLfloat x, AKGLfloat y) {}
void glTexCoord2i(AKGLint s, AKGLint t) {}
void glSwapAPPLE(void) {}
