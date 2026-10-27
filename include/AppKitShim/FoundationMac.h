// macOS-only Foundation classes: user notifications (bridged to iOS UserNotifications) and
// the AppleScript/Apple Event support classes. iOS has no AppleScript, so those are inert
// models that let code referencing them link and run without doing anything.
#import <Foundation/Foundation.h>

#pragma mark User notifications

typedef NS_ENUM(NSInteger, NSUserNotificationActivationType) {
  NSUserNotificationActivationTypeNone = 0,
  NSUserNotificationActivationTypeContentsClicked = 1,
  NSUserNotificationActivationTypeActionButtonClicked = 2,
  NSUserNotificationActivationTypeReplied = 3,
  NSUserNotificationActivationTypeAdditionalActionClicked = 4,
};

@interface NSUserNotification : NSObject <NSCopying>
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *informativeText;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSDictionary *userInfo;
@property (nonatomic, copy) NSString *soundName;
@property (nonatomic, strong) id contentImage;
@property (nonatomic) BOOL hasActionButton;
@property (nonatomic, copy) NSString *actionButtonTitle;
@property (nonatomic, copy) NSString *otherButtonTitle;
@property (nonatomic, copy) NSDate *deliveryDate;
@property (nonatomic, readonly) NSUserNotificationActivationType activationType;
@property (nonatomic, readonly, getter=isPresented) BOOL presented;
@property (nonatomic, readonly, copy) NSDate *actualDeliveryDate;
@end

extern NSString *const NSUserNotificationDefaultSoundName;

@class NSUserNotificationCenter;
@protocol NSUserNotificationCenterDelegate <NSObject>
@optional
- (void)userNotificationCenter:(NSUserNotificationCenter *)center didDeliverNotification:(NSUserNotification *)notification;
- (void)userNotificationCenter:(NSUserNotificationCenter *)center didActivateNotification:(NSUserNotification *)notification;
- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center shouldPresentNotification:(NSUserNotification *)notification;
@end

// Delivers through UNUserNotificationCenter, requesting permission the first time.
@interface NSUserNotificationCenter : NSObject
@property (class, readonly, strong) NSUserNotificationCenter *defaultUserNotificationCenter;
@property (nonatomic, weak) id<NSUserNotificationCenterDelegate> delegate;
@property (nonatomic, readonly, copy) NSArray<NSUserNotification *> *deliveredNotifications;
@property (nonatomic, copy) NSArray<NSUserNotification *> *scheduledNotifications;
- (void)deliverNotification:(NSUserNotification *)notification;
- (void)scheduleNotification:(NSUserNotification *)notification;
- (void)removeScheduledNotification:(NSUserNotification *)notification;
- (void)removeDeliveredNotification:(NSUserNotification *)notification;
- (void)removeAllDeliveredNotifications;
@end

#pragma mark Apple Events / AppleScript (inert on iOS)

typedef uint32_t AEKeyword;
typedef int32_t AEReturnID;
typedef int32_t AETransactionID;

@interface NSAppleEventDescriptor : NSObject <NSCopying>
+ (NSAppleEventDescriptor *)nullDescriptor;
+ (NSAppleEventDescriptor *)descriptorWithString:(NSString *)string;
+ (NSAppleEventDescriptor *)descriptorWithInt32:(int32_t)signedInt;
+ (NSAppleEventDescriptor *)descriptorWithBoolean:(Boolean)boolean;
+ (NSAppleEventDescriptor *)listDescriptor;
+ (NSAppleEventDescriptor *)appleEventWithEventClass:(uint32_t)eventClass eventID:(uint32_t)eventID
                                    targetDescriptor:(NSAppleEventDescriptor *)target
                                            returnID:(AEReturnID)returnID transactionID:(AETransactionID)transactionID;
@property (nonatomic, readonly) uint32_t eventClass;
@property (nonatomic, readonly) uint32_t eventID;
@property (nonatomic, readonly) uint32_t descriptorType;
@property (nonatomic, readonly, copy) NSString *stringValue;
@property (nonatomic, readonly) int32_t int32Value;
@property (nonatomic, readonly) Boolean booleanValue;
@property (nonatomic, readonly) NSInteger numberOfItems;
- (NSAppleEventDescriptor *)descriptorAtIndex:(NSInteger)index;
- (NSAppleEventDescriptor *)paramDescriptorForKeyword:(AEKeyword)keyword;
- (void)setParamDescriptor:(NSAppleEventDescriptor *)descriptor forKeyword:(AEKeyword)keyword;
- (void)insertDescriptor:(NSAppleEventDescriptor *)descriptor atIndex:(NSInteger)index;
@end

@interface NSAppleEventManager : NSObject
@property (class, readonly, strong) NSAppleEventManager *sharedAppleEventManager;
- (void)setEventHandler:(id)handler andSelector:(SEL)handleEventSelector
          forEventClass:(uint32_t)eventClass andEventID:(uint32_t)eventID;
- (void)removeEventHandlerForEventClass:(uint32_t)eventClass andEventID:(uint32_t)eventID;
- (NSAppleEventDescriptor *)currentAppleEvent;
@end

@interface NSScriptClassDescription : NSObject
+ (NSScriptClassDescription *)classDescriptionForClass:(Class)aClass;
@property (nonatomic, readonly) uint32_t appleEventCode;
@property (nonatomic, readonly, copy) NSString *className;
@end

@interface NSScriptCommand : NSObject
@property (nonatomic, strong) NSScriptClassDescription *commandDescription;
@property (nonatomic, strong) id directParameter;
@property (nonatomic, strong) id evaluatedReceivers;
@property (nonatomic, readonly, strong) NSAppleEventDescriptor *appleEvent;
- (id)executeCommand;
@end

@interface NSUniqueIDSpecifier : NSObject
- (instancetype)initWithContainerClassDescription:(NSScriptClassDescription *)classDescription
                               containerSpecifier:(id)container key:(NSString *)property uniqueID:(id)uniqueID;
@property (nonatomic, strong) id uniqueID;
@property (nonatomic, copy) NSString *key;
@end
