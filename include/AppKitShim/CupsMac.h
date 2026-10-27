// libcups, the printing client macOS ships (Chromium prints through it). iOS has no CUPS
// server, so this behaves like a Mac with no printers set up: destination lookups find none,
// requests to the server report it unavailable, and PPDs can't be fetched. Building and
// reading IPP messages is real (it's in-memory data), as are option lookup and the PWG
// media-size table.
#import <Foundation/Foundation.h>

typedef struct cups_option_s { char *name; char *value; } cups_option_t;
typedef struct cups_dest_s { char *name; char *instance; int is_default; int num_options; cups_option_t *options; } cups_dest_t;
typedef struct _cups_dinfo_s cups_dinfo_t;
typedef struct _http_s http_t;
typedef struct _ipp_s ipp_t;
typedef struct _ipp_attribute_s ipp_attribute_t;
typedef struct ppd_file_s ppd_file_t;
typedef struct ppd_option_s ppd_option_t;
typedef struct ppd_choice_s ppd_choice_t;
typedef struct ppd_attr_s ppd_attr_t;
typedef struct pwg_media_s { const char *pwg; const char *legacy; const char *ppd; int width; int length; } pwg_media_t;

typedef int ipp_tag_t;
typedef int ipp_op_t;
typedef int ipp_status_t;
typedef int ipp_res_t;
typedef int http_status_t;
typedef int http_encryption_t;
typedef int http_addr_family_t;
typedef int ppd_status_t;
typedef unsigned cups_ptype_t;
typedef unsigned cups_dest_flags_t;
typedef int (*cups_dest_cb_t)(void *user_data, cups_dest_flags_t flags, cups_dest_t *dest);

enum {
  IPP_TAG_ZERO = 0x00, IPP_TAG_OPERATION = 0x01, IPP_TAG_JOB = 0x02, IPP_TAG_END = 0x03, IPP_TAG_PRINTER = 0x04,
  IPP_TAG_UNSUPPORTED_GROUP = 0x05, IPP_TAG_INTEGER = 0x21, IPP_TAG_BOOLEAN = 0x22, IPP_TAG_ENUM = 0x23,
  IPP_TAG_RESOLUTION = 0x32, IPP_TAG_RANGE = 0x33, IPP_TAG_BEGIN_COLLECTION = 0x34, IPP_TAG_TEXT = 0x41,
  IPP_TAG_NAME = 0x42, IPP_TAG_KEYWORD = 0x44, IPP_TAG_URI = 0x45, IPP_TAG_CHARSET = 0x47,
  IPP_TAG_LANGUAGE = 0x48, IPP_TAG_MIMETYPE = 0x49,
};
enum { IPP_STATUS_OK = 0x0000, IPP_STATUS_ERROR_NOT_FOUND = 0x0406, IPP_STATUS_ERROR_SERVICE_UNAVAILABLE = 0x0502,
       IPP_STATUS_ERROR_INTERNAL = 0x0500 };
enum { HTTP_STATUS_ERROR = -1, HTTP_STATUS_CONTINUE = 100, HTTP_STATUS_OK = 200, HTTP_STATUS_NOT_FOUND = 404 };
enum { PPD_OK = 0, PPD_FILE_OPEN_ERROR = 1, PPD_NULL_FILE = 2 };
enum { IPP_RES_PER_INCH = 3, IPP_RES_PER_CM = 4 };

// Destinations: none on iOS.
extern int cupsGetDests2(http_t *http, cups_dest_t **dests);
extern int cupsEnumDests(unsigned flags, int msec, int *cancel, cups_ptype_t type, cups_ptype_t mask, cups_dest_cb_t cb, void *user_data);
extern cups_dest_t *cupsGetDest(const char *name, const char *instance, int num_dests, cups_dest_t *dests);
extern cups_dest_t *cupsGetNamedDest(http_t *http, const char *name, const char *instance);
extern int cupsCopyDest(cups_dest_t *dest, int num_dests, cups_dest_t **dests);
extern int cupsRemoveDest(const char *name, const char *instance, int num_dests, cups_dest_t **dests);
extern void cupsFreeDests(int num_dests, cups_dest_t *dests);
extern cups_dinfo_t *cupsCopyDestInfo(http_t *http, cups_dest_t *dest);
extern void cupsFreeDestInfo(cups_dinfo_t *dinfo);
extern int cupsCheckDestSupported(http_t *http, cups_dest_t *dest, cups_dinfo_t *dinfo, const char *option, const char *value);
extern ipp_attribute_t *cupsFindDestDefault(http_t *http, cups_dest_t *dest, cups_dinfo_t *dinfo, const char *option);
extern ipp_attribute_t *cupsFindDestSupported(http_t *http, cups_dest_t *dest, cups_dinfo_t *dinfo, const char *option);
extern const char *cupsLocalizeDestValue(http_t *http, cups_dest_t *dest, cups_dinfo_t *dinfo, const char *option, const char *value);
extern const char *cupsGetOption(const char *name, int num_options, cups_option_t *options);
extern int cupsMarkOptions(ppd_file_t *ppd, int num_options, cups_option_t *options);

// Requests to the (absent) server.
extern ipp_t *cupsDoRequest(http_t *http, ipp_t *request, const char *resource);
extern http_status_t cupsSendRequest(http_t *http, ipp_t *request, const char *resource, size_t length);
extern http_status_t cupsWriteRequestData(http_t *http, const char *buffer, size_t length);
extern ipp_t *cupsGetResponse(http_t *http, const char *resource);
extern int cupsCancelJob2(http_t *http, const char *name, int job_id, int purge);
extern ipp_status_t cupsLastError(void);
extern const char *cupsLastErrorString(void);
extern const char *cupsServer(void);
extern const char *cupsUser(void);
extern const char *cupsUserAgent(void);
extern int ippPort(void);
extern const char *cupsGetPPD(const char *name);
extern http_status_t cupsGetPPD2(http_t *http, const char *name, ...);

extern http_t *httpConnect2(const char *host, int port, void *addrlist, http_addr_family_t family, http_encryption_t encryption,
                            int blocking, int msec, int *cancel);
extern http_t *httpConnectEncrypt(const char *host, int port, http_encryption_t encryption);
extern void httpClose(http_t *http);
extern void httpBlocking(http_t *http, int b);
extern int httpError(http_t *http);

// IPP messages (real, in memory).
extern ipp_t *ippNew(void);
extern ipp_t *ippNewRequest(ipp_op_t op);
extern void ippDelete(ipp_t *ipp);
extern int ippSetVersion(ipp_t *ipp, int major, int minor);
extern ipp_status_t ippGetStatusCode(ipp_t *ipp);
extern ipp_attribute_t *ippAddString(ipp_t *ipp, ipp_tag_t group, ipp_tag_t value_tag, const char *name, const char *language, const char *value);
extern ipp_attribute_t *ippAddStrings(ipp_t *ipp, ipp_tag_t group, ipp_tag_t value_tag, const char *name, int num_values,
                                      const char *language, const char *const *values);
extern ipp_attribute_t *ippAddInteger(ipp_t *ipp, ipp_tag_t group, ipp_tag_t value_tag, const char *name, int value);
extern ipp_attribute_t *ippAddBoolean(ipp_t *ipp, ipp_tag_t group, const char *name, char value);
extern ipp_attribute_t *ippAddRange(ipp_t *ipp, ipp_tag_t group, const char *name, int lower, int upper);
extern ipp_attribute_t *ippAddCollection(ipp_t *ipp, ipp_tag_t group, const char *name, ipp_t *value);
extern ipp_attribute_t *ippAddCollections(ipp_t *ipp, ipp_tag_t group, const char *name, int num_values, const ipp_t **values);
extern ipp_attribute_t *ippCopyAttribute(ipp_t *dst, ipp_attribute_t *attr, int quickcopy);
extern void ippDeleteAttribute(ipp_t *ipp, ipp_attribute_t *attr);
extern ipp_attribute_t *ippFindAttribute(ipp_t *ipp, const char *name, ipp_tag_t type);
extern ipp_attribute_t *ippFirstAttribute(ipp_t *ipp);
extern ipp_attribute_t *ippNextAttribute(ipp_t *ipp);
extern const char *ippGetName(ipp_attribute_t *attr);
extern ipp_tag_t ippGetGroupTag(ipp_attribute_t *attr);
extern int ippGetCount(ipp_attribute_t *attr);
extern const char *ippGetString(ipp_attribute_t *attr, int element, const char **language);
extern int ippGetInteger(ipp_attribute_t *attr, int element);
extern int ippGetRange(ipp_attribute_t *attr, int element, int *upper);
extern int ippGetResolution(ipp_attribute_t *attr, int element, int *yres, ipp_res_t *units);
extern ipp_t *ippGetCollection(ipp_attribute_t *attr, int element);
extern int ippValidateAttributes(ipp_t *ipp);

// PPDs: none can be fetched or opened.
extern ppd_file_t *ppdOpenFd(int fd);
extern void ppdClose(ppd_file_t *ppd);
extern ppd_status_t ppdLastError(int *line);
extern const char *ppdErrorString(ppd_status_t status);
extern ppd_attr_t *ppdFindAttr(ppd_file_t *ppd, const char *name, const char *spec);
extern ppd_option_t *ppdFindOption(ppd_file_t *ppd, const char *keyword);
extern ppd_choice_t *ppdFindChoice(ppd_option_t *o, const char *option);
extern ppd_choice_t *ppdFindMarkedChoice(ppd_file_t *ppd, const char *keyword);
extern void ppdMarkDefaults(ppd_file_t *ppd);

// PWG media names for a size in hundredths of a millimetre.
extern pwg_media_t *pwgMediaForSize(int width, int length);
