// Key translation tables. UIKit reports keys as USB HID usages; AppKit (and Chromium,
// which builds DOM key events from NSEvent) expects macOS virtual key codes (kVK_*).
#import "AKShimPrivate.h"

enum { AKUnknownKey = 0xFF };

unsigned short AKMacKeyCodeForHIDUsage(long u) {
  // Letters a..z are HID 0x04..0x1D; kVK codes follow the physical ANSI layout instead.
  static const unsigned char letters[26] = {
    0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E, // a..m
    0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06, // n..z
  };
  // Digits 1..9,0 are HID 0x1E..0x27.
  static const unsigned char digits[10] = { 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D };
  // F1..F12 are HID 0x3A..0x45.
  static const unsigned char fkeys[12] = { 0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F };

  if (u >= 0x04 && u <= 0x1D) return letters[u - 0x04];
  if (u >= 0x1E && u <= 0x27) return digits[u - 0x1E];
  if (u >= 0x3A && u <= 0x45) return fkeys[u - 0x3A];
  switch (u) {
    case 0x28: return 0x24; // Return
    case 0x29: return 0x35; // Escape
    case 0x2A: return 0x33; // Backspace (kVK_Delete)
    case 0x2B: return 0x30; // Tab
    case 0x2C: return 0x31; // Space
    case 0x2D: return 0x1B; // -
    case 0x2E: return 0x18; // =
    case 0x2F: return 0x21; // [
    case 0x30: return 0x1E; // ]
    case 0x31: return 0x2A; // backslash
    case 0x33: return 0x29; // ;
    case 0x34: return 0x27; // '
    case 0x35: return 0x32; // `
    case 0x36: return 0x2B; // ,
    case 0x37: return 0x2F; // .
    case 0x38: return 0x2C; // /
    case 0x39: return 0x39; // Caps Lock
    case 0x4A: return 0x73; // Home
    case 0x4B: return 0x74; // Page Up
    case 0x4C: return 0x75; // Forward Delete
    case 0x4D: return 0x77; // End
    case 0x4E: return 0x79; // Page Down
    case 0x4F: return 0x7C; // Right
    case 0x50: return 0x7B; // Left
    case 0x51: return 0x7D; // Down
    case 0x52: return 0x7E; // Up
    case 0x58: return 0x4C; // Keypad Enter
    case 0xE0: return 0x3B; // Left Control
    case 0xE1: return 0x38; // Left Shift
    case 0xE2: return 0x3A; // Left Option
    case 0xE3: return 0x37; // Left Command
    case 0xE4: return 0x3E; // Right Control
    case 0xE5: return 0x3C; // Right Shift
    case 0xE6: return 0x3D; // Right Option
    case 0xE7: return 0x36; // Right Command
    default:   return AKUnknownKey;
  }
}

// The on-screen keyboard reports characters, not keys; recover the key a US layout would use.
unsigned short AKMacKeyCodeForCharacter(unichar c) {
  if (c >= 'A' && c <= 'Z') c = c - 'A' + 'a';
  if (c >= 'a' && c <= 'z') return AKMacKeyCodeForHIDUsage(0x04 + (c - 'a'));
  if (c >= '1' && c <= '9') return AKMacKeyCodeForHIDUsage(0x1E + (c - '1'));
  switch (c) {
    case '0': return 0x1D;
    case '\n': case '\r': return 0x24;
    case '\t': return 0x30;
    case ' ': return 0x31;
    case '-': case '_': return 0x1B;
    case '=': case '+': return 0x18;
    case '[': case '{': return 0x21;
    case ']': case '}': return 0x1E;
    case '\\': case '|': return 0x2A;
    case ';': case ':': return 0x29;
    case '\'': case '"': return 0x27;
    case '`': case '~': return 0x32;
    case ',': case '<': return 0x2B;
    case '.': case '>': return 0x2F;
    case '/': case '?': return 0x2C;
    default: return AKUnknownKey;
  }
}

static NSString *AKChar(unichar c) { return [NSString stringWithCharacters:&c length:1]; }

NSString *AKCharactersForMacKeyCode(unsigned short code) {
  switch (code) {
    case 0x24: case 0x4C: return @"\r";
    case 0x30: return @"\t";
    case 0x33: return AKChar(0x7F);
    case 0x35: return AKChar(0x1B);
    case 0x75: return AKChar(NSDeleteFunctionKey);
    case 0x73: return AKChar(NSHomeFunctionKey);
    case 0x77: return AKChar(NSEndFunctionKey);
    case 0x74: return AKChar(NSPageUpFunctionKey);
    case 0x79: return AKChar(NSPageDownFunctionKey);
    case 0x7B: return AKChar(NSLeftArrowFunctionKey);
    case 0x7C: return AKChar(NSRightArrowFunctionKey);
    case 0x7D: return AKChar(NSDownArrowFunctionKey);
    case 0x7E: return AKChar(NSUpArrowFunctionKey);
    default: break;
  }
  static const unsigned short fkeys[12] = { 0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F };
  for (int i = 0; i < 12; i++) if (fkeys[i] == code) return AKChar(NSF1FunctionKey + i);
  return nil;
}

NSEventModifierFlags AKModifierFlagForHIDUsage(long u) {
  switch (u) {
    case 0xE0: case 0xE4: return NSEventModifierFlagControl;
    case 0xE1: case 0xE5: return NSEventModifierFlagShift;
    case 0xE2: case 0xE6: return NSEventModifierFlagOption;
    case 0xE3: case 0xE7: return NSEventModifierFlagCommand;
    case 0x39:            return NSEventModifierFlagCapsLock;
    default:              return 0;
  }
}

// AppKit's standard key bindings for editing keys (the subset Chromium's text fields use).
SEL AKCommandSelectorForKeyEvent(NSEvent *event) {
  NSEventModifierFlags f = event.modifierFlags;
  BOOL shift = (f & NSEventModifierFlagShift) != 0;
  BOOL option = (f & NSEventModifierFlagOption) != 0;
  BOOL command = (f & NSEventModifierFlagCommand) != 0;
  switch (event.keyCode) {
    case 0x24: case 0x4C: return @selector(insertNewline:);
    case 0x30: return shift ? @selector(insertBacktab:) : @selector(insertTab:);
    case 0x33: return option ? @selector(deleteWordBackward:)
                    : command ? @selector(deleteToBeginningOfLine:) : @selector(deleteBackward:);
    case 0x75: return option ? @selector(deleteWordForward:) : @selector(deleteForward:);
    case 0x35: return @selector(cancelOperation:);
    case 0x7B:
      if (command) return shift ? @selector(moveToBeginningOfLineAndModifySelection:) : @selector(moveToBeginningOfLine:);
      if (option)  return shift ? @selector(moveWordLeftAndModifySelection:) : @selector(moveWordLeft:);
      return shift ? @selector(moveLeftAndModifySelection:) : @selector(moveLeft:);
    case 0x7C:
      if (command) return shift ? @selector(moveToEndOfLineAndModifySelection:) : @selector(moveToEndOfLine:);
      if (option)  return shift ? @selector(moveWordRightAndModifySelection:) : @selector(moveWordRight:);
      return shift ? @selector(moveRightAndModifySelection:) : @selector(moveRight:);
    case 0x7E:
      if (command) return shift ? @selector(moveToBeginningOfDocumentAndModifySelection:) : @selector(moveToBeginningOfDocument:);
      return shift ? @selector(moveUpAndModifySelection:) : @selector(moveUp:);
    case 0x7D:
      if (command) return shift ? @selector(moveToEndOfDocumentAndModifySelection:) : @selector(moveToEndOfDocument:);
      return shift ? @selector(moveDownAndModifySelection:) : @selector(moveDown:);
    case 0x73: return @selector(scrollToBeginningOfDocument:);
    case 0x77: return @selector(scrollToEndOfDocument:);
    case 0x74: return @selector(scrollPageUp:);
    case 0x79: return @selector(scrollPageDown:);
    default:   return NULL;
  }
}
