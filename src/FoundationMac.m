#import "AKShimPrivate.h"
#import "AppKitShim/FoundationMac.h"
#import <UserNotifications/UserNotifications.h>

NSString *const NSUserNotificationDefaultSoundName = @"DefaultSoundName";

#pragma mark User notifications (UNUserNotificationCenter)

@interface NSUserNotification ()
@property (nonatomic, readwrite) NSUserNotificationActivationType activationType;
@property (nonatomic, readwrite, getter=isPresented) BOOL presented;
@property (nonatomic, readwrite, copy) NSDate *actualDeliveryDate;
@end

@implementation NSUserNotification
- (id)copyWithZone:(NSZone *)zone {
  NSUserNotification *c = [NSUserNotification new];
  c.title = _title; c.subtitle = _subtitle; c.informativeText = _informativeText;
  c.identifier = _identifier; c.userInfo = _userInfo; c.soundName = _soundName;
  c.contentImage = _contentImage; c.hasActionButton = _hasActionButton;
  c.actionButtonTitle = _actionButtonTitle; c.otherButtonTitle = _otherButtonTitle;
  c.deliveryDate = _deliveryDate;
  return c;
}

AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

@implementation NSUserNotificationCenter {
  NSMutableArray<NSUserNotification *> *_delivered;
}

+ (NSUserNotificationCenter *)defaultUserNotificationCenter {
  static NSUserNotificationCenter *center;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ center = [NSUserNotificationCenter new]; });
  return center;
}

- (instancetype)init {
  if ((self = [super init])) { _delivered = [NSMutableArray array]; _scheduledNotifications = @[]; }
  return self;
}

- (NSArray<NSUserNotification *> *)deliveredNotifications { return [_delivered copy]; }

static NSString *AKNotificationID(NSUserNotification *n) {
  return n.identifier.length ? n.identifier : [NSUUID UUID].UUIDString;
}

// Posts through the iOS notification center, asking permission the first time. A notification
// delivered while the app is foreground still fires the delegate's didDeliver callback.
- (void)deliverNotification:(NSUserNotification *)notification {
  if (!notification) return;
  NSString *identifier = AKNotificationID(notification);
  notification.identifier = identifier;
  notification.actualDeliveryDate = [NSDate date];

  UNUserNotificationCenter *un = UNUserNotificationCenter.currentNotificationCenter;
  [un requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                    completionHandler:^(BOOL granted, NSError *error) {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = notification.title ?: @"";
    content.subtitle = notification.subtitle ?: @"";
    content.body = notification.informativeText ?: @"";
    if (notification.userInfo) content.userInfo = notification.userInfo;
    if (notification.soundName) content.sound = UNNotificationSound.defaultSound;
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
    [un addNotificationRequest:request withCompletionHandler:nil];
  }];

  @synchronized (_delivered) { [_delivered addObject:notification]; }
  notification.presented = YES;
  dispatch_async(dispatch_get_main_queue(), ^{
    if ([self.delegate respondsToSelector:@selector(userNotificationCenter:didDeliverNotification:)])
      [self.delegate userNotificationCenter:self didDeliverNotification:notification];
  });
}

// Scheduling for a future date maps onto a time-interval trigger; a past date delivers now.
- (void)scheduleNotification:(NSUserNotification *)notification {
  NSTimeInterval delay = [notification.deliveryDate timeIntervalSinceNow];
  if (delay <= 0) { [self deliverNotification:notification]; return; }
  NSString *identifier = AKNotificationID(notification);
  notification.identifier = identifier;
  UNUserNotificationCenter *un = UNUserNotificationCenter.currentNotificationCenter;
  [un requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                    completionHandler:^(BOOL granted, NSError *error) {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = notification.title ?: @"";
    content.body = notification.informativeText ?: @"";
    UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:delay repeats:NO];
    [un addNotificationRequest:[UNNotificationRequest requestWithIdentifier:identifier content:content trigger:trigger]
         withCompletionHandler:nil];
  }];
}

- (void)removeScheduledNotification:(NSUserNotification *)notification {
  if (notification.identifier)
    [UNUserNotificationCenter.currentNotificationCenter removePendingNotificationRequestsWithIdentifiers:@[ notification.identifier ]];
}

- (void)removeDeliveredNotification:(NSUserNotification *)notification {
  if (!notification.identifier) return;
  [UNUserNotificationCenter.currentNotificationCenter removeDeliveredNotificationsWithIdentifiers:@[ notification.identifier ]];
  @synchronized (_delivered) { [_delivered removeObjectIdenticalTo:notification]; }
}

- (void)removeAllDeliveredNotifications {
  [UNUserNotificationCenter.currentNotificationCenter removeAllDeliveredNotifications];
  @synchronized (_delivered) { [_delivered removeAllObjects]; }
}


AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

#pragma mark Apple Events (inert model)

// A minimal descriptor that holds a value, list items and keyed parameters, so code that
// builds an Apple Event and reads values back works; nothing is ever dispatched to another app.
@implementation NSAppleEventDescriptor {
  NSMutableArray<NSAppleEventDescriptor *> *_list;
  NSMutableDictionary<NSNumber *, NSAppleEventDescriptor *> *_params;
  NSString *_string;
  int32_t _int32;
  Boolean _boolean;
}

- (instancetype)init {
  if ((self = [super init])) { _list = [NSMutableArray array]; _params = [NSMutableDictionary dictionary]; }
  return self;
}

+ (NSAppleEventDescriptor *)nullDescriptor { return [NSAppleEventDescriptor new]; }
+ (NSAppleEventDescriptor *)listDescriptor { return [NSAppleEventDescriptor new]; }

+ (NSAppleEventDescriptor *)descriptorWithString:(NSString *)string {
  NSAppleEventDescriptor *d = [NSAppleEventDescriptor new];
  d->_string = [string copy];
  d->_descriptorType = 'utxt';
  return d;
}

+ (NSAppleEventDescriptor *)descriptorWithInt32:(int32_t)value {
  NSAppleEventDescriptor *d = [NSAppleEventDescriptor new];
  d->_int32 = value;
  d->_descriptorType = 'long';
  return d;
}

+ (NSAppleEventDescriptor *)descriptorWithBoolean:(Boolean)value {
  NSAppleEventDescriptor *d = [NSAppleEventDescriptor new];
  d->_boolean = value;
  d->_descriptorType = 'bool';
  return d;
}

+ (NSAppleEventDescriptor *)appleEventWithEventClass:(uint32_t)eventClass eventID:(uint32_t)eventID
                                    targetDescriptor:(NSAppleEventDescriptor *)target
                                            returnID:(AEReturnID)returnID transactionID:(AETransactionID)transactionID {
  NSAppleEventDescriptor *d = [NSAppleEventDescriptor new];
  d->_eventClass = eventClass;
  d->_eventID = eventID;
  d->_descriptorType = 'aevt';
  return d;
}

- (NSString *)stringValue { return _string; }
- (int32_t)int32Value { return _int32; }
- (Boolean)booleanValue { return _boolean; }
- (NSInteger)numberOfItems { return (NSInteger)_list.count; }
- (NSAppleEventDescriptor *)descriptorAtIndex:(NSInteger)index { return (index >= 1 && index <= (NSInteger)_list.count) ? _list[index - 1] : nil; }
- (NSAppleEventDescriptor *)paramDescriptorForKeyword:(AEKeyword)keyword { return _params[@(keyword)]; }
- (void)setParamDescriptor:(NSAppleEventDescriptor *)descriptor forKeyword:(AEKeyword)keyword { if (descriptor) _params[@(keyword)] = descriptor; }

- (void)insertDescriptor:(NSAppleEventDescriptor *)descriptor atIndex:(NSInteger)index {
  if (!descriptor) return;
  NSInteger i = index <= 0 ? (NSInteger)_list.count : MIN(index - 1, (NSInteger)_list.count);
  [_list insertObject:descriptor atIndex:(NSUInteger)i];
}

- (id)copyWithZone:(NSZone *)zone {
  NSAppleEventDescriptor *c = [NSAppleEventDescriptor new];
  c->_string = _string; c->_int32 = _int32; c->_boolean = _boolean;
  c->_eventClass = _eventClass; c->_eventID = _eventID; c->_descriptorType = _descriptorType;
  c->_list = [_list mutableCopy]; c->_params = [_params mutableCopy];
  return c;
}


AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

@implementation NSAppleEventManager

+ (NSAppleEventManager *)sharedAppleEventManager {
  static NSAppleEventManager *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [NSAppleEventManager new]; });
  return shared;
}

// No Apple Events are delivered on iOS, so a registered handler is simply never called.
- (void)setEventHandler:(id)handler andSelector:(SEL)selector forEventClass:(uint32_t)eventClass andEventID:(uint32_t)eventID {}
- (void)removeEventHandlerForEventClass:(uint32_t)eventClass andEventID:(uint32_t)eventID {}
- (NSAppleEventDescriptor *)currentAppleEvent { return nil; }


AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

@implementation NSScriptClassDescription
+ (NSScriptClassDescription *)classDescriptionForClass:(Class)aClass {
  NSScriptClassDescription *d = [NSScriptClassDescription new];
  d->_className = NSStringFromClass(aClass);
  return d;
}

AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

@implementation NSScriptCommand
- (NSAppleEventDescriptor *)appleEvent { return nil; }
- (id)executeCommand { return nil; } // no scripting runtime on iOS

AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

@implementation NSUniqueIDSpecifier
- (instancetype)initWithContainerClassDescription:(NSScriptClassDescription *)classDescription
                               containerSpecifier:(id)container key:(NSString *)property uniqueID:(id)uniqueID {
  if ((self = [super init])) { _key = [property copy]; _uniqueID = uniqueID; }
  return self;
}

AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end
