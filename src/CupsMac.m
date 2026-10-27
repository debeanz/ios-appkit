// See CupsMac.h: no CUPS server on iOS; IPP messages, option lookup and media sizes are real.
#import "AKShimPrivate.h"
#import "AppKitShim/CupsMac.h"
#import <errno.h>

#pragma mark Last error

static __thread ipp_status_t gLastError = IPP_STATUS_OK;
static __thread const char *gLastErrorString = "successful-ok";

static void AKSetUnavailable(void) {
  gLastError = IPP_STATUS_ERROR_SERVICE_UNAVAILABLE;
  gLastErrorString = "No print service is available on this device";
}

ipp_status_t cupsLastError(void) { return gLastError; }
const char *cupsLastErrorString(void) { return gLastErrorString; }

#pragma mark Destinations (none on iOS)

int cupsGetDests2(http_t *http, cups_dest_t **dests) {
  if (dests) *dests = NULL;
  return 0;
}

// Enumeration completes successfully having found nothing; the callback is never called.
int cupsEnumDests(unsigned flags, int msec, int *cancel, cups_ptype_t type, cups_ptype_t mask, cups_dest_cb_t cb, void *user_data) {
  return 1;
}

cups_dest_t *cupsGetDest(const char *name, const char *instance, int num_dests, cups_dest_t *dests) {
  for (int i = 0; i < num_dests && dests; i++) {
    BOOL nameMatch = name ? (dests[i].name && strcmp(dests[i].name, name) == 0) : dests[i].is_default;
    BOOL instMatch = instance ? (dests[i].instance && strcmp(dests[i].instance, instance) == 0) : dests[i].instance == NULL;
    if (nameMatch && instMatch) return &dests[i];
  }
  return NULL;
}

cups_dest_t *cupsGetNamedDest(http_t *http, const char *name, const char *instance) {
  gLastError = IPP_STATUS_ERROR_NOT_FOUND;
  gLastErrorString = "The printer or class does not exist";
  return NULL;
}

int cupsCopyDest(cups_dest_t *dest, int num_dests, cups_dest_t **dests) { return num_dests; }
int cupsRemoveDest(const char *name, const char *instance, int num_dests, cups_dest_t **dests) { return num_dests; }

void cupsFreeDests(int num_dests, cups_dest_t *dests) {
  for (int i = 0; i < num_dests && dests; i++) {
    free(dests[i].name);
    free(dests[i].instance);
    for (int j = 0; j < dests[i].num_options; j++) { free(dests[i].options[j].name); free(dests[i].options[j].value); }
    free(dests[i].options);
  }
  free(dests);
}

cups_dinfo_t *cupsCopyDestInfo(http_t *http, cups_dest_t *dest) { AKSetUnavailable(); return NULL; }
void cupsFreeDestInfo(cups_dinfo_t *dinfo) {}
int cupsCheckDestSupported(http_t *http, cups_dest_t *dest, cups_dinfo_t *dinfo, const char *option, const char *value) { return 0; }
ipp_attribute_t *cupsFindDestDefault(http_t *http, cups_dest_t *dest, cups_dinfo_t *dinfo, const char *option) { return NULL; }
ipp_attribute_t *cupsFindDestSupported(http_t *http, cups_dest_t *dest, cups_dinfo_t *dinfo, const char *option) { return NULL; }
const char *cupsLocalizeDestValue(http_t *http, cups_dest_t *dest, cups_dinfo_t *dinfo, const char *option, const char *value) { return value; }

// Case-insensitive name match, as libcups does.
const char *cupsGetOption(const char *name, int num_options, cups_option_t *options) {
  if (!name || !options) return NULL;
  for (int i = 0; i < num_options; i++)
    if (options[i].name && strcasecmp(options[i].name, name) == 0) return options[i].value;
  return NULL;
}

int cupsMarkOptions(ppd_file_t *ppd, int num_options, cups_option_t *options) { return 0; }

#pragma mark Requests to the server (none on iOS)

ipp_t *cupsDoRequest(http_t *http, ipp_t *request, const char *resource) {
  ippDelete(request); // cupsDoRequest consumes the request, as in libcups
  AKSetUnavailable();
  return NULL;
}

http_status_t cupsSendRequest(http_t *http, ipp_t *request, const char *resource, size_t length) { AKSetUnavailable(); return HTTP_STATUS_ERROR; }
http_status_t cupsWriteRequestData(http_t *http, const char *buffer, size_t length) { return HTTP_STATUS_ERROR; }
ipp_t *cupsGetResponse(http_t *http, const char *resource) { AKSetUnavailable(); return NULL; }
int cupsCancelJob2(http_t *http, const char *name, int job_id, int purge) { AKSetUnavailable(); return 0; }

const char *cupsServer(void) { return "/private/var/run/cupsd"; }
const char *cupsUser(void) {
  static char user[256];
  if (!user[0]) strlcpy(user, NSUserName().UTF8String ?: "mobile", sizeof user);
  return user;
}
const char *cupsUserAgent(void) { return "CUPS/2.3 (iOS) IPP/2.0"; }
int ippPort(void) { return 631; }

const char *cupsGetPPD(const char *name) { AKSetUnavailable(); return NULL; }
http_status_t cupsGetPPD2(http_t *http, const char *name, ...) { AKSetUnavailable(); return HTTP_STATUS_NOT_FOUND; }

http_t *httpConnect2(const char *host, int port, void *addrlist, http_addr_family_t family, http_encryption_t encryption,
                     int blocking, int msec, int *cancel) { return NULL; }
http_t *httpConnectEncrypt(const char *host, int port, http_encryption_t encryption) { return NULL; }
void httpClose(http_t *http) {}
void httpBlocking(http_t *http, int b) {}
int httpError(http_t *http) { return ECONNREFUSED; }

#pragma mark IPP messages

@interface AKIPPAttr : NSObject
@property (nonatomic, copy) NSData *name;      // NUL-terminated UTF-8
@property (nonatomic) ipp_tag_t group, valueTag;
@property (nonatomic, strong) NSMutableArray *values; // NSData strings, NSNumber, NSArray ranges/resolutions, AKIPP
@end
@implementation AKIPPAttr
@end

@interface AKIPP : NSObject
@property (nonatomic, strong) NSMutableArray<AKIPPAttr *> *attrs;
@property (nonatomic) NSUInteger cursor;
@property (nonatomic) int op, majorVersion, minorVersion;
@property (nonatomic) ipp_status_t status;
@end
@implementation AKIPP
@end

static AKIPP *AKMsg(ipp_t *ipp) { return (__bridge AKIPP *)(void *)ipp; }
static AKIPPAttr *AKAttr(ipp_attribute_t *a) { return (__bridge AKIPPAttr *)(void *)a; }

static NSData *AKCString(const char *s) {
  size_t n = s ? strlen(s) : 0;
  NSMutableData *d = [NSMutableData dataWithLength:n + 1];
  if (n) memcpy(d.mutableBytes, s, n);
  return d;
}

ipp_t *ippNew(void) {
  AKIPP *m = [AKIPP new];
  m.attrs = [NSMutableArray array];
  m.majorVersion = 2;
  return (ipp_t *)CFBridgingRetain(m);
}

ipp_t *ippNewRequest(ipp_op_t op) {
  ipp_t *ipp = ippNew();
  AKMsg(ipp).op = op;
  ippAddString(ipp, IPP_TAG_OPERATION, IPP_TAG_CHARSET, "attributes-charset", NULL, "utf-8");
  ippAddString(ipp, IPP_TAG_OPERATION, IPP_TAG_LANGUAGE, "attributes-natural-language", NULL, "en");
  return ipp;
}

void ippDelete(ipp_t *ipp) { if (ipp) CFRelease((CFTypeRef)ipp); }

int ippSetVersion(ipp_t *ipp, int major, int minor) {
  if (!ipp) return 0;
  AKMsg(ipp).majorVersion = major;
  AKMsg(ipp).minorVersion = minor;
  return 1;
}

ipp_status_t ippGetStatusCode(ipp_t *ipp) { return ipp ? AKMsg(ipp).status : IPP_STATUS_ERROR_INTERNAL; }

static ipp_attribute_t *AKAdd(ipp_t *ipp, ipp_tag_t group, ipp_tag_t valueTag, const char *name, NSArray *values) {
  if (!ipp || !name) return NULL;
  AKIPPAttr *a = [AKIPPAttr new];
  a.name = AKCString(name);
  a.group = group;
  a.valueTag = valueTag;
  a.values = [values mutableCopy];
  [AKMsg(ipp).attrs addObject:a];
  return (__bridge ipp_attribute_t *)a; // owned by the message
}

ipp_attribute_t *ippAddString(ipp_t *ipp, ipp_tag_t group, ipp_tag_t tag, const char *name, const char *language, const char *value) {
  return AKAdd(ipp, group, tag, name, @[ AKCString(value) ]);
}

ipp_attribute_t *ippAddStrings(ipp_t *ipp, ipp_tag_t group, ipp_tag_t tag, const char *name, int n, const char *language,
                               const char *const *values) {
  NSMutableArray *vals = [NSMutableArray array];
  for (int i = 0; i < n; i++) [vals addObject:AKCString(values ? values[i] : NULL)];
  return AKAdd(ipp, group, tag, name, vals);
}

ipp_attribute_t *ippAddInteger(ipp_t *ipp, ipp_tag_t group, ipp_tag_t tag, const char *name, int value) {
  return AKAdd(ipp, group, tag, name, @[ @(value) ]);
}

ipp_attribute_t *ippAddBoolean(ipp_t *ipp, ipp_tag_t group, const char *name, char value) {
  return AKAdd(ipp, group, IPP_TAG_BOOLEAN, name, @[ @(value != 0) ]);
}

ipp_attribute_t *ippAddRange(ipp_t *ipp, ipp_tag_t group, const char *name, int lower, int upper) {
  return AKAdd(ipp, group, IPP_TAG_RANGE, name, @[ @[ @(lower), @(upper) ] ]);
}

ipp_attribute_t *ippAddCollection(ipp_t *ipp, ipp_tag_t group, const char *name, ipp_t *value) {
  return AKAdd(ipp, group, IPP_TAG_BEGIN_COLLECTION, name, value ? @[ AKMsg(value) ] : @[]);
}

ipp_attribute_t *ippAddCollections(ipp_t *ipp, ipp_tag_t group, const char *name, int n, const ipp_t **values) {
  NSMutableArray *vals = [NSMutableArray array];
  for (int i = 0; i < n; i++) if (values && values[i]) [vals addObject:AKMsg((ipp_t *)values[i])];
  return AKAdd(ipp, group, IPP_TAG_BEGIN_COLLECTION, name, vals);
}

ipp_attribute_t *ippCopyAttribute(ipp_t *dst, ipp_attribute_t *attr, int quickcopy) {
  AKIPPAttr *src = AKAttr(attr);
  if (!dst || !src) return NULL;
  ipp_attribute_t *copy = AKAdd(dst, src.group, src.valueTag, (const char *)src.name.bytes, src.values);
  return copy;
}

void ippDeleteAttribute(ipp_t *ipp, ipp_attribute_t *attr) {
  if (ipp && attr) [AKMsg(ipp).attrs removeObjectIdenticalTo:AKAttr(attr)];
}

ipp_attribute_t *ippFindAttribute(ipp_t *ipp, const char *name, ipp_tag_t type) {
  if (!ipp || !name) return NULL;
  AKIPP *m = AKMsg(ipp);
  for (NSUInteger i = 0; i < m.attrs.count; i++) {
    AKIPPAttr *a = m.attrs[i];
    if (strcmp((const char *)a.name.bytes, name) == 0 && (type == IPP_TAG_ZERO || a.valueTag == type)) {
      m.cursor = i + 1;
      return (__bridge ipp_attribute_t *)a;
    }
  }
  return NULL;
}

ipp_attribute_t *ippFirstAttribute(ipp_t *ipp) {
  if (!ipp || AKMsg(ipp).attrs.count == 0) return NULL;
  AKMsg(ipp).cursor = 1;
  return (__bridge ipp_attribute_t *)AKMsg(ipp).attrs[0];
}

ipp_attribute_t *ippNextAttribute(ipp_t *ipp) {
  if (!ipp) return NULL;
  AKIPP *m = AKMsg(ipp);
  if (m.cursor >= m.attrs.count) return NULL;
  return (__bridge ipp_attribute_t *)m.attrs[m.cursor++];
}

const char *ippGetName(ipp_attribute_t *attr) { return attr ? (const char *)AKAttr(attr).name.bytes : NULL; }
ipp_tag_t ippGetGroupTag(ipp_attribute_t *attr) { return attr ? AKAttr(attr).group : IPP_TAG_ZERO; }
int ippGetCount(ipp_attribute_t *attr) { return attr ? (int)AKAttr(attr).values.count : 0; }

static id AKValue(ipp_attribute_t *attr, int element) {
  if (!attr || element < 0 || element >= (int)AKAttr(attr).values.count) return nil;
  return AKAttr(attr).values[(NSUInteger)element];
}

const char *ippGetString(ipp_attribute_t *attr, int element, const char **language) {
  if (language) *language = NULL;
  id v = AKValue(attr, element);
  return [v isKindOfClass:NSData.class] ? (const char *)[v bytes] : NULL;
}

int ippGetInteger(ipp_attribute_t *attr, int element) {
  id v = AKValue(attr, element);
  return [v isKindOfClass:NSNumber.class] ? [v intValue] : 0;
}

int ippGetRange(ipp_attribute_t *attr, int element, int *upper) {
  id v = AKValue(attr, element);
  BOOL ok = [v isKindOfClass:NSArray.class] && [v count] >= 2;
  if (upper) *upper = ok ? [v[1] intValue] : 0;
  return ok ? [v[0] intValue] : 0;
}

int ippGetResolution(ipp_attribute_t *attr, int element, int *yres, ipp_res_t *units) {
  id v = AKValue(attr, element);
  BOOL ok = [v isKindOfClass:NSArray.class] && [v count] >= 3;
  if (yres) *yres = ok ? [v[1] intValue] : 0;
  if (units) *units = ok ? [v[2] intValue] : IPP_RES_PER_INCH;
  return ok ? [v[0] intValue] : 0;
}

ipp_t *ippGetCollection(ipp_attribute_t *attr, int element) {
  id v = AKValue(attr, element);
  return [v isKindOfClass:AKIPP.class] ? (__bridge ipp_t *)v : NULL;
}

int ippValidateAttributes(ipp_t *ipp) { return ipp != NULL; }

#pragma mark PPDs (none can be opened)

static __thread ppd_status_t gPPDError = PPD_OK;

ppd_file_t *ppdOpenFd(int fd) { gPPDError = fd < 0 ? PPD_FILE_OPEN_ERROR : PPD_NULL_FILE; return NULL; }
void ppdClose(ppd_file_t *ppd) {}
ppd_status_t ppdLastError(int *line) { if (line) *line = 0; return gPPDError; }
const char *ppdErrorString(ppd_status_t status) {
  switch (status) {
    case PPD_OK: return "OK";
    case PPD_FILE_OPEN_ERROR: return "Unable to open PPD file";
    case PPD_NULL_FILE: return "NULL PPD file pointer";
    default: return "Unknown";
  }
}
ppd_attr_t *ppdFindAttr(ppd_file_t *ppd, const char *name, const char *spec) { return NULL; }
ppd_option_t *ppdFindOption(ppd_file_t *ppd, const char *keyword) { return NULL; }
ppd_choice_t *ppdFindChoice(ppd_option_t *o, const char *option) { return NULL; }
ppd_choice_t *ppdFindMarkedChoice(ppd_file_t *ppd, const char *keyword) { return NULL; }
void ppdMarkDefaults(ppd_file_t *ppd) {}

#pragma mark PWG media sizes (hundredths of a millimetre)

static pwg_media_t gMedia[] = {
  { "na_letter_8.5x11in",       "na-letter", "Letter",    21590, 27940 },
  { "na_legal_8.5x14in",        "na-legal",  "Legal",     21590, 35560 },
  { "na_ledger_11x17in",        "tabloid",   "Tabloid",   27940, 43180 },
  { "na_executive_7.25x10.5in", "executive", "Executive", 18415, 26670 },
  { "iso_a3_297x420mm",         "iso-a3",    "A3",        29700, 42000 },
  { "iso_a4_210x297mm",         "iso-a4",    "A4",        21000, 29700 },
  { "iso_a5_148x210mm",         "iso-a5",    "A5",        14800, 21000 },
  { "iso_b5_176x250mm",         "iso-b5",    "ISOB5",     17600, 25000 },
};

// Known sizes match within a millimetre; anything else gets a custom PWG name, as libcups does.
pwg_media_t *pwgMediaForSize(int width, int length) {
  if (width <= 0 || length <= 0) return NULL;
  for (size_t i = 0; i < sizeof gMedia / sizeof gMedia[0]; i++)
    if (abs(gMedia[i].width - width) <= 100 && abs(gMedia[i].length - length) <= 100) return &gMedia[i];
  static __thread pwg_media_t custom;
  static __thread char name[64], ppd[64];
  snprintf(name, sizeof name, "custom_%.2fx%.2fmm_%.2fx%.2fmm", width / 100.0, length / 100.0, width / 100.0, length / 100.0);
  snprintf(ppd, sizeof ppd, "%.2fx%.2fmm", width / 100.0, length / 100.0);
  custom = (pwg_media_t){ name, NULL, ppd, width, length };
  return &custom;
}
