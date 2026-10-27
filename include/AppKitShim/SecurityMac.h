// macOS-only Security: the old SecKeychain C API, Authorization Services, keychain ACLs and
// identity search. iOS's own Security headers declare all of these as unavailable, so the
// shim can't reuse their names or types: each function below has an AK-prefixed C name and
// exports the real symbol (the one the client binds to) through an asm label, with plain C
// types in place of the macOS-only ones.
//
// The generic-password calls bridge to the iOS keychain (SecItem*), so Steam's saved login
// works. Authorization Services (privilege elevation) always denies; ACLs, identity search
// and trust settings have no iOS equivalent and report it.
#import <Foundation/Foundation.h>

enum {
  AKErrSecItemNotFound = -25300,
  AKErrSecUnimplemented = -4,
  AKErrSecParam = -50,
  AKErrAuthorizationSuccess = 0,
  AKErrAuthorizationDenied = -60005,
};

#define AK_SEC_EXPORT(name) __asm__("_" #name)

OSStatus AKSecKeychainAddGenericPassword(void *keychain, UInt32 serviceLen, const char *service, UInt32 accountLen,
                                         const char *account, UInt32 passwordLen, const void *password, void **itemRef)
    AK_SEC_EXPORT(SecKeychainAddGenericPassword);
OSStatus AKSecKeychainFindGenericPassword(const void *keychainOrArray, UInt32 serviceLen, const char *service,
                                          UInt32 accountLen, const char *account, UInt32 *passwordLen,
                                          void **passwordData, void **itemRef)
    AK_SEC_EXPORT(SecKeychainFindGenericPassword);
OSStatus AKSecKeychainItemDelete(void *itemRef) AK_SEC_EXPORT(SecKeychainItemDelete);
OSStatus AKSecKeychainItemFreeContent(void *attrList, void *data) AK_SEC_EXPORT(SecKeychainItemFreeContent);

OSStatus AKAuthorizationCreate(const void *rights, const void *environment, uint32_t flags, void **authorization)
    AK_SEC_EXPORT(AuthorizationCreate);
OSStatus AKAuthorizationFree(void *authorization, uint32_t flags) AK_SEC_EXPORT(AuthorizationFree);
OSStatus AKAuthorizationExecuteWithPrivileges(void *authorization, const char *pathToTool, uint32_t options,
                                              char *const *arguments, FILE **communicationsPipe)
    AK_SEC_EXPORT(AuthorizationExecuteWithPrivileges);
