// See ApplicationServicesMac.h. The Carbon Pasteboard uses UIPasteboard; process and paper
// info is answered honestly; printing has no device and accessibility/zoom aren't reachable.
#import "AKShimPrivate.h"
#import "AppKitShim/ApplicationServicesMac.h"

#pragma mark Accessibility (not reachable from an iOS app)

AXUIElementRef AXUIElementCreateApplication(pid_t pid) {
  return (AXUIElementRef)CFBridgingRetain([NSString stringWithFormat:@"AXApp:%d", pid]);
}
AXError AXUIElementCopyActionNames(AXUIElementRef element, CFArrayRef *names) {
  if (names) *names = CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
  return kAXErrorSuccess;
}
AXError AXUIElementCopyAttributeNames(AXUIElementRef element, CFArrayRef *names) {
  if (names) *names = CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
  return kAXErrorSuccess;
}
AXError AXUIElementCopyParameterizedAttributeNames(AXUIElementRef element, CFArrayRef *names) {
  if (names) *names = CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
  return kAXErrorSuccess;
}
// There is no other process to inspect: reads find no value, writes and actions are refused
// the way they are when the user hasn't granted accessibility access.
AXError AXUIElementCopyAttributeValue(AXUIElementRef element, CFStringRef attribute, CFTypeRef *value) {
  if (value) *value = NULL;
  return element ? kAXErrorNoValue : kAXErrorInvalidUIElement;
}
AXError AXUIElementCopyParameterizedAttributeValue(AXUIElementRef element, CFStringRef attribute,
                                                   CFTypeRef parameter, CFTypeRef *result) {
  if (result) *result = NULL;
  return element ? kAXErrorNoValue : kAXErrorInvalidUIElement;
}
AXError AXUIElementSetAttributeValue(AXUIElementRef element, CFStringRef attribute, CFTypeRef value) { return kAXErrorAPIDisabled; }
AXError AXUIElementPerformAction(AXUIElementRef element, CFStringRef action) { return kAXErrorAPIDisabled; }
CFTypeID AXUIElementGetTypeID(void) { return CFStringGetTypeID(); } // elements are the strings above

AXError AXObserverCreateWithInfoCallback(pid_t application, AXObserverCallbackWithInfo callback, AXObserverRef *outObserver) {
  if (outObserver) *outObserver = NULL;
  return kAXErrorNotImplemented; // no cross-process accessibility on iOS
}
// No observer is ever created, so these only ever see one the caller didn't get from us.
AXError AXObserverAddNotification(AXObserverRef observer, AXUIElementRef element, CFStringRef notification, void *refcon) {
  return kAXErrorNotImplemented;
}
CFRunLoopSourceRef AXObserverGetRunLoopSource(AXObserverRef observer) { return NULL; }

// An AXValue wraps a CGPoint/CGSize/CGRect/CFRange/AXError. Stored as NSData of { type, bytes }
// so it is a real CFType, like the text markers below.
static size_t AKAXValueSize(AXValueType type) {
  switch (type) {
    case kAXValueCGPointType: return sizeof(CGPoint);
    case kAXValueCGSizeType:  return sizeof(CGSize);
    case kAXValueCGRectType:  return sizeof(CGRect);
    case kAXValueCFRangeType: return sizeof(CFRange);
    case kAXValueAXErrorType: return sizeof(AXError);
    default:                  return 0;
  }
}
AXValueRef AXValueCreate(AXValueType type, const void *valuePtr) {
  size_t size = AKAXValueSize(type);
  if (!size || !valuePtr) return NULL;
  NSMutableData *data = [NSMutableData dataWithBytes:&type length:sizeof type];
  [data appendBytes:valuePtr length:size];
  return CFBridgingRetain(data);
}
AXValueType AXValueGetType(AXValueRef value) {
  NSData *data = (__bridge NSData *)value;
  if (data.length < sizeof(AXValueType)) return kAXValueIllegalType;
  AXValueType type;
  memcpy(&type, data.bytes, sizeof type);
  return type;
}
Boolean AXValueGetValue(AXValueRef value, AXValueType type, void *valuePtr) {
  if (!value || !valuePtr || AXValueGetType(value) != type) return false;
  NSData *data = (__bridge NSData *)value;
  size_t size = AKAXValueSize(type);
  if (data.length < sizeof(AXValueType) + size) return false;
  memcpy(valuePtr, (const uint8_t *)data.bytes + sizeof(AXValueType), size);
  return true;
}
CFTypeID AXValueGetTypeID(void) { return CFDataGetTypeID(); }

// Text markers are opaque CF data; the shim keeps their bytes so a client that round-trips
// them works. They are NSData, which makes them valid CFTypes (retain/release/CFEqual).
AXTextMarkerRef AXTextMarkerCreate(CFAllocatorRef allocator, const UInt8 *bytes, CFIndex length) {
  return (AXTextMarkerRef)CFBridgingRetain([NSData dataWithBytes:bytes length:(NSUInteger)MAX(length, 0)]);
}
const UInt8 *AXTextMarkerGetBytePtr(AXTextMarkerRef marker) { return marker ? ((__bridge NSData *)marker).bytes : NULL; }
CFIndex AXTextMarkerGetLength(AXTextMarkerRef marker) { return marker ? (CFIndex)((__bridge NSData *)marker).length : 0; }
CFTypeID AXTextMarkerGetTypeID(void) { return CFDataGetTypeID(); }

AXTextMarkerRangeRef AXTextMarkerRangeCreate(CFAllocatorRef allocator, AXTextMarkerRef start, AXTextMarkerRef end) {
  NSArray *pair = @[ (__bridge id)start ?: [NSData data], (__bridge id)end ?: [NSData data] ];
  return (AXTextMarkerRangeRef)CFBridgingRetain(pair);
}
AXTextMarkerRef AXTextMarkerRangeCopyStartMarker(AXTextMarkerRangeRef range) {
  return range ? (AXTextMarkerRef)CFBridgingRetain(((__bridge NSArray *)range)[0]) : NULL;
}
AXTextMarkerRef AXTextMarkerRangeCopyEndMarker(AXTextMarkerRangeRef range) {
  return range ? (AXTextMarkerRef)CFBridgingRetain(((__bridge NSArray *)range)[1]) : NULL;
}
CFTypeID AXTextMarkerRangeGetTypeID(void) { return CFArrayGetTypeID(); }

#pragma mark Carbon Process Manager

// A ProcessSerialNumber is { UInt32 high; UInt32 low }; the current process is { 0, 2 }.
typedef struct { uint32_t high, low; } AKPSN;

OSErr AKGetCurrentProcess(void *psn) { if (psn) *(AKPSN *)psn = (AKPSN){ 0, AKkCurrentProcess }; return noErr; }
OSErr AKGetFrontProcess(void *psn) { if (psn) *(AKPSN *)psn = (AKPSN){ 0, AKkCurrentProcess }; return noErr; } // only this app is visible

OSErr AKGetProcessInformation(const void *psn, void *info) {
  // The caller's ProcessInfoRec starts with a length field it set; leave it and the rest alone
  // beyond stamping the process number, which is all the shim can meaningfully fill.
  if (!info) return AKParamErr;
  return noErr;
}

OSStatus AKGetProcessPID(const void *psn, pid_t *pid) {
  if (!pid) return AKParamErr;
  const AKPSN *p = psn;
  if (p && p->low != AKkCurrentProcess) return AKprocNotFound; // only the current process resolves
  *pid = getpid();
  return noErr;
}

void AKSetApplicationIsDaemon(Boolean isDaemon) {} // an iOS app can't become a daemon

#pragma mark QuickDraw cursor (no hardware cursor on iOS)

void InitCursor(void) {}
void HideCursor(void) {}
void ShowCursor(void) {}

#pragma mark Carbon Pasteboard (UIPasteboard)

// Carbon flavor types are UTIs, which is what UIPasteboard stores, so they pass straight
// through. The general pasteboard is the system clipboard, shared with NSPasteboard.
@interface AKCarbonPasteboard : NSObject
@property (nonatomic, strong) UIPasteboard *pb;
@property (nonatomic) NSInteger lastChangeCount;
@end
@implementation AKCarbonPasteboard
@end

static AKCarbonPasteboard *AKPB(PasteboardRef ref) { return (__bridge AKCarbonPasteboard *)(void *)ref; }

OSStatus PasteboardCreate(CFStringRef name, PasteboardRef *outPasteboard) {
  if (!outPasteboard) return AKParamErr;
  AKCarbonPasteboard *p = [AKCarbonPasteboard new];
  NSString *n = (__bridge NSString *)name;
  p.pb = (!n || [n isEqualToString:@"com.apple.pasteboard.clipboard"]) ? UIPasteboard.generalPasteboard
                                                                       : [UIPasteboard pasteboardWithName:n create:YES];
  p.lastChangeCount = p.pb.changeCount;
  *outPasteboard = (PasteboardRef)CFBridgingRetain(p);
  return noErr;
}

PasteboardSyncFlags PasteboardSynchronize(PasteboardRef pasteboard) {
  AKCarbonPasteboard *p = AKPB(pasteboard);
  if (!p) return 0;
  PasteboardSyncFlags flags = 0;
  if (p.pb.changeCount != p.lastChangeCount) { flags |= kPasteboardModified; p.lastChangeCount = p.pb.changeCount; }
  return flags;
}

OSStatus PasteboardClear(PasteboardRef pasteboard) {
  if (!AKPB(pasteboard)) return AKParamErr;
  AKPB(pasteboard).pb.items = @[];
  return noErr;
}

OSStatus PasteboardGetItemCount(PasteboardRef pasteboard, ItemCount *itemCount) {
  if (!AKPB(pasteboard) || !itemCount) return AKParamErr;
  *itemCount = (ItemCount)MAX(AKPB(pasteboard).pb.numberOfItems, 0);
  return noErr;
}

// Item IDs are 1-based indices, as Carbon code commonly treats them.
OSStatus PasteboardGetItemIdentifier(PasteboardRef pasteboard, UInt32 itemIndex, PasteboardItemID *itemID) {
  if (!AKPB(pasteboard) || !itemID || itemIndex < 1 || itemIndex > (UInt32)AKPB(pasteboard).pb.numberOfItems) return badPasteboardIndexErr;
  *itemID = (PasteboardItemID)(uintptr_t)itemIndex;
  return noErr;
}

OSStatus PasteboardPutItemFlavor(PasteboardRef pasteboard, PasteboardItemID itemID, CFStringRef flavorType,
                                 CFDataRef flavorData, PasteboardFlavorFlags flavorFlags) {
  AKCarbonPasteboard *p = AKPB(pasteboard);
  if (!p || !flavorType) return AKParamErr;
  NSUInteger index = (NSUInteger)(uintptr_t)itemID;
  index = index >= 1 ? index - 1 : 0;
  NSMutableArray *items = [p.pb.items mutableCopy] ?: [NSMutableArray array];
  while (items.count <= index) [items addObject:[NSMutableDictionary dictionary]];
  NSMutableDictionary *item = [items[index] mutableCopy];
  item[(__bridge NSString *)flavorType] = (__bridge NSData *)flavorData ?: [NSData data];
  items[index] = item;
  p.pb.items = items;
  return noErr;
}

OSStatus PasteboardCopyItemFlavorData(PasteboardRef pasteboard, PasteboardItemID itemID, CFStringRef flavorType,
                                      CFDataRef *flavorData) {
  AKCarbonPasteboard *p = AKPB(pasteboard);
  if (!p || !flavorType || !flavorData) return AKParamErr;
  NSUInteger index = (NSUInteger)(uintptr_t)itemID;
  index = index >= 1 ? index - 1 : 0;
  NSData *data = [p.pb dataForPasteboardType:(__bridge NSString *)flavorType inItemSet:[NSIndexSet indexSetWithIndex:index]].firstObject;
  if (!data) return badPasteboardFlavorErr;
  *flavorData = (CFDataRef)CFBridgingRetain(data);
  return noErr;
}

#pragma mark Carbon Printing Manager (no printer on iOS)

// Print settings and page formats are real data objects (so save/restore of a job's settings
// works); sessions have no printer, so starting a print job reports none is available.
@interface AKPMObject : NSObject
@property (nonatomic, strong) NSMutableDictionary *values;
@end
@implementation AKPMObject
- (instancetype)init { if ((self = [super init])) _values = [NSMutableDictionary dictionary]; return self; }
@end

static AKPMObject *AKPM(void *o) { return (__bridge AKPMObject *)o; }

OSStatus PMRelease(PMObject object) { if (object) CFRelease(object); return noErr; }

OSStatus PMCopyPageFormat(PMPageFormat source, PMPageFormat dest) {
  if (!source || !dest) return kPMInvalidParameter;
  AKPM(dest).values = [AKPM(source).values mutableCopy];
  return noErr;
}
OSStatus PMCopyPrintSettings(PMPrintSettings source, PMPrintSettings dest) {
  if (!source || !dest) return kPMInvalidParameter;
  AKPM(dest).values = [AKPM(source).values mutableCopy];
  return noErr;
}

// US Letter by default, like PMPrintInfo.
static void AKSetPaper(AKPMObject *fmt, double w, double h) {
  fmt.values[@"paperWidth"] = @(w);
  fmt.values[@"paperHeight"] = @(h);
}

OSStatus PMCreatePageFormatWithPMPaper(PMPageFormat *pageFormat, PMPaper paper) {
  if (!pageFormat) return kPMInvalidParameter;
  AKPMObject *fmt = [AKPMObject new];
  double w = 612, h = 792;
  if (paper) { PMPaperGetWidth(paper, &w); PMPaperGetHeight(paper, &h); }
  AKSetPaper(fmt, w, h);
  *pageFormat = (PMPageFormat)CFBridgingRetain(fmt);
  return noErr;
}

OSStatus PMGetOrientation(PMPageFormat pageFormat, PMOrientation *orientation) {
  if (!pageFormat || !orientation) return kPMInvalidParameter;
  NSNumber *o = AKPM(pageFormat).values[@"orientation"];
  *orientation = o ? (PMOrientation)o.unsignedShortValue : kPMPortrait;
  return noErr;
}
OSStatus PMSetOrientation(PMPageFormat pageFormat, PMOrientation orientation, Boolean lock) {
  if (!pageFormat) return kPMInvalidParameter;
  AKPM(pageFormat).values[@"orientation"] = @(orientation);
  return noErr;
}

static double AKPaperW(PMPageFormat f) { NSNumber *n = AKPM(f).values[@"paperWidth"]; return n ? n.doubleValue : 612; }
static double AKPaperH(PMPageFormat f) { NSNumber *n = AKPM(f).values[@"paperHeight"]; return n ? n.doubleValue : 792; }

OSStatus PMGetAdjustedPaperRect(PMPageFormat pageFormat, PMRect *paperRect) {
  if (!pageFormat || !paperRect) return kPMInvalidParameter;
  PMOrientation o = kPMPortrait;
  PMGetOrientation(pageFormat, &o);
  BOOL landscape = (o == kPMLandscape || o == kPMReverseLandscape);
  double w = AKPaperW(pageFormat), h = AKPaperH(pageFormat);
  *paperRect = (PMRect){ 0, 0, landscape ? w : h, landscape ? h : w };
  return noErr;
}

OSStatus PMGetAdjustedPageRect(PMPageFormat pageFormat, PMRect *pageRect) {
  if (!pageFormat || !pageRect) return kPMInvalidParameter;
  PMRect paper;
  PMGetAdjustedPaperRect(pageFormat, &paper);
  // AppKit's default margins (72pt sides, 90pt top/bottom).
  *pageRect = (PMRect){ paper.top + 90, paper.left + 72, paper.bottom - 90, paper.right - 72 };
  return noErr;
}

OSStatus PMGetPageFormatPaper(PMPageFormat pageFormat, PMPaper *paper) {
  if (!pageFormat || !paper) return kPMInvalidParameter;
  AKPMObject *p = [AKPMObject new];
  p.values[@"width"] = @(AKPaperW(pageFormat));
  p.values[@"height"] = @(AKPaperH(pageFormat));
  *paper = (PMPaper)CFBridgingRetain(p);
  return noErr;
}

CFDataRef PMPageFormatCreateDataRepresentation(PMPageFormat pageFormat) {
  if (!pageFormat) return NULL;
  return (CFDataRef)CFBridgingRetain([NSKeyedArchiver archivedDataWithRootObject:AKPM(pageFormat).values requiringSecureCoding:NO error:nil]);
}
OSStatus PMPageFormatCreateWithDataRepresentation(CFDataRef data, PMPageFormat *pageFormat) {
  if (!data || !pageFormat) return kPMInvalidParameter;
  AKPMObject *fmt = [AKPMObject new];
  id v = [NSKeyedUnarchiver unarchivedObjectOfClasses:[NSSet setWithObjects:NSDictionary.class, NSNumber.class, NSString.class, nil] fromData:(__bridge NSData *)data error:nil];
  if ([v isKindOfClass:NSDictionary.class]) fmt.values = [v mutableCopy];
  *pageFormat = (PMPageFormat)CFBridgingRetain(fmt);
  return noErr;
}

OSStatus PMPaperCreateCustom(PMPrinter printer, CFStringRef paperID, CFStringRef name, double width, double height,
                             const PMPaperMargins *margins, PMPaper *paper) {
  if (!paper) return kPMInvalidParameter;
  AKPMObject *p = [AKPMObject new];
  p.values[@"width"] = @(width);
  p.values[@"height"] = @(height);
  p.values[@"id"] = (__bridge NSString *)paperID ?: @"custom";
  p.values[@"name"] = (__bridge NSString *)name ?: @"Custom";
  if (margins) p.values[@"margins"] = @[ @(margins->top), @(margins->left), @(margins->bottom), @(margins->right) ];
  *paper = (PMPaper)CFBridgingRetain(p);
  return noErr;
}

OSStatus PMPaperGetWidth(PMPaper paper, double *width) {
  if (!paper || !width) return kPMInvalidParameter;
  NSNumber *n = AKPM(paper).values[@"width"];
  *width = n ? n.doubleValue : 612;
  return noErr;
}
OSStatus PMPaperGetHeight(PMPaper paper, double *height) {
  if (!paper || !height) return kPMInvalidParameter;
  NSNumber *n = AKPM(paper).values[@"height"];
  *height = n ? n.doubleValue : 792;
  return noErr;
}
OSStatus PMPaperGetMargins(PMPaper paper, PMPaperMargins *margins) {
  if (!paper || !margins) return kPMInvalidParameter;
  NSArray *m = AKPM(paper).values[@"margins"];
  *margins = m.count == 4 ? (PMPaperMargins){ [m[0] doubleValue], [m[1] doubleValue], [m[2] doubleValue], [m[3] doubleValue] }
                          : (PMPaperMargins){ 0, 0, 0, 0 };
  return noErr;
}
OSStatus PMPaperGetPPDPaperName(PMPaper paper, CFStringRef *paperName) {
  if (!paper || !paperName) return kPMInvalidParameter;
  *paperName = (CFStringRef)CFBridgingRetain(AKPM(paper).values[@"name"] ?: @"Letter");
  return noErr;
}

CFDataRef PMPrintSettingsCreateDataRepresentation(PMPrintSettings printSettings) {
  if (!printSettings) return NULL;
  return (CFDataRef)CFBridgingRetain([NSKeyedArchiver archivedDataWithRootObject:AKPM(printSettings).values requiringSecureCoding:NO error:nil]);
}
OSStatus PMPrintSettingsCreateWithDataRepresentation(CFDataRef data, PMPrintSettings *printSettings) {
  if (!data || !printSettings) return kPMInvalidParameter;
  AKPMObject *s = [AKPMObject new];
  id v = [NSKeyedUnarchiver unarchivedObjectOfClasses:[NSSet setWithObjects:NSDictionary.class, NSNumber.class, NSString.class, nil] fromData:(__bridge NSData *)data error:nil];
  if ([v isKindOfClass:NSDictionary.class]) s.values = [v mutableCopy];
  *printSettings = (PMPrintSettings)CFBridgingRetain(s);
  return noErr;
}
OSStatus PMPrintSettingsSetJobName(PMPrintSettings s, CFStringRef name) {
  if (!s) return kPMInvalidParameter;
  AKPM(s).values[@"jobName"] = (__bridge NSString *)name ?: @"";
  return noErr;
}
OSStatus PMPrintSettingsSetValue(PMPrintSettings s, CFStringRef key, CFTypeRef value, Boolean locked) {
  if (!s || !key) return kPMInvalidParameter;
  AKPM(s).values[(__bridge NSString *)key] = (__bridge id)value ?: [NSNull null];
  return noErr;
}
OSStatus PMSetCopies(PMPrintSettings s, UInt32 copies, Boolean lock) { if (!s) return kPMInvalidParameter; AKPM(s).values[@"copies"] = @(copies); return noErr; }
OSStatus PMSetCollate(PMPrintSettings s, Boolean collate) { if (!s) return kPMInvalidParameter; AKPM(s).values[@"collate"] = @(collate); return noErr; }
OSStatus PMSetDuplex(PMPrintSettings s, PMDuplexMode duplex) { if (!s) return kPMInvalidParameter; AKPM(s).values[@"duplex"] = @(duplex); return noErr; }

// No printer exists, so printer handles can't be made and sessions report no default printer.
OSStatus PMPrinterCreateFromPrinterID(CFStringRef printerID, PMPrinter *printer) { if (printer) *printer = NULL; return kPMInvalidPrinter; }
CFStringRef PMPrinterGetID(PMPrinter printer) { return printer ? (__bridge CFStringRef)AKPM(printer).values[@"id"] : NULL; }
OSStatus PMPrinterGetPaperList(PMPrinter printer, CFArrayRef *paperList) { if (paperList) *paperList = NULL; return kPMInvalidPrinter; }
OSStatus PMPrinterGetPrinterResolutionCount(PMPrinter printer, UInt32 *count) { if (count) *count = 0; return kPMInvalidPrinter; }
OSStatus PMPrinterGetIndexedPrinterResolution(PMPrinter printer, UInt32 index, PMResolution *resolution) { return kPMInvalidPrinter; }
OSStatus PMPrinterSetOutputResolution(PMPrinter printer, PMPrintSettings printSettings, const PMResolution *resolution) { return kPMInvalidPrinter; }

OSStatus PMSessionBeginCGDocumentNoDialog(PMPrintSession s, PMPrintSettings st, PMPageFormat f) { return kPMNoDefaultPrinter; }
OSStatus PMSessionBeginPageNoDialog(PMPrintSession s, PMPageFormat f, const PMRect *pageFrame) { return kPMNoDefaultPrinter; }
OSStatus PMSessionEndPageNoDialog(PMPrintSession s) { return kPMNoError; }
OSStatus PMSessionEndDocumentNoDialog(PMPrintSession s) { return kPMNoError; }
OSStatus PMSessionGetCGGraphicsContext(PMPrintSession s, CGContextRef *context) { if (context) *context = NULL; return kPMNoDefaultPrinter; }
OSStatus PMSessionGetCurrentPrinter(PMPrintSession s, PMPrinter *printer) { if (printer) *printer = NULL; return kPMNoDefaultPrinter; }
OSStatus PMSessionSetCurrentPMPrinter(PMPrintSession s, PMPrinter printer) { return kPMInvalidPrinter; }
OSStatus PMSessionGetDestinationType(PMPrintSession s, PMPrintSettings st, PMDestinationType *destType) {
  if (destType) *destType = kPMDestinationInvalid;
  return kPMNoError;
}
OSStatus PMSessionSetDestination(PMPrintSession s, PMPrintSettings st, PMDestinationType destType, CFStringRef destFormat, CFURLRef destLocation) { return kPMNoError; }
OSStatus PMSessionCopyDestinationFormat(PMPrintSession s, PMPrintSettings st, CFStringRef *destFormat) { if (destFormat) *destFormat = NULL; return kPMNoError; }
OSStatus PMSessionCopyDestinationLocation(PMPrintSession s, PMPrintSettings st, CFURLRef *destLocation) { if (destLocation) *destLocation = NULL; return kPMNoError; }
OSStatus PMSessionValidatePageFormat(PMPrintSession s, PMPageFormat f, Boolean *result) { if (result) *result = false; return kPMNoError; }
OSStatus PMSessionValidatePrintSettings(PMPrintSession s, PMPrintSettings st, Boolean *result) { if (result) *result = false; return kPMNoError; }

#pragma mark Universal Access zoom (not reachable from an iOS app)

Boolean UAZoomEnabled(void) { return false; }
OSStatus UAZoomChangeFocus(const CGRect *focusRect, const CGRect *highlightRect, int type) { return kAXErrorNotImplemented; }
