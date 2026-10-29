// The part of Carbon the client still uses: the Carbon Event Manager (handlers, targets,
// queues, global hotkeys), keyboard type queries, secure input, Text Services Manager
// document properties and Text Input Sources. iOS has no Carbon; this is a small working
// implementation, not stubs: handlers installed on a target really receive events sent to
// it, and hotkeys registered with RegisterEventHotKey fire from the hardware keyboard.
#import <CoreFoundation/CoreFoundation.h>
#import <MacTypes.h>

typedef struct OpaqueEventRef *EventRef;
typedef struct OpaqueEventTargetRef *EventTargetRef;
typedef struct OpaqueEventQueueRef *EventQueueRef;
typedef struct OpaqueEventHandlerRef *EventHandlerRef;
typedef struct OpaqueEventHandlerCallRef *EventHandlerCallRef;
typedef struct OpaqueEventHotKeyRef *EventHotKeyRef;
typedef struct __TISInputSource *TISInputSourceRef;
typedef void *TSMDocumentID;

typedef double EventTime;
typedef double EventTimeout;
typedef UInt32 EventAttributes;
typedef SInt16 EventPriority;
typedef OSType EventParamName;
typedef OSType EventParamType;
typedef UInt32 TSMDocumentPropertyTag;

typedef struct EventTypeSpec { OSType eventClass; UInt32 eventKind; } EventTypeSpec;
typedef struct EventHotKeyID { OSType signature; UInt32 id; } EventHotKeyID;

typedef OSStatus (*EventHandlerProcPtr)(EventHandlerCallRef inHandlerCallRef, EventRef inEvent, void *inUserData);
typedef EventHandlerProcPtr EventHandlerUPP;
#define NewEventHandlerUPP(proc) ((EventHandlerUPP)(proc))
#define DisposeEventHandlerUPP(upp) ((void)(upp))

// Classic Event Manager record, only so AEProcessEvent has its real signature.
typedef UInt16 EventKind;
typedef UInt16 EventModifiers;
typedef struct EventRecord {
  EventKind what;
  unsigned long message;
  UInt32 when;
  Point where;
  EventModifiers modifiers;
} EventRecord;

enum {
  eventNotHandledErr = -9874,
  eventLoopTimedOutErr = -9875,
  eventParameterNotFoundErr = -9870,
  eventHotKeyExistsErr = -9878,
  eventHotKeyInvalidErr = -9879,
};

enum {
  kEventClassKeyboard = 'keyb',
  kEventClassApplication = 'appl',
  kEventHotKeyPressed = 5,
  kEventHotKeyReleased = 6,
  kEventParamDirectObject = '----',
  typeEventHotKeyID = 'hkid',
  typeWildCard = '****',
  kEventAttributeNone = 0,
  kEventPriorityStandard = 1,
};

// GetCurrentKeyModifiers bits.
enum {
  cmdKey = 1 << 8,
  shiftKey = 1 << 9,
  alphaLock = 1 << 10,
  optionKey = 1 << 11,
  controlKey = 1 << 12,
};

enum { kKeyboardJIS = 'JIS ', kKeyboardANSI = 'ANSI', kKeyboardISO = 'ISO ', kKeyboardUnknown = kUnknownType };

// Events
extern OSStatus CreateEvent(CFAllocatorRef allocator, UInt32 eventClass, UInt32 eventKind, EventTime when,
                            EventAttributes flags, EventRef *outEvent);
extern EventRef CopyEvent(EventRef event);
extern EventRef RetainEvent(EventRef event);
extern void ReleaseEvent(EventRef event);
extern UInt32 GetEventClass(EventRef event);
extern UInt32 GetEventKind(EventRef event);
extern EventTime GetEventTime(EventRef event);
extern OSStatus SetEventTime(EventRef event, EventTime when);
extern EventTime GetCurrentEventTime(void);
extern OSStatus SetEventParameter(EventRef event, EventParamName name, EventParamType type, ByteCount size, const void *data);
extern OSStatus GetEventParameter(EventRef event, EventParamName name, EventParamType desiredType,
                                  EventParamType *outActualType, ByteCount bufferSize, ByteCount *outActualSize, void *outData);
extern EventRef GetCurrentEvent(void);

// Targets and handlers
extern EventTargetRef GetApplicationEventTarget(void);
extern EventTargetRef GetEventDispatcherTarget(void);
extern EventTargetRef GetEventMonitorTarget(void);
extern OSStatus InstallEventHandler(EventTargetRef target, EventHandlerUPP handler, ItemCount numTypes,
                                    const EventTypeSpec *list, void *userData, EventHandlerRef *outRef);
extern OSStatus RemoveEventHandler(EventHandlerRef handler);
extern OSStatus AddEventTypesToHandler(EventHandlerRef handler, ItemCount numTypes, const EventTypeSpec *list);
extern OSStatus RemoveEventTypesFromHandler(EventHandlerRef handler, ItemCount numTypes, const EventTypeSpec *list);
extern OSStatus CallNextEventHandler(EventHandlerCallRef callRef, EventRef event);
extern OSStatus SendEventToEventTargetWithOptions(EventRef event, EventTargetRef target, OptionBits options);

// Queues
extern EventQueueRef GetMainEventQueue(void);
extern EventQueueRef GetCurrentEventQueue(void);
extern OSStatus PostEventToQueue(EventQueueRef queue, EventRef event, EventPriority priority);
extern OSStatus ReceiveNextEvent(ItemCount numTypes, const EventTypeSpec *list, EventTimeout timeout,
                                 Boolean pullEvent, EventRef *outEvent);

// Hotkeys: macOS virtual key code + Carbon modifier bits (cmdKey...).
extern OSStatus RegisterEventHotKey(UInt32 keyCode, UInt32 modifiers, EventHotKeyID hotKeyID, EventTargetRef target,
                                    OptionBits options, EventHotKeyRef *outRef);
extern OSStatus UnregisterEventHotKey(EventHotKeyRef hotKey);

// Keyboard state
extern UInt32 GetCurrentKeyModifiers(void);
extern UInt8 LMGetKbdType(void);
extern UInt8 LMGetKbdLast(void);
extern OSType KBGetLayoutType(SInt16 keyboardType);
extern OSStatus EnableSecureEventInput(void);
extern OSStatus DisableSecureEventInput(void);
extern Boolean IsSecureEventInputEnabled(void);

// Apple Events from the classic loop: nothing arrives that way on iOS.
extern OSErr AEProcessEvent(const EventRecord *theEventRecord);

// Text Services Manager
extern OSStatus TSMSetDocumentProperty(TSMDocumentID doc, TSMDocumentPropertyTag tag, UInt32 size, void *data);
extern OSStatus TSMRemoveDocumentProperty(TSMDocumentID doc, TSMDocumentPropertyTag tag);

// Text Input Sources: one US keyboard layout.
extern const CFStringRef kTISPropertyInputSourceID;
extern const CFStringRef kTISPropertyUnicodeKeyLayoutData;
extern const CFStringRef kTISPropertyInputSourceType;
extern const CFStringRef kTISTypeKeyboardLayout;
extern const CFStringRef kTISNotifySelectedKeyboardInputSourceChanged;   // never posted: the layout never changes
extern const CFStringRef kTISPropertyLocalizedName;
extern const CFStringRef kTISPropertyInputSourceLanguages;
extern const CFStringRef kTISTypeKeyboardInputMode;
// The sources whose properties match every one given (all of them for NULL): the one layout,
// or none. Selecting it succeeds; it is already the one.
extern CFArrayRef TISCreateInputSourceList(CFDictionaryRef properties, Boolean includeAllInstalled) CF_RETURNS_RETAINED;
extern OSStatus TISSelectInputSource(TISInputSourceRef source);
extern TISInputSourceRef TISCopyCurrentKeyboardInputSource(void) CF_RETURNS_RETAINED;
extern TISInputSourceRef TISCopyCurrentKeyboardLayoutInputSource(void) CF_RETURNS_RETAINED;
extern TISInputSourceRef TISCopyCurrentASCIICapableKeyboardLayoutInputSource(void) CF_RETURNS_RETAINED;
extern CFArrayRef TISCreateASCIICapableInputSourceList(void) CF_RETURNS_RETAINED;
extern void *TISGetInputSourceProperty(TISInputSourceRef source, CFStringRef propertyKey);
