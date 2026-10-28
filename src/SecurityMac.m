// See SecurityMac.h. Every definition takes its exported symbol name from an asm label,
// because the iOS Security headers declare the real names as unavailable.
#import "AKShimPrivate.h"
#import "AppKitShim/SecurityMac.h"
#import <Security/Security.h>
#import <objc/runtime.h>

#define AK_SEC(ret, cname, sym, params) ret cname params __asm__("_" #sym); ret cname params

#pragma mark Generic passwords over the iOS keychain

static NSString *AKStr(const char *bytes, UInt32 length) {
  return bytes ? [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding] : @"";
}

// An iOS keychain item has no SecKeychainItemRef; the shim hands back a reference that carries
// the service and account, so the item can be deleted again.
@interface AKKeychainItem : NSObject
@property (nonatomic, copy) NSString *service;
@property (nonatomic, copy) NSString *account;
@end
@implementation AKKeychainItem
@end

static NSMutableDictionary *AKQuery(NSString *service, NSString *account) {
  NSMutableDictionary *q = [NSMutableDictionary dictionary];
  q[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
  if (service) q[(__bridge id)kSecAttrService] = service;
  if (account) q[(__bridge id)kSecAttrAccount] = account;
  return q;
}

static void *AKItemRef(NSString *service, NSString *account) {
  AKKeychainItem *item = [AKKeychainItem new];
  item.service = service;
  item.account = account;
  return (void *)CFBridgingRetain(item);
}

OSStatus AKSecKeychainAddGenericPassword(void *keychain, UInt32 serviceLen, const char *service, UInt32 accountLen,
                                         const char *account, UInt32 passwordLen, const void *password, void **itemRef) {
  NSString *svc = AKStr(service, serviceLen), *acct = AKStr(account, accountLen);
  NSMutableDictionary *add = AKQuery(svc, acct);
  add[(__bridge id)kSecValueData] = [NSData dataWithBytes:password length:passwordLen];
  OSStatus status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
  if (status == noErr && itemRef) *itemRef = AKItemRef(svc, acct);
  return status;
}

OSStatus AKSecKeychainFindGenericPassword(const void *keychainOrArray, UInt32 serviceLen, const char *service,
                                          UInt32 accountLen, const char *account, UInt32 *passwordLen,
                                          void **passwordData, void **itemRef) {
  NSString *svc = AKStr(service, serviceLen), *acct = AKStr(account, accountLen);
  NSMutableDictionary *query = AKQuery(svc, acct);
  query[(__bridge id)kSecReturnData] = @YES;
  query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
  CFTypeRef result = NULL;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
  if (status != noErr) return status;
  NSData *data = (__bridge_transfer NSData *)result;
  // The caller frees the buffer with SecKeychainItemFreeContent.
  if (passwordLen) *passwordLen = (UInt32)data.length;
  if (passwordData) { *passwordData = malloc(MAX(data.length, (NSUInteger)1)); memcpy(*passwordData, data.bytes, data.length); }
  if (itemRef) *itemRef = AKItemRef(svc, acct);
  return noErr;
}

OSStatus AKSecKeychainItemDelete(void *itemRef) {
  if (!itemRef) return AKErrSecParam;
  AKKeychainItem *item = (__bridge AKKeychainItem *)itemRef;
  return SecItemDelete((__bridge CFDictionaryRef)AKQuery(item.service, item.account));
}

OSStatus AKSecKeychainItemFreeContent(void *attrList, void *data) {
  if (data) free(data);
  return noErr;
}

AK_SEC(OSStatus, AKSecKeychainItemCreateFromContent, SecKeychainItemCreateFromContent,
       (uint32_t itemClass, void *attrList, UInt32 length, const void *data, void *keychain, void *access, void **itemRef)) {
  if (itemRef) *itemRef = NULL;
  return AKErrSecUnimplemented;
}

// One implicit keychain on iOS: NULL stands for it, as NULL means "default" to the calls above.
AK_SEC(OSStatus, AKSecKeychainItemCopyKeychain, SecKeychainItemCopyKeychain, (void *itemRef, void **keychain)) {
  if (keychain) *keychain = NULL;
  return noErr;
}
AK_SEC(OSStatus, AKSecKeychainCopyDefault, SecKeychainCopyDefault, (void **keychain)) {
  if (keychain) *keychain = NULL;
  return noErr;
}
AK_SEC(OSStatus, AKSecKeychainGetStatus, SecKeychainGetStatus, (void *keychain, UInt32 *status)) {
  if (status) *status = 0x1 | 0x2 | 0x4; // unlocked, readable, writable
  return noErr;
}

static Boolean gInteractionAllowed = true;
AK_SEC(OSStatus, AKSecKeychainSetUserInteractionAllowed, SecKeychainSetUserInteractionAllowed, (Boolean state)) {
  gInteractionAllowed = state;
  return noErr;
}
AK_SEC(OSStatus, AKSecKeychainGetUserInteractionAllowed, SecKeychainGetUserInteractionAllowed, (Boolean *state)) {
  if (state) *state = gInteractionAllowed;
  return noErr;
}
AK_SEC(OSStatus, AKSecKeychainAddCallback, SecKeychainAddCallback, (void *callback, uint32_t mask, void *context)) {
  return noErr; // keychain change events aren't observable on iOS
}

#pragma mark ACLs, identity preferences, trust settings (not available on iOS)

AK_SEC(OSStatus, AKSecAccessCreate, SecAccessCreate, (const void *descriptor, const void *trusted, void **access)) {
  if (access) *access = NULL;
  return AKErrSecUnimplemented;
}
AK_SEC(OSStatus, AKSecAccessCopyACLList, SecAccessCopyACLList, (void *access, const void **list)) {
  if (list) *list = NULL;
  return AKErrSecUnimplemented;
}
AK_SEC(OSStatus, AKSecACLCopyContents, SecACLCopyContents, (void *acl, const void **apps, const void **prompt, uint32_t *selector)) {
  return AKErrSecUnimplemented;
}
AK_SEC(OSStatus, AKSecACLSetContents, SecACLSetContents, (void *acl, const void *apps, const void *prompt, uint32_t selector)) {
  return AKErrSecUnimplemented;
}
AK_SEC(OSStatus, AKSecIdentityCopyPreferred, SecIdentityCopyPreferred, (const void *name, const void *usage, const void *issuers, void **identity)) {
  if (identity) *identity = NULL;
  return AKErrSecItemNotFound;
}
AK_SEC(OSStatus, AKSecIdentitySearchCreate, SecIdentitySearchCreate, (const void *keychains, uint32_t usage, void **search)) {
  if (search) *search = NULL;
  return AKErrSecUnimplemented;
}
AK_SEC(OSStatus, AKSecIdentitySearchCopyNext, SecIdentitySearchCopyNext, (void *search, void **identity)) {
  if (identity) *identity = NULL;
  return AKErrSecItemNotFound;
}
AK_SEC(OSStatus, AKSecTrustSettingsCopyCertificates, SecTrustSettingsCopyCertificates, (uint32_t domain, const void **certs)) {
  if (certs) *certs = NULL;
  return AKErrSecItemNotFound; // no per-user trust-settings store on iOS
}
AK_SEC(OSStatus, AKSecTrustSettingsCopyTrustSettings, SecTrustSettingsCopyTrustSettings, (const void *cert, uint32_t domain, const void **settings)) {
  if (settings) *settings = NULL;
  return AKErrSecItemNotFound;
}
AK_SEC(OSStatus, AKSecCodeCopyGuestWithAttributes, SecCodeCopyGuestWithAttributes, (void *host, const void *attrs, uint32_t flags, void **guest)) {
  if (guest) *guest = NULL;
  return AKErrSecUnimplemented;
}

#pragma mark Authorization Services (privilege elevation: always denied on iOS)

// An iOS app can't elevate privileges. A token can be created and freed so code holding one
// runs, but no right is ever granted and nothing is ever run with privileges.
OSStatus AKAuthorizationCreate(const void *rights, const void *environment, uint32_t flags, void **authorization) {
  if (authorization) *authorization = (void *)CFBridgingRetain([NSObject new]);
  return AKErrAuthorizationSuccess;
}

OSStatus AKAuthorizationFree(void *authorization, uint32_t flags) {
  if (authorization) CFRelease((CFTypeRef)authorization);
  return AKErrAuthorizationSuccess;
}

OSStatus AKAuthorizationExecuteWithPrivileges(void *authorization, const char *pathToTool, uint32_t options,
                                              char *const *arguments, FILE **communicationsPipe) {
  if (communicationsPipe) *communicationsPipe = NULL;
  return AKErrAuthorizationDenied;
}

AK_SEC(OSStatus, AKAuthorizationCopyRights, AuthorizationCopyRights,
       (void *authorization, const void *rights, const void *environment, uint32_t flags, void **authorizedRights)) {
  if (authorizedRights) *authorizedRights = NULL;
  return AKErrAuthorizationDenied;
}
AK_SEC(OSStatus, AKAuthorizationRightGet, AuthorizationRightGet, (const char *rightName, const void **definition)) {
  if (definition) *definition = NULL;
  return AKErrAuthorizationDenied;
}
AK_SEC(OSStatus, AKAuthorizationRightSet, AuthorizationRightSet,
       (void *authorization, const char *rightName, const void *definition, const void *description, const void *bundle, const void *table)) {
  return AKErrAuthorizationDenied;
}

#pragma mark Keychain search and certificate data

// Old Mac keychain searches (games look for root certificates or saved passwords this way).
// iOS has no file keychains to open or search, so: no such keychain, nothing found.
enum { AKErrSecNoSuchKeychain = -25294, AKErrSecItemNotFound = -25300, AKErrSecUnimplemented = -4 };

AK_SEC(OSStatus, AKSecKeychainOpen, SecKeychainOpen, (const char *pathName, void **keychain)) {
  if (keychain) *keychain = NULL;
  return AKErrSecNoSuchKeychain;
}
AK_SEC(OSStatus, AKSecKeychainSearchCreateFromAttributes, SecKeychainSearchCreateFromAttributes,
       (const void *keychainOrArray, uint32_t itemClass, const void *attrList, void **searchRef)) {
  if (searchRef) *searchRef = NULL;
  return AKErrSecItemNotFound;
}
AK_SEC(OSStatus, AKSecKeychainSearchCopyNext, SecKeychainSearchCopyNext, (void *searchRef, void **itemRef)) {
  if (itemRef) *itemRef = NULL;
  return AKErrSecItemNotFound;
}
AK_SEC(OSStatus, AKSecKeychainItemCopyContent, SecKeychainItemCopyContent,
       (void *itemRef, uint32_t *itemClass, void *attrList, UInt32 *length, void **outData)) {
  if (length) *length = 0;
  if (outData) *outData = NULL;
  return AKErrSecItemNotFound;
}
// The certificate's DER bytes as a CSSM_DATA {length, data}: iOS has SecCertificateCopyData.
typedef struct { size_t Length; uint8_t *Data; } AKCSSMData;
AK_SEC(OSStatus, AKSecCertificateGetData, SecCertificateGetData, (SecCertificateRef certificate, AKCSSMData *data)) {
  if (!certificate || !data) return AKErrSecUnimplemented;
  // CSSM_DATA points into the certificate; keep the bytes alive with the certificate.
  static const char kDataKey = 0;
  NSData *der = CFBridgingRelease(SecCertificateCopyData(certificate));
  objc_setAssociatedObject((__bridge id)certificate, &kDataKey, der, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  data->Length = der.length;
  data->Data = (uint8_t *)der.bytes;
  return 0;
}
