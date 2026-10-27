// A real 'uchr' keyboard layout for the US keyboard, built at runtime, and UCKeyTranslate,
// which reads any uchr with direct key outputs. The layout is what
// TISGetInputSourceProperty(kTISPropertyUnicodeKeyLayoutData) hands out, so Chromium and SDL
// translate keys exactly as they do on a Mac with the US layout selected.
//
// Not modelled: the Option-key layer (å, ∫, ç...) and dead keys; Option maps to the base layer.
#import "AKShimPrivate.h"
#import "AppKitShim/CoreServicesMac.h"

static const UCKeyOutput AKNoOutput = 0xFFFF;

enum { AKTableBase = 0, AKTableShift = 1, AKTableCaps = 2, AKTableCount = 3, AKKeyCount = 128 };

// Characters for each macOS virtual key code: unshifted, shifted. Non-text keys carry the
// control characters the Mac's own US layout uses (Return 0x0D, arrows 0x1C-0x1F...).
static void AKFillUSTables(UCKeyOutput tables[AKTableCount][AKKeyCount]) {
  for (int t = 0; t < AKTableCount; t++)
    for (int k = 0; k < AKKeyCount; k++) tables[t][k] = AKNoOutput;

  static const struct { UInt8 code; char base, shift; } printable[] = {
    {0x00,'a','A'}, {0x01,'s','S'}, {0x02,'d','D'}, {0x03,'f','F'}, {0x04,'h','H'}, {0x05,'g','G'},
    {0x06,'z','Z'}, {0x07,'x','X'}, {0x08,'c','C'}, {0x09,'v','V'}, {0x0B,'b','B'}, {0x0C,'q','Q'},
    {0x0D,'w','W'}, {0x0E,'e','E'}, {0x0F,'r','R'}, {0x10,'y','Y'}, {0x11,'t','T'}, {0x12,'1','!'},
    {0x13,'2','@'}, {0x14,'3','#'}, {0x15,'4','$'}, {0x16,'6','^'}, {0x17,'5','%'}, {0x18,'=','+'},
    {0x19,'9','('}, {0x1A,'7','&'}, {0x1B,'-','_'}, {0x1C,'8','*'}, {0x1D,'0',')'}, {0x1E,']','}'},
    {0x1F,'o','O'}, {0x20,'u','U'}, {0x21,'[','{'}, {0x22,'i','I'}, {0x23,'p','P'}, {0x25,'l','L'},
    {0x26,'j','J'}, {0x27,'\'','"'}, {0x28,'k','K'}, {0x29,';',':'}, {0x2A,'\\','|'}, {0x2B,',','<'},
    {0x2C,'/','?'}, {0x2D,'n','N'}, {0x2E,'m','M'}, {0x2F,'.','>'}, {0x31,' ',' '}, {0x32,'`','~'},
  };
  for (size_t i = 0; i < sizeof printable / sizeof printable[0]; i++) {
    UInt8 k = printable[i].code;
    char base = printable[i].base;
    tables[AKTableBase][k] = (UCKeyOutput)base;
    tables[AKTableShift][k] = (UCKeyOutput)printable[i].shift;
    // Caps Lock capitalises letters only.
    tables[AKTableCaps][k] = (base >= 'a' && base <= 'z') ? (UCKeyOutput)(base - 'a' + 'A') : (UCKeyOutput)base;
  }

  static const struct { UInt8 code; UCKeyOutput out; } control[] = {
    {0x24, 0x0D}, {0x30, 0x09}, {0x33, 0x08}, {0x35, 0x1B}, {0x4C, 0x03}, // Return Tab Delete Esc Enter
    {0x73, 0x01}, {0x77, 0x04}, {0x74, 0x0B}, {0x79, 0x0C}, {0x75, 0x7F}, // Home End PgUp PgDn FwdDel
    {0x7B, 0x1C}, {0x7C, 0x1D}, {0x7E, 0x1E}, {0x7D, 0x1F},               // Left Right Up Down
    {0x7A, 0x10}, {0x78, 0x10}, {0x63, 0x10}, {0x76, 0x10}, {0x60, 0x10}, {0x61, 0x10}, // F1-F6
    {0x62, 0x10}, {0x64, 0x10}, {0x65, 0x10}, {0x6D, 0x10}, {0x67, 0x10}, {0x6F, 0x10}, // F7-F12
  };
  for (size_t i = 0; i < sizeof control / sizeof control[0]; i++)
    for (int t = 0; t < AKTableCount; t++) tables[t][control[i].code] = control[i].out;
}

// Which table a modifier state uses. The state is the Carbon modifier mask >> 8:
// bit 0 Command, 1 Shift, 2 Caps Lock, 3 Option, 4 Control, 5 right Shift, 6 right Option,
// 7 right Control.
static UInt8 AKTableForModifierState(unsigned state) {
  BOOL shift = (state & 0x02) || (state & 0x20);
  BOOL caps = (state & 0x04) != 0;
  if (shift) return AKTableShift;
  if (caps) return AKTableCaps;
  return AKTableBase;
}

NSData *AKUSKeyboardLayoutData(void) {
  static NSData *data;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // Layout: header (with one keyboard-type entry) | modifiers table | char table index | tables.
    const size_t headerSize = sizeof(UCKeyboardLayout);
    const size_t modsSize = (offsetof(UCKeyModifiersToTableNum, tableNum) + 256 + 3) & ~(size_t)3;
    const size_t indexSize = offsetof(UCKeyToCharTableIndex, keyToCharTableOffsets) + AKTableCount * sizeof(UInt32);
    const size_t tableSize = AKKeyCount * sizeof(UCKeyOutput);
    const size_t modsOffset = headerSize, indexOffset = modsOffset + modsSize, tablesOffset = indexOffset + indexSize;
    NSMutableData *blob = [NSMutableData dataWithLength:tablesOffset + AKTableCount * tableSize];
    uint8_t *base = blob.mutableBytes;

    UCKeyboardLayout *header = (UCKeyboardLayout *)base;
    header->keyLayoutHeaderFormat = kUCKeyLayoutHeaderFormat;
    header->keyLayoutDataVersion = 0x0100;
    header->keyLayoutFeatureInfoOffset = 0;
    header->keyboardTypeCount = 1;
    header->keyboardTypeList[0] = (UCKeyboardTypeHeader){
      .keyboardTypeFirst = 0, .keyboardTypeLast = 0, // 0..0 applies to every keyboard type
      .keyModifiersToTableNumOffset = (UInt32)modsOffset,
      .keyToCharTableIndexOffset = (UInt32)indexOffset,
    };

    UCKeyModifiersToTableNum *mods = (UCKeyModifiersToTableNum *)(base + modsOffset);
    mods->keyModifiersToTableNumFormat = kUCKeyModifiersToTableNumFormat;
    mods->defaultTableNum = AKTableBase;
    mods->modifiersCount = 256;
    for (unsigned s = 0; s < 256; s++) mods->tableNum[s] = AKTableForModifierState(s);

    UCKeyToCharTableIndex *index = (UCKeyToCharTableIndex *)(base + indexOffset);
    index->keyToCharTableIndexFormat = kUCKeyToCharTableIndexFormat;
    index->keyToCharTableSize = AKKeyCount;
    index->keyToCharTableCount = AKTableCount;
    UCKeyOutput tables[AKTableCount][AKKeyCount];
    AKFillUSTables(tables);
    for (unsigned t = 0; t < AKTableCount; t++) {
      size_t off = tablesOffset + t * tableSize;
      index->keyToCharTableOffsets[t] = (UInt32)off;
      memcpy(base + off, tables[t], tableSize);
    }
    data = [blob copy];
  });
  return data;
}

OSStatus UCKeyTranslate(const UCKeyboardLayout *layout, UInt16 virtualKeyCode, UInt16 keyAction,
                        UInt32 modifierKeyState, UInt32 keyboardType, OptionBits options,
                        UInt32 *deadKeyState, UniCharCount maxStringLength,
                        UniCharCount *actualStringLength, UniChar unicodeString[]) {
  if (!layout || !actualStringLength) return AKParamErr;
  *actualStringLength = 0;
  if (deadKeyState) *deadKeyState = 0;
  if (layout->keyLayoutHeaderFormat != kUCKeyLayoutHeaderFormat || layout->keyboardTypeCount == 0) return AKParamErr;
  if (keyAction == kUCKeyActionUp) return noErr; // key ups produce no text

  // Use the entry covering this keyboard type, falling back to the first.
  const UCKeyboardTypeHeader *type = &layout->keyboardTypeList[0];
  for (UInt32 i = 0; i < layout->keyboardTypeCount; i++) {
    const UCKeyboardTypeHeader *t = &layout->keyboardTypeList[i];
    if (keyboardType >= t->keyboardTypeFirst && keyboardType <= t->keyboardTypeLast) { type = t; break; }
  }

  const uint8_t *base = (const uint8_t *)layout;
  const UCKeyModifiersToTableNum *mods = (const UCKeyModifiersToTableNum *)(base + type->keyModifiersToTableNumOffset);
  const UCKeyToCharTableIndex *index = (const UCKeyToCharTableIndex *)(base + type->keyToCharTableIndexOffset);
  if (mods->keyModifiersToTableNumFormat != kUCKeyModifiersToTableNumFormat ||
      index->keyToCharTableIndexFormat != kUCKeyToCharTableIndexFormat) return AKParamErr;

  UInt32 state = modifierKeyState & 0xFF;
  UInt32 table = state < mods->modifiersCount ? mods->tableNum[state] : mods->defaultTableNum;
  if (table >= index->keyToCharTableCount || virtualKeyCode >= index->keyToCharTableSize) return noErr;

  const UCKeyOutput *chars = (const UCKeyOutput *)(base + index->keyToCharTableOffsets[table]);
  UCKeyOutput out = chars[virtualKeyCode];
  if (out == AKNoOutput || (out & kUCKeyOutputTestForIndexMask)) return noErr; // no text / dead key
  if (maxStringLength == 0 || !unicodeString) return noErr;
  unicodeString[0] = out;
  *actualStringLength = 1;
  return noErr;
}

double Fix2X(Fixed x) { return (double)x / 65536.0; }
Fixed Long2Fix(long x) { return (Fixed)(x << 16); }
