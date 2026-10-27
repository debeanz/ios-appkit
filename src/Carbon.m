// A small, working Carbon Event Manager plus the keyboard-related Carbon calls the client
// makes. See CarbonMac.h.
#import "AKShimPrivate.h"

#pragma mark Events

@interface AKCarbonParam : NSObject
@property (nonatomic) EventParamType type;
@property (nonatomic, copy) NSData *data;
@end
@implementation AKCarbonParam
@end

@interface AKCarbonEvent : NSObject
@property (nonatomic) UInt32 eventClass, eventKind;
@property (nonatomic) EventTime time;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, AKCarbonParam *> *params;
@end
@implementation AKCarbonEvent
@end

static AKCarbonEvent *AKEvent(EventRef e) { return (__bridge AKCarbonEvent *)(void *)e; }

OSStatus CreateEvent(CFAllocatorRef allocator, UInt32 eventClass, UInt32 eventKind, EventTime when,
                     EventAttributes flags, EventRef *outEvent) {
  if (!outEvent) return AKParamErr;
  AKCarbonEvent *e = [AKCarbonEvent new];
  e.eventClass = eventClass;
  e.eventKind = eventKind;
  e.time = when > 0 ? when : NSProcessInfo.processInfo.systemUptime;
  e.params = [NSMutableDictionary dictionary];
  *outEvent = (EventRef)CFBridgingRetain(e);
  return noErr;
}

EventRef CopyEvent(EventRef event) {
  if (!event) return NULL;
  AKCarbonEvent *src = AKEvent(event), *e = [AKCarbonEvent new];
  e.eventClass = src.eventClass;
  e.eventKind = src.eventKind;
  e.time = src.time;
  e.params = [src.params mutableCopy];
  return (EventRef)CFBridgingRetain(e);
}

EventRef RetainEvent(EventRef event) { if (event) CFRetain(event); return event; }
void ReleaseEvent(EventRef event) { if (event) CFRelease(event); }
UInt32 GetEventClass(EventRef event) { return AKEvent(event).eventClass; }
UInt32 GetEventKind(EventRef event) { return AKEvent(event).eventKind; }
EventTime GetEventTime(EventRef event) { return AKEvent(event).time; }
OSStatus SetEventTime(EventRef event, EventTime when) { AKEvent(event).time = when; return noErr; }

OSStatus SetEventParameter(EventRef event, EventParamName name, EventParamType type, ByteCount size, const void *data) {
  if (!event || (!data && size)) return AKParamErr;
  AKCarbonParam *p = [AKCarbonParam new];
  p.type = type;
  p.data = [NSData dataWithBytes:data length:size];
  AKEvent(event).params[@(name)] = p;
  return noErr;
}

OSStatus GetEventParameter(EventRef event, EventParamName name, EventParamType desiredType,
                           EventParamType *outActualType, ByteCount bufferSize, ByteCount *outActualSize, void *outData) {
  AKCarbonParam *p = AKEvent(event).params[@(name)];
  if (!p) return eventParameterNotFoundErr;
  // No type coercion: the stored type must match unless the caller asks for any type.
  if (desiredType != typeWildCard && desiredType != p.type) return eventParameterNotFoundErr;
  if (outActualType) *outActualType = p.type;
  if (outActualSize) *outActualSize = p.data.length;
  if (outData) memcpy(outData, p.data.bytes, MIN(bufferSize, p.data.length));
  return noErr;
}

static NSMutableArray<AKCarbonEvent *> *gDispatching; // events being sent, innermost last

EventRef GetCurrentEvent(void) {
  return (__bridge EventRef)gDispatching.lastObject;
}

#pragma mark Targets and handlers

@class AKCarbonTarget;

@interface AKCarbonHandler : NSObject
@property (nonatomic) EventHandlerUPP proc;
@property (nonatomic) void *userData;
@property (nonatomic, weak) AKCarbonTarget *target;
@property (nonatomic, strong) NSMutableArray<NSValue *> *types; // EventTypeSpec
- (BOOL)handlesClass:(UInt32)cls kind:(UInt32)kind;
@end

@implementation AKCarbonHandler
- (BOOL)handlesClass:(UInt32)cls kind:(UInt32)kind {
  for (NSValue *v in _types) {
    EventTypeSpec spec;
    [v getValue:&spec];
    if (spec.eventClass == cls && spec.eventKind == kind) return YES;
  }
  return NO;
}
@end

@interface AKCarbonTarget : NSObject
@property (nonatomic, strong) NSMutableArray<AKCarbonHandler *> *handlers; // newest first
@end
@implementation AKCarbonTarget
- (instancetype)init { if ((self = [super init])) _handlers = [NSMutableArray array]; return self; }
@end

// One in-flight dispatch: the remaining handlers, so CallNextEventHandler can continue it.
@interface AKCarbonCall : NSObject
@property (nonatomic, strong) NSArray<AKCarbonHandler *> *handlers;
@property (nonatomic) NSUInteger next;
@end
@implementation AKCarbonCall
@end

static AKCarbonTarget *AKTarget(EventTargetRef t) { return (__bridge AKCarbonTarget *)(void *)t; }

static AKCarbonTarget *AKStaticTarget(int which) {
  static AKCarbonTarget *targets[3];
  static dispatch_once_t once;
  dispatch_once(&once, ^{ for (int i = 0; i < 3; i++) targets[i] = [AKCarbonTarget new]; });
  return targets[which];
}

EventTargetRef GetApplicationEventTarget(void) { return (__bridge EventTargetRef)AKStaticTarget(0); }
EventTargetRef GetEventDispatcherTarget(void)  { return (__bridge EventTargetRef)AKStaticTarget(1); }
EventTargetRef GetEventMonitorTarget(void)     { return (__bridge EventTargetRef)AKStaticTarget(2); }

static void AKAddTypes(AKCarbonHandler *h, ItemCount n, const EventTypeSpec *list) {
  for (ItemCount i = 0; i < n; i++) [h.types addObject:[NSValue valueWithBytes:&list[i] objCType:@encode(EventTypeSpec)]];
}

OSStatus InstallEventHandler(EventTargetRef target, EventHandlerUPP handler, ItemCount numTypes,
                             const EventTypeSpec *list, void *userData, EventHandlerRef *outRef) {
  if (!target || !handler) return AKParamErr;
  AKCarbonHandler *h = [AKCarbonHandler new];
  h.proc = handler;
  h.userData = userData;
  h.target = AKTarget(target);
  h.types = [NSMutableArray array];
  AKAddTypes(h, numTypes, list);
  @synchronized (AKTarget(target)) { [AKTarget(target).handlers insertObject:h atIndex:0]; }
  if (outRef) *outRef = (__bridge EventHandlerRef)h; // owned by the target until removed
  return noErr;
}

OSStatus RemoveEventHandler(EventHandlerRef handlerRef) {
  AKCarbonHandler *h = (__bridge AKCarbonHandler *)(void *)handlerRef;
  AKCarbonTarget *t = h.target;
  if (!t) return AKParamErr;
  @synchronized (t) { [t.handlers removeObjectIdenticalTo:h]; }
  return noErr;
}

OSStatus AddEventTypesToHandler(EventHandlerRef handlerRef, ItemCount numTypes, const EventTypeSpec *list) {
  AKAddTypes((__bridge AKCarbonHandler *)(void *)handlerRef, numTypes, list);
  return noErr;
}

OSStatus RemoveEventTypesFromHandler(EventHandlerRef handlerRef, ItemCount numTypes, const EventTypeSpec *list) {
  AKCarbonHandler *h = (__bridge AKCarbonHandler *)(void *)handlerRef;
  for (ItemCount i = 0; i < numTypes; i++) {
    NSIndexSet *gone = [h.types indexesOfObjectsPassingTest:^BOOL(NSValue *v, NSUInteger idx, BOOL *stop) {
      EventTypeSpec spec;
      [v getValue:&spec];
      return spec.eventClass == list[i].eventClass && spec.eventKind == list[i].eventKind;
    }];
    [h.types removeObjectsAtIndexes:gone];
  }
  return noErr;
}

static OSStatus AKContinue(AKCarbonCall *call, EventRef event) {
  AKCarbonEvent *e = AKEvent(event);
  while (call.next < call.handlers.count) {
    AKCarbonHandler *h = call.handlers[call.next++];
    if (![h handlesClass:e.eventClass kind:e.eventKind]) continue;
    OSStatus status = h.proc((__bridge EventHandlerCallRef)call, event, h.userData);
    if (status != eventNotHandledErr) return status;
  }
  return eventNotHandledErr;
}

OSStatus CallNextEventHandler(EventHandlerCallRef callRef, EventRef event) {
  if (!callRef || !event) return AKParamErr;
  return AKContinue((__bridge AKCarbonCall *)(void *)callRef, event);
}

static OSStatus AKSendToTarget(EventRef event, AKCarbonTarget *target) {
  AKCarbonCall *call = [AKCarbonCall new];
  @synchronized (target) { call.handlers = [target.handlers copy]; }
  return AKContinue(call, event);
}

// Unhandled events fall through to the application target, as in Carbon's containment chain.
OSStatus SendEventToEventTargetWithOptions(EventRef event, EventTargetRef target, OptionBits options) {
  if (!event || !target) return AKParamErr;
  if (!gDispatching) gDispatching = [NSMutableArray array];
  [gDispatching addObject:AKEvent(event)];
  OSStatus status = AKSendToTarget(event, AKTarget(target));
  AKCarbonTarget *app = AKStaticTarget(0);
  if (status == eventNotHandledErr && AKTarget(target) != app) status = AKSendToTarget(event, app);
  [gDispatching removeLastObject];
  return status;
}

#pragma mark Queues

@interface AKCarbonQueue : NSObject
@property (nonatomic, strong) NSMutableArray<AKCarbonEvent *> *events;
@end
@implementation AKCarbonQueue
@end

static AKCarbonQueue *AKMainQueue(void) {
  static AKCarbonQueue *q;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ q = [AKCarbonQueue new]; q.events = [NSMutableArray array]; });
  return q;
}

EventQueueRef GetMainEventQueue(void)    { return (__bridge EventQueueRef)AKMainQueue(); }
EventQueueRef GetCurrentEventQueue(void) { return (__bridge EventQueueRef)AKMainQueue(); } // one queue

OSStatus PostEventToQueue(EventQueueRef queue, EventRef event, EventPriority priority) {
  if (!queue || !event) return AKParamErr;
  AKCarbonQueue *q = (__bridge AKCarbonQueue *)(void *)queue;
  @synchronized (q) { [q.events addObject:AKEvent(event)]; }
  CFRunLoopWakeUp(CFRunLoopGetMain());
  return noErr;
}

static AKCarbonEvent *AKTakeMatching(ItemCount n, const EventTypeSpec *list, BOOL pull) {
  AKCarbonQueue *q = AKMainQueue();
  @synchronized (q) {
    for (NSUInteger i = 0; i < q.events.count; i++) {
      AKCarbonEvent *e = q.events[i];
      BOOL match = (n == 0);
      for (ItemCount t = 0; t < n && !match; t++)
        match = list[t].eventClass == e.eventClass && list[t].eventKind == e.eventKind;
      if (!match) continue;
      if (pull) [q.events removeObjectAtIndex:i];
      return e;
    }
  }
  return nil;
}

// Waits by running the current run loop, as Carbon's ReceiveNextEvent does. A negative
// timeout waits forever; zero just checks.
OSStatus ReceiveNextEvent(ItemCount numTypes, const EventTypeSpec *list, EventTimeout timeout,
                          Boolean pullEvent, EventRef *outEvent) {
  NSDate *deadline = timeout < 0 ? NSDate.distantFuture : [NSDate dateWithTimeIntervalSinceNow:timeout];
  for (;;) {
    AKCarbonEvent *e = AKTakeMatching(numTypes, list, pullEvent);
    if (e) {
      if (outEvent) *outEvent = pullEvent ? (EventRef)CFBridgingRetain(e) : (__bridge EventRef)e;
      return noErr;
    }
    if ([deadline timeIntervalSinceNow] <= 0) return eventLoopTimedOutErr;
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:MIN(0.05, MAX(0, deadline.timeIntervalSinceNow))]];
  }
}

#pragma mark Hotkeys

@interface AKCarbonHotKey : NSObject
@property (nonatomic) UInt32 keyCode, modifiers;
@property (nonatomic) EventHotKeyID hotKeyID;
@property (nonatomic, strong) AKCarbonTarget *target;
@end
@implementation AKCarbonHotKey
@end

static NSMutableArray<AKCarbonHotKey *> *gHotKeys;
static const UInt32 AKHotKeyModifierMask = cmdKey | shiftKey | optionKey | controlKey;

static UInt32 AKCarbonModifiers(NSEventModifierFlags f) {
  UInt32 m = 0;
  if (f & NSEventModifierFlagCommand)  m |= cmdKey;
  if (f & NSEventModifierFlagShift)    m |= shiftKey;
  if (f & NSEventModifierFlagCapsLock) m |= alphaLock;
  if (f & NSEventModifierFlagOption)   m |= optionKey;
  if (f & NSEventModifierFlagControl)  m |= controlKey;
  return m;
}

OSStatus RegisterEventHotKey(UInt32 keyCode, UInt32 modifiers, EventHotKeyID hotKeyID, EventTargetRef target,
                             OptionBits options, EventHotKeyRef *outRef) {
  if (!target) return AKParamErr;
  @synchronized (AKStaticTarget(0)) {
    if (!gHotKeys) gHotKeys = [NSMutableArray array];
    for (AKCarbonHotKey *k in gHotKeys)
      if (k.keyCode == keyCode && (k.modifiers & AKHotKeyModifierMask) == (modifiers & AKHotKeyModifierMask)) return eventHotKeyExistsErr;
    AKCarbonHotKey *k = [AKCarbonHotKey new];
    k.keyCode = keyCode;
    k.modifiers = modifiers;
    k.hotKeyID = hotKeyID;
    k.target = AKTarget(target);
    [gHotKeys addObject:k];
    if (outRef) *outRef = (__bridge EventHotKeyRef)k;
  }
  return noErr;
}

OSStatus UnregisterEventHotKey(EventHotKeyRef hotKey) {
  @synchronized (AKStaticTarget(0)) {
    NSUInteger before = gHotKeys.count;
    [gHotKeys removeObjectIdenticalTo:(__bridge AKCarbonHotKey *)(void *)hotKey];
    return gHotKeys.count < before ? noErr : eventHotKeyInvalidErr;
  }
}

BOOL AKCarbonDispatchHotKey(unsigned short keyCode, NSEventModifierFlags flags, BOOL down) {
  UInt32 mods = AKCarbonModifiers(flags) & AKHotKeyModifierMask;
  AKCarbonHotKey *match = nil;
  @synchronized (AKStaticTarget(0)) {
    for (AKCarbonHotKey *k in gHotKeys)
      if (k.keyCode == keyCode && (k.modifiers & AKHotKeyModifierMask) == mods) { match = k; break; }
  }
  if (!match) return NO;
  EventRef e = NULL;
  CreateEvent(NULL, kEventClassKeyboard, down ? kEventHotKeyPressed : kEventHotKeyReleased, 0, 0, &e);
  EventHotKeyID hid = match.hotKeyID;
  SetEventParameter(e, kEventParamDirectObject, typeEventHotKeyID, sizeof hid, &hid);
  SendEventToEventTargetWithOptions(e, (__bridge EventTargetRef)match.target, 0);
  ReleaseEvent(e);
  return YES; // a registered hotkey is consumed, as on the Mac
}

#pragma mark Keyboard state

UInt32 GetCurrentKeyModifiers(void) { return AKCarbonModifiers([NSEvent modifierFlags]); }

// 40 is the keyboard type macOS reports for a standard USB/Bluetooth ANSI keyboard.
UInt8 LMGetKbdType(void) { return 40; }
UInt8 LMGetKbdLast(void) { return 40; }
OSType KBGetLayoutType(SInt16 keyboardType) { return kKeyboardANSI; }

static BOOL gSecureInput;
OSStatus EnableSecureEventInput(void)  { gSecureInput = YES; return noErr; }
OSStatus DisableSecureEventInput(void) { gSecureInput = NO; return noErr; }
Boolean IsSecureEventInputEnabled(void) { return gSecureInput; }

OSErr AEProcessEvent(const EventRecord *theEventRecord) { return noErr; }

#pragma mark Text Services Manager

static NSMutableDictionary<NSString *, NSData *> *gTSMProperties;

static NSString *AKTSMKey(TSMDocumentID doc, TSMDocumentPropertyTag tag) {
  return [NSString stringWithFormat:@"%p/%u", doc, (unsigned)tag];
}

OSStatus TSMSetDocumentProperty(TSMDocumentID doc, TSMDocumentPropertyTag tag, UInt32 size, void *data) {
  @synchronized (AKStaticTarget(0)) {
    if (!gTSMProperties) gTSMProperties = [NSMutableDictionary dictionary];
    gTSMProperties[AKTSMKey(doc, tag)] = [NSData dataWithBytes:data length:size];
  }
  return noErr;
}

OSStatus TSMRemoveDocumentProperty(TSMDocumentID doc, TSMDocumentPropertyTag tag) {
  @synchronized (AKStaticTarget(0)) { [gTSMProperties removeObjectForKey:AKTSMKey(doc, tag)]; }
  return noErr;
}

#pragma mark Text Input Sources

const CFStringRef kTISPropertyInputSourceID = CFSTR("TISPropertyInputSourceID");
const CFStringRef kTISPropertyUnicodeKeyLayoutData = CFSTR("TISPropertyUnicodeKeyLayoutData");

@interface AKInputSource : NSObject
@property (nonatomic, copy) NSDictionary *properties;
@end
@implementation AKInputSource
@end

static AKInputSource *AKUSInputSource(void) {
  static AKInputSource *source;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    source = [AKInputSource new];
    source.properties = @{
      (__bridge NSString *)kTISPropertyInputSourceID: @"com.apple.keylayout.US",
      (__bridge NSString *)kTISPropertyUnicodeKeyLayoutData: AKUSKeyboardLayoutData(),
    };
  });
  return source;
}

TISInputSourceRef TISCopyCurrentKeyboardInputSource(void) { return (TISInputSourceRef)CFBridgingRetain(AKUSInputSource()); }
TISInputSourceRef TISCopyCurrentKeyboardLayoutInputSource(void) { return TISCopyCurrentKeyboardInputSource(); }
TISInputSourceRef TISCopyCurrentASCIICapableKeyboardLayoutInputSource(void) { return TISCopyCurrentKeyboardInputSource(); }
CFArrayRef TISCreateASCIICapableInputSourceList(void) { return (CFArrayRef)CFBridgingRetain(@[ AKUSInputSource() ]); }

// Follows the Get rule: the value belongs to the source, so callers don't release it.
void *TISGetInputSourceProperty(TISInputSourceRef source, CFStringRef key) {
  AKInputSource *s = (__bridge AKInputSource *)(void *)source;
  return (__bridge void *)s.properties[(__bridge NSString *)key];
}
