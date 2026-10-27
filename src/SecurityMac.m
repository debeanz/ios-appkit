// See SecurityMac.h. The generic-password calls use the iOS keychain through SecItem*;
// everything macOS-specific (default keychains, ACLs, trust settings, privilege elevation)
// reports that it isn't available.
#import "AKShimPrivate.h"
#import "AppKitShim/SecurityMac.h"

#pragma mark Generic passwords over the iOS keychain

static NSString *AKStr(const char *bytes, UInt32 length) {
  return bytes ? [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding] : @"";
}

// An iOS keychain item has no SecKeychainItemRef; the shim hands back a reference that carries
// the service and account, so SecKeychainItemDelete can find the item again.
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

OSStatus SecKeychainAddGenericPassword(SecKeychainRef keychain, UInt32 serviceLen, const char *service,
                                       UInt32 accountLen, const char *account, UInt32 passwordLen,
                                       const void *password, SecKeychainItemRef *itemRef) {
  NSString *svc = AKStr(service, serviceLen), *acct = AKStr(account, accountLen);
  NSMutableDictionary *add = AKQuery(svc, acct);
  add[(__bridge id)kSecValueData] = [NSData dataWithBytes:password length:passwordLen];
  OSStatus status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
  if (status == noErr && itemRef) {
    AKKeychainItem *item = [AKKeychainItem new];
    item.service = svc;
    item.account = acct;
    *itemRef = (SecKeychainItemRef)CFBridgingRetain(item);
  }
  return status;
}

OSStatus SecKeychainFindGenericPassword(CFTypeRef keychainOrArray, UInt32 serviceLen, const char *service,
                                        UInt32 accountLen, const char *account, UInt32 *passwordLen,
                                        void **passwordData, SecKeychainItemRef *itemRef) {
  NSString *svc = AKStr(service, serviceLen), *acct = AKStr(account, accountLen);
  NSMutableDictionary *query = AKQuery(svc, acct);
  query[(__bridge id)kSecReturnData] = @YES;
  query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
  CFTypeRef result = NULL;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
  if (status != noErr) return status;
  NSData *data = (__bridge_transfer NSData *)result;
  // The caller frees the password buffer with SecKeychainItemFreeContent.
  if (passwordLen) *passwordLen = (UInt32)data.length;
  if (passwordData) { *passwordData = malloc(data.length); memcpy(*passwordData, data.bytes, data.length); }
  if (itemRef) {
    AKKeychainItem *item = [AKKeychainItem new];
    item.service = svc;
    item.account = acct;
    *itemRef = (SecKeychainItemRef)CFBridgingRetain(item);
  }
  return noErr;
}

OSStatus SecKeychainItemDelete(SecKeychainItemRef itemRef) {
  AKKeychainItem *item = itemRef ? (__bridge AKKeychainItem *)(void *)itemRef : nil;
  if (!item) return errSecParam;
  return SecItemDelete((__bridge CFDictionaryRef)AKQuery(item.service, item.account));
}

OSStatus SecKeychainItemFreeContent(SecKeychainAttributeList *attrList, void *data) {
  if (data) free(data);
  return noErr;
}

OSStatus SecKeychainItemCreateFromContent(SecItemClass itemClass, SecKeychainAttributeList *attrList, UInt32 length,
                                          const void *data, SecKeychainRef keychainRef, SecAccessRef initialAccess,
                                          SecKeychainItemRef *itemRef) {
  return errSecUnimplemented;
}

OSStatus SecKeychainItemCopyKeychain(SecKeychainItemRef itemRef, SecKeychainRef *keychainRef) {
  if (keychainRef) *keychainRef = NULL; // one implicit keychain on iOS
  return noErr;
}

#pragma mark Default keychain, status, interaction (one implicit keychain on iOS)

OSStatus SecKeychainCopyDefault(SecKeychainRef *keychain) {
  if (keychain) *keychain = NULL;
  return noErr; // NULL means "the default keychain" to the calls above
}

OSStatus SecKeychainGetStatus(SecKeychainRef keychain, SecKeychainStatus *status) {
  if (status) *status = 0x1 | 0x2 | 0x4; // unlocked, readable, writable
  return noErr;
}

static Boolean gInteractionAllowed = true;
OSStatus SecKeychainSetUserInteractionAllowed(Boolean state) { gInteractionAllowed = state; return noErr; }
OSStatus SecKeychainGetUserInteractionAllowed(Boolean *state) { if (state) *state = gInteractionAllowed; return noErr; }
OSStatus SecKeychainAddCallback(SecKeychainCallback callback, SecKeychainEventMask mask, void *context) { return noErr; }

#pragma mark ACLs, identity preferences, trust settings (not available on iOS)

OSStatus SecAccessCreate(CFStringRef descriptor, CFArrayRef trustedlist, SecAccessRef *accessRef) {
  if (accessRef) *accessRef = NULL;
  return errSecUnimplemented;
}
OSStatus SecAccessCopyACLList(SecAccessRef accessRef, CFArrayRef *aclList) { if (aclList) *aclList = NULL; return errSecUnimplemented; }
OSStatus SecACLCopyContents(SecACLRef acl, CFArrayRef *apps, CFStringRef *prompt, uint32_t *selector) { return errSecUnimplemented; }
OSStatus SecACLSetContents(SecACLRef acl, CFArrayRef apps, CFStringRef prompt, uint32_t selector) { return errSecUnimplemented; }

OSStatus SecIdentityCopyPreferred(CFStringRef name, CFArrayRef keyUsage, CFArrayRef validIssuers, SecIdentityRef *identity) {
  if (identity) *identity = NULL;
  return errSecItemNotFound;
}
OSStatus SecIdentitySearchCreate(CFTypeRef keychainOrArray, CSSM_KEYUSE keyUsage, SecIdentitySearchRef *searchRef) {
  if (searchRef) *searchRef = NULL;
  return errSecUnimplemented;
}
OSStatus SecIdentitySearchCopyNext(SecIdentitySearchRef searchRef, SecIdentityRef *identity) {
  if (identity) *identity = NULL;
  return errSecItemNotFound;
}
OSStatus SecTrustSettingsCopyCertificates(uint32_t domain, CFArrayRef *certArray) {
  if (certArray) *certArray = NULL;
  return errSecItemNotFound; // no per-user trust-settings store on iOS
}
OSStatus SecTrustSettingsCopyTrustSettings(SecCertificateRef certRef, uint32_t domain, CFArrayRef *trustSettings) {
  if (trustSettings) *trustSettings = NULL;
  return errSecItemNotFound;
}
OSStatus SecCodeCopyGuestWithAttributes(SecCodeRef host, CFDictionaryRef attributes, uint32_t flags, SecCodeRef *guest) {
  if (guest) *guest = NULL;
  return errSecUnimplemented;
}

#pragma mark Authorization Services (privilege elevation — always denied on iOS)

// An iOS app can't elevate privileges. AuthorizationCreate returns a token so code that holds
// one works, but no right is ever granted and nothing is run with privileges.
OSStatus AuthorizationCreate(const AuthorizationRights *rights, const AuthorizationEnvironment *environment,
                             AuthorizationFlags flags, AuthorizationRef *authorization) {
  if (authorization) *authorization = (AuthorizationRef)CFBridgingRetain([NSObject new]);
  return errAuthorizationSuccess;
}

OSStatus AuthorizationFree(AuthorizationRef authorization, AuthorizationFlags flags) {
  if (authorization) CFRelease((CFTypeRef)authorization);
  return errAuthorizationSuccess;
}

OSStatus AuthorizationCopyRights(AuthorizationRef authorization, const AuthorizationRights *rights,
                                 const AuthorizationEnvironment *environment, AuthorizationFlags flags,
                                 AuthorizationRights **authorizedRights) {
  if (authorizedRights) *authorizedRights = NULL;
  return errAuthorizationDenied; // no privileged right is ever granted
}

OSStatus AuthorizationExecuteWithPrivileges(AuthorizationRef authorization, const char *pathToTool,
                                            AuthorizationFlags options, char *const *arguments, FILE **communicationsPipe) {
  if (communicationsPipe) *communicationsPipe = NULL;
  return errAuthorizationDenied; // an iOS app cannot run a tool with elevated privileges
}

OSStatus AuthorizationRightGet(const char *rightName, CFDictionaryRef *rightDefinition) {
  if (rightDefinition) *rightDefinition = NULL;
  return errAuthorizationDenied;
}

OSStatus AuthorizationRightSet(AuthorizationRef authorization, const char *rightName, CFTypeRef rightDefinition,
                               CFStringRef descriptionKey, CFStringRef bundle, CFStringRef localeTableName) {
  return errAuthorizationDenied;
}
