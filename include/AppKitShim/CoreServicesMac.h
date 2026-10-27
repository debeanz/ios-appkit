// The macOS-only CoreServices calls the client needs for keyboard input: UCKeyTranslate and
// the 'uchr' keyboard-layout format it reads, plus two FixMath helpers. iOS lacks all of it
// (confirmed against the iOS SDK's export lists).
#import <CoreFoundation/CoreFoundation.h>
#import <MacTypes.h>

// 'uchr' layout structures, as in macOS UnicodeUtilities.h.
typedef UInt16 UCKeyOutput;

typedef struct UCKeyboardTypeHeader {
  UInt32 keyboardTypeFirst;
  UInt32 keyboardTypeLast;
  UInt32 keyModifiersToTableNumOffset;
  UInt32 keyToCharTableIndexOffset;
  UInt32 keyStateRecordsIndexOffset;
  UInt32 keyStateTerminatorsOffset;
  UInt32 keySequenceDataIndexOffset;
} UCKeyboardTypeHeader;

typedef struct UCKeyboardLayout {
  UInt16 keyLayoutHeaderFormat;
  UInt16 keyLayoutDataVersion;
  UInt32 keyLayoutFeatureInfoOffset;
  UInt32 keyboardTypeCount;
  UCKeyboardTypeHeader keyboardTypeList[1];
} UCKeyboardLayout;

typedef struct UCKeyModifiersToTableNum {
  UInt16 keyModifiersToTableNumFormat;
  UInt16 defaultTableNum;
  UInt32 modifiersCount;
  UInt8 tableNum[1];
} UCKeyModifiersToTableNum;

typedef struct UCKeyToCharTableIndex {
  UInt16 keyToCharTableIndexFormat;
  UInt16 keyToCharTableSize;
  UInt32 keyToCharTableCount;
  UInt32 keyToCharTableOffsets[1];
} UCKeyToCharTableIndex;

enum {
  kUCKeyLayoutHeaderFormat = 0x1002,
  kUCKeyLayoutFeatureInfoFormat = 0x2001,
  kUCKeyModifiersToTableNumFormat = 0x4001,
  kUCKeyToCharTableIndexFormat = 0x5001,
};

enum {
  kUCKeyActionDown = 0,
  kUCKeyActionUp = 1,
  kUCKeyActionAutoKey = 2,
  kUCKeyActionDisplay = 3,
};

enum {
  kUCKeyTranslateNoDeadKeysBit = 0,
  kUCKeyTranslateNoDeadKeysMask = 1 << kUCKeyTranslateNoDeadKeysBit,
};

// Key outputs with these top bits are dead-key states or sequences; the US layout has none.
enum {
  kUCKeyOutputStateIndexMask = 0x4000,
  kUCKeyOutputSequenceIndexMask = 0x8000,
  kUCKeyOutputTestForIndexMask = 0xC000,
  kUCKeyOutputGetIndexMask = 0x3FFF,
};

// Translates one key press with a layout. modifierKeyState is the Carbon modifier mask
// shifted right by 8, as on the Mac: ((modifiers >> 8) & 0xFF).
extern OSStatus UCKeyTranslate(const UCKeyboardLayout *keyLayoutPtr,
                               UInt16 virtualKeyCode,
                               UInt16 keyAction,
                               UInt32 modifierKeyState,
                               UInt32 keyboardType,
                               OptionBits keyTranslateOptions,
                               UInt32 *deadKeyState,
                               UniCharCount maxStringLength,
                               UniCharCount *actualStringLength,
                               UniChar unicodeString[]);

extern double Fix2X(Fixed x); // Fixed comes from MacTypes.h
extern Fixed Long2Fix(long x);
