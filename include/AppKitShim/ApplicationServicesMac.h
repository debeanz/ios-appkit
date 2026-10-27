// macOS-only ApplicationServices: the accessibility C API, the Carbon Process Manager, the
// QuickDraw cursor calls, the Carbon Printing Manager and Pasteboard, and Universal Access
// zoom. The Carbon Pasteboard bridges to UIPasteboard (so it shares the system clipboard);
// process and paper info is answered honestly; printing has no device (as in the CUPS shim);
// accessibility and screen zoom aren't reachable from an iOS app and report so.
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <MacTypes.h>

#pragma mark Accessibility (AXUIElement / AXTextMarker)

typedef struct __AXUIElement *AXUIElementRef;
typedef struct __AXObserver *AXObserverRef;
typedef const struct __AXTextMarker *AXTextMarkerRef;
typedef const struct __AXTextMarkerRange *AXTextMarkerRangeRef;
typedef CFTypeRef AXValueRef;
typedef int32_t AXError;
typedef void (*AXObserverCallbackWithInfo)(AXObserverRef observer, AXUIElementRef element, CFStringRef notification,
                                           CFDictionaryRef info, void *refcon);

enum { kAXErrorSuccess = 0, kAXErrorFailure = -25200, kAXErrorNoValue = -25212,
       kAXErrorAPIDisabled = -25211, kAXErrorNotImplemented = -25208, kAXErrorInvalidUIElement = -25202 };

extern AXUIElementRef AXUIElementCreateApplication(pid_t pid) CF_RETURNS_RETAINED;
extern AXError AXUIElementCopyActionNames(AXUIElementRef element, CFArrayRef *names);
extern AXError AXUIElementCopyAttributeNames(AXUIElementRef element, CFArrayRef *names);
extern AXError AXUIElementCopyParameterizedAttributeNames(AXUIElementRef element, CFArrayRef *names);
extern AXError AXObserverCreateWithInfoCallback(pid_t application, AXObserverCallbackWithInfo callback, AXObserverRef *outObserver);

extern AXTextMarkerRef AXTextMarkerCreate(CFAllocatorRef allocator, const UInt8 *bytes, CFIndex length) CF_RETURNS_RETAINED;
extern const UInt8 *AXTextMarkerGetBytePtr(AXTextMarkerRef marker);
extern CFIndex AXTextMarkerGetLength(AXTextMarkerRef marker);
extern CFTypeID AXTextMarkerGetTypeID(void);
extern AXTextMarkerRangeRef AXTextMarkerRangeCreate(CFAllocatorRef allocator, AXTextMarkerRef start, AXTextMarkerRef end) CF_RETURNS_RETAINED;
extern AXTextMarkerRef AXTextMarkerRangeCopyStartMarker(AXTextMarkerRangeRef range) CF_RETURNS_RETAINED;
extern AXTextMarkerRef AXTextMarkerRangeCopyEndMarker(AXTextMarkerRangeRef range) CF_RETURNS_RETAINED;
extern CFTypeID AXTextMarkerRangeGetTypeID(void);

#pragma mark Carbon Process Manager

typedef struct ProcessSerialNumber { UInt32 highLongOfPSN; UInt32 lowLongOfPSN; } ProcessSerialNumber;
typedef struct ProcessInfoRec { UInt32 processInfoLength; void *processName; ProcessSerialNumber processNumber;
                                UInt32 processType; OSType processSignature; UInt32 processMode; void *processLocation;
                                UInt32 processSize; UInt32 processFreeMem; ProcessSerialNumber processLauncher;
                                SInt32 processLaunchDate; SInt32 processActiveTime; void *processAppRef; } ProcessInfoRec;

typedef struct PMPaperMargins { double top, left, bottom, right; } PMPaperMargins;
enum { kNoProcess = 0, kCurrentProcess = 2, procNotFound = -600 };

extern OSErr GetCurrentProcess(ProcessSerialNumber *psn);
extern OSErr GetFrontProcess(ProcessSerialNumber *psn);
extern OSErr GetProcessInformation(const ProcessSerialNumber *psn, ProcessInfoRec *info);
extern OSStatus GetProcessPID(const ProcessSerialNumber *psn, pid_t *pid);
extern void SetApplicationIsDaemon(Boolean isDaemon);

#pragma mark QuickDraw cursor (no hardware cursor on iOS)

extern void InitCursor(void);
extern void HideCursor(void);
extern void ShowCursor(void);

#pragma mark Carbon Pasteboard (bridged to UIPasteboard)

typedef struct OpaquePasteboardRef *PasteboardRef;
typedef const void *PasteboardItemID;
typedef UInt32 PasteboardFlavorFlags;
typedef UInt32 PasteboardSyncFlags;

enum { badPasteboardSyncErr = -25130, badPasteboardIndexErr = -25133, badPasteboardFlavorErr = -25131,
       kPasteboardModified = 1, kPasteboardClientIsOwner = 2 };

extern OSStatus PasteboardCreate(CFStringRef name, PasteboardRef *outPasteboard);
extern PasteboardSyncFlags PasteboardSynchronize(PasteboardRef pasteboard);
extern OSStatus PasteboardClear(PasteboardRef pasteboard);
extern OSStatus PasteboardGetItemCount(PasteboardRef pasteboard, ItemCount *itemCount);
extern OSStatus PasteboardGetItemIdentifier(PasteboardRef pasteboard, UInt32 itemIndex, PasteboardItemID *itemID);
extern OSStatus PasteboardPutItemFlavor(PasteboardRef pasteboard, PasteboardItemID itemID, CFStringRef flavorType,
                                        CFDataRef flavorData, PasteboardFlavorFlags flavorFlags);
extern OSStatus PasteboardCopyItemFlavorData(PasteboardRef pasteboard, PasteboardItemID itemID, CFStringRef flavorType,
                                             CFDataRef *flavorData);

#pragma mark Carbon Printing Manager (no printer on iOS)

typedef struct OpaquePMPrintSession *PMPrintSession;
typedef struct OpaquePMPrintSettings *PMPrintSettings;
typedef struct OpaquePMPageFormat *PMPageFormat;
typedef struct OpaquePMPaper *PMPaper;
typedef struct OpaquePMPrinter *PMPrinter;
typedef void *PMObject;
typedef UInt16 PMOrientation;
typedef UInt32 PMDestinationType;
typedef UInt32 PMTag;
typedef UInt32 PMDuplexMode;
typedef struct PMRect { double top, left, bottom, right; } PMRect;
typedef struct PMResolution { double hRes, vRes; } PMResolution;

enum { kPMPortrait = 1, kPMLandscape = 2, kPMReversePortrait = 3, kPMReverseLandscape = 4 };
enum { kPMDestinationInvalid = 0, kPMDestinationPrinter = 1, kPMDestinationFile = 2, kPMDestinationPreview = 5 };
enum { kPMDuplexNone = 0x0001, kPMDuplexNoTumble = 0x0002, kPMDuplexTumble = 0x0003 };
enum { kPMNoError = 0, kPMGeneralError = -30870, kPMInvalidPrinter = -30872, kPMNoDefaultPrinter = -30873,
       kPMNotImplemented = -30875, kPMInvalidParameter = -50 };

extern OSStatus PMRelease(PMObject object);
extern OSStatus PMCopyPageFormat(PMPageFormat source, PMPageFormat dest);
extern OSStatus PMCopyPrintSettings(PMPrintSettings source, PMPrintSettings dest);
extern OSStatus PMCreatePageFormatWithPMPaper(PMPageFormat *pageFormat, PMPaper paper);
extern OSStatus PMGetOrientation(PMPageFormat pageFormat, PMOrientation *orientation);
extern OSStatus PMSetOrientation(PMPageFormat pageFormat, PMOrientation orientation, Boolean lock);
extern OSStatus PMGetAdjustedPageRect(PMPageFormat pageFormat, PMRect *pageRect);
extern OSStatus PMGetAdjustedPaperRect(PMPageFormat pageFormat, PMRect *paperRect);
extern OSStatus PMGetPageFormatPaper(PMPageFormat pageFormat, PMPaper *paper);
extern CFDataRef PMPageFormatCreateDataRepresentation(PMPageFormat pageFormat) CF_RETURNS_RETAINED;
extern OSStatus PMPageFormatCreateWithDataRepresentation(CFDataRef data, PMPageFormat *pageFormat);
extern OSStatus PMPaperCreateCustom(PMPrinter printer, CFStringRef id, CFStringRef name, double width, double height,
                                    const PMPaperMargins *margins, PMPaper *paper);
extern OSStatus PMPaperGetWidth(PMPaper paper, double *paperWidth);
extern OSStatus PMPaperGetHeight(PMPaper paper, double *paperHeight);
extern OSStatus PMPaperGetMargins(PMPaper paper, PMPaperMargins *paperMargins);
extern OSStatus PMPaperGetPPDPaperName(PMPaper paper, CFStringRef *paperName);
extern CFDataRef PMPrintSettingsCreateDataRepresentation(PMPrintSettings printSettings) CF_RETURNS_RETAINED;
extern OSStatus PMPrintSettingsCreateWithDataRepresentation(CFDataRef data, PMPrintSettings *printSettings);
extern OSStatus PMPrintSettingsSetJobName(PMPrintSettings printSettings, CFStringRef name);
extern OSStatus PMPrintSettingsSetValue(PMPrintSettings printSettings, CFStringRef key, CFTypeRef value, Boolean locked);
extern OSStatus PMSetCopies(PMPrintSettings printSettings, UInt32 copies, Boolean lock);
extern OSStatus PMSetCollate(PMPrintSettings printSettings, Boolean collate);
extern OSStatus PMSetDuplex(PMPrintSettings printSettings, PMDuplexMode duplexSetting);
extern OSStatus PMPrinterCreateFromPrinterID(CFStringRef printerID, PMPrinter *printer);
extern CFStringRef PMPrinterGetID(PMPrinter printer);
extern OSStatus PMPrinterGetPaperList(PMPrinter printer, CFArrayRef *paperList);
extern OSStatus PMPrinterGetPrinterResolutionCount(PMPrinter printer, UInt32 *count);
extern OSStatus PMPrinterGetIndexedPrinterResolution(PMPrinter printer, UInt32 index, PMResolution *resolution);
extern OSStatus PMPrinterSetOutputResolution(PMPrinter printer, PMPrintSettings printSettings, const PMResolution *resolution);
extern OSStatus PMSessionBeginCGDocumentNoDialog(PMPrintSession printSession, PMPrintSettings printSettings, PMPageFormat pageFormat);
extern OSStatus PMSessionBeginPageNoDialog(PMPrintSession printSession, PMPageFormat pageFormat, const PMRect *pageFrame);
extern OSStatus PMSessionEndPageNoDialog(PMPrintSession printSession);
extern OSStatus PMSessionEndDocumentNoDialog(PMPrintSession printSession);
extern OSStatus PMSessionGetCGGraphicsContext(PMPrintSession printSession, CGContextRef *context);
extern OSStatus PMSessionGetCurrentPrinter(PMPrintSession printSession, PMPrinter *currentPrinter);
extern OSStatus PMSessionSetCurrentPMPrinter(PMPrintSession session, PMPrinter printer);
extern OSStatus PMSessionGetDestinationType(PMPrintSession printSession, PMPrintSettings printSettings, PMDestinationType *destType);
extern OSStatus PMSessionSetDestination(PMPrintSession printSession, PMPrintSettings printSettings, PMDestinationType destType,
                                        CFStringRef destFormat, CFURLRef destLocation);
extern OSStatus PMSessionCopyDestinationFormat(PMPrintSession printSession, PMPrintSettings printSettings, CFStringRef *destFormat);
extern OSStatus PMSessionCopyDestinationLocation(PMPrintSession printSession, PMPrintSettings printSettings, CFURLRef *destLocation);
extern OSStatus PMSessionValidatePageFormat(PMPrintSession printSession, PMPageFormat pageFormat, Boolean *result);
extern OSStatus PMSessionValidatePrintSettings(PMPrintSession printSession, PMPrintSettings printSettings, Boolean *result);

#pragma mark Universal Access zoom (not reachable from an iOS app)

extern Boolean UAZoomEnabled(void);
extern OSStatus UAZoomChangeFocus(const CGRect *focusRect, const CGRect *highlightRect, int type);

