// macOS-only Security: the old SecKeychain C API, Authorization Services, keychain ACLs and
// identity search. iOS keeps the keychain itself (reached through SecItem*, which exists), so
// the generic-password calls bridge to it; Steam's saved login works. Authorization Services
// (privilege elevation) and the ACL/trust-settings APIs don't exist on iOS and report denial.
#import <Security/Security.h>
#import <CoreFoundation/CoreFoundation.h>
#import <MacTypes.h>

// macOS-only types the declarations below need (SecCode is the code-signing API, CSSM the old
// crypto layer); neither exists in the iOS Security headers.
typedef struct __SecCode *SecCodeRef;
typedef uint32_t CSSM_KEYUSE;

#pragma mark Keychain (bridged to the iOS keychain)

typedef struct OpaqueSecKeychainRef *SecKeychainRef;
typedef struct OpaqueSecKeychainItemRef *SecKeychainItemRef;
typedef struct OpaqueSecKeychainSearchRef *SecKeychainSearchRef;
typedef struct OpaqueSecAccessRef *SecAccessRef;
typedef struct OpaqueSecACLRef *SecACLRef;
typedef struct OpaqueSecIdentitySearchRef *SecIdentitySearchRef;
typedef UInt16 SecKeychainAttrType;
typedef UInt32 SecKeychainStatus;
typedef uint32_t SecKeychainEvent;
typedef uint32_t SecKeychainEventMask;

typedef struct SecKeychainAttribute { SecKeychainAttrType tag; UInt32 length; void *data; } SecKeychainAttribute;
typedef struct SecKeychainAttributeList { UInt32 count; SecKeychainAttribute *attr; } SecKeychainAttributeList;
typedef UInt32 SecItemClass;
typedef struct SecKeychainCallbackInfo SecKeychainCallbackInfo;
typedef OSStatus (*SecKeychainCallback)(SecKeychainEvent keychainEvent, SecKeychainCallbackInfo *info, void *context);

enum { errSecNoSuchKeychain = -25294, errSecItemNotFound = -25300, errSecDuplicateItem = -25299,
       errSecUnimplemented = -4, errSecAuthFailed = -25293, errSecParam = -50 };

extern OSStatus SecKeychainAddGenericPassword(SecKeychainRef keychain, UInt32 serviceNameLength, const char *serviceName,
                                              UInt32 accountNameLength, const char *accountName, UInt32 passwordLength,
                                              const void *passwordData, SecKeychainItemRef *itemRef);
extern OSStatus SecKeychainFindGenericPassword(CFTypeRef keychainOrArray, UInt32 serviceNameLength, const char *serviceName,
                                               UInt32 accountNameLength, const char *accountName, UInt32 *passwordLength,
                                               void **passwordData, SecKeychainItemRef *itemRef);
extern OSStatus SecKeychainItemDelete(SecKeychainItemRef itemRef);
extern OSStatus SecKeychainItemFreeContent(SecKeychainAttributeList *attrList, void *data);
extern OSStatus SecKeychainItemCopyKeychain(SecKeychainItemRef itemRef, SecKeychainRef *keychainRef);
extern OSStatus SecKeychainItemCreateFromContent(SecItemClass itemClass, SecKeychainAttributeList *attrList,
                                                 UInt32 length, const void *data, SecKeychainRef keychainRef,
                                                 SecAccessRef initialAccess, SecKeychainItemRef *itemRef);
extern OSStatus SecKeychainCopyDefault(SecKeychainRef *keychain);
extern OSStatus SecKeychainGetStatus(SecKeychainRef keychain, SecKeychainStatus *status);
extern OSStatus SecKeychainSetUserInteractionAllowed(Boolean state);
extern OSStatus SecKeychainGetUserInteractionAllowed(Boolean *state);
extern OSStatus SecKeychainAddCallback(SecKeychainCallback callbackFunction, SecKeychainEventMask eventMask, void *userContext);

#pragma mark Keychain access control (no per-item ACLs on iOS)

extern OSStatus SecAccessCreate(CFStringRef descriptor, CFArrayRef trustedlist, SecAccessRef *accessRef);
extern OSStatus SecAccessCopyACLList(SecAccessRef accessRef, CFArrayRef *aclList);
extern OSStatus SecACLCopyContents(SecACLRef acl, CFArrayRef *applicationList, CFStringRef *promptDescription, uint32_t *keychainPromptSelector);
extern OSStatus SecACLSetContents(SecACLRef acl, CFArrayRef applicationList, CFStringRef promptDescription, uint32_t keychainPromptSelector);

#pragma mark Identity preferences / trust settings (not available on iOS)

extern OSStatus SecIdentityCopyPreferred(CFStringRef name, CFArrayRef keyUsage, CFArrayRef validIssuers, SecIdentityRef *identity);
extern OSStatus SecIdentitySearchCreate(CFTypeRef keychainOrArray, CSSM_KEYUSE keyUsage, SecIdentitySearchRef *searchRef);
extern OSStatus SecIdentitySearchCopyNext(SecIdentitySearchRef searchRef, SecIdentityRef *identity);
extern OSStatus SecTrustSettingsCopyCertificates(uint32_t domain, CFArrayRef *certArray);
extern OSStatus SecTrustSettingsCopyTrustSettings(SecCertificateRef certRef, uint32_t domain, CFArrayRef *trustSettings);
extern OSStatus SecCodeCopyGuestWithAttributes(SecCodeRef host, CFDictionaryRef attributes, uint32_t flags, SecCodeRef *guest);

#pragma mark Authorization Services (privilege elevation — denied on iOS)

typedef struct AuthorizationOpaqueRef *AuthorizationRef;
typedef uint32_t AuthorizationFlags;
typedef struct AuthorizationItem { const char *name; size_t valueLength; void *value; uint32_t flags; } AuthorizationItem;
typedef struct AuthorizationItemSet { uint32_t count; AuthorizationItem *items; } AuthorizationItemSet;
typedef AuthorizationItemSet AuthorizationRights;
typedef AuthorizationItemSet AuthorizationEnvironment;

enum { errAuthorizationSuccess = 0, errAuthorizationDenied = -60005, errAuthorizationCanceled = -60006,
       errAuthorizationInternal = -60008 };

extern OSStatus AuthorizationCreate(const AuthorizationRights *rights, const AuthorizationEnvironment *environment,
                                    AuthorizationFlags flags, AuthorizationRef *authorization);
extern OSStatus AuthorizationFree(AuthorizationRef authorization, AuthorizationFlags flags);
extern OSStatus AuthorizationCopyRights(AuthorizationRef authorization, const AuthorizationRights *rights,
                                        const AuthorizationEnvironment *environment, AuthorizationFlags flags,
                                        AuthorizationRights **authorizedRights);
extern OSStatus AuthorizationExecuteWithPrivileges(AuthorizationRef authorization, const char *pathToTool,
                                                   AuthorizationFlags options, char *const *arguments, FILE **communicationsPipe);
extern OSStatus AuthorizationRightGet(const char *rightName, CFDictionaryRef *rightDefinition);
extern OSStatus AuthorizationRightSet(AuthorizationRef authorization, const char *rightName, CFTypeRef rightDefinition,
                                      CFStringRef descriptionKey, CFStringRef bundle, CFStringRef localeTableName);
