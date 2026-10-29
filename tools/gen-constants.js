#!/usr/bin/env node
// Generates src/AppKitConstants.m and include/AppKitShim/AppKitConstants.h: the AppKit string
// and number constants the client imports that iOS lacks and no other shim file defines yet.
// Values are AppKit's own (accessibility names follow its fixed "AX..." scheme).
//
//   node tools/gen-constants.js
'use strict';
const fs = require('fs');

// Accessibility: NSAccessibility<Name><Kind> -> "AX<Name>", with a few irregular ones.
const AX_KINDS = ['ParameterizedAttribute', 'TextAttribute', 'Attribute', 'Subrole', 'Role', 'Action', 'Notification', 'Value'];
const AX_FUNCTIONS = new Set(['NSAccessibilityPostNotification', 'NSAccessibilityPostNotificationWithUserInfo',
  'NSAccessibilityActionDescription', 'NSAccessibilityRoleDescription', 'NSAccessibilityUnignoredAncestor',
  'NSAccessibilityUnignoredChildren']);
const AX_EXCEPTIONS = {
  NSAccessibilityAnnouncementKey: 'AXAnnouncementKey',
  NSAccessibilityPriorityKey: 'AXPriorityKey',
  NSAccessibilityFontSizeKey: 'AXFontSize',
  NSAccessibilityFontFamilyKey: 'AXFontFamily',
};
function axValue(name) {
  if (AX_EXCEPTIONS[name]) return AX_EXCEPTIONS[name];
  let base = name.slice('NSAccessibility'.length);
  for (const k of AX_KINDS) if (base.endsWith(k)) { base = base.slice(0, -k.length); break; }
  return 'AX' + base;
}

const STRINGS = {
  NSAppearanceNameAqua: 'NSAppearanceNameAqua',
  NSAppearanceNameDarkAqua: 'NSAppearanceNameDarkAqua',
  NSAppearanceNameAccessibilityHighContrastAqua: 'NSAppearanceNameAccessibilityHighContrastAqua',
  NSAppearanceNameAccessibilityHighContrastDarkAqua: 'NSAppearanceNameAccessibilityHighContrastDarkAqua',
  NSCalibratedRGBColorSpace: 'NSCalibratedRGBColorSpace',
  NSDeviceRGBColorSpace: 'NSDeviceRGBColorSpace',
  NSImageNameApplicationIcon: 'NSApplicationIcon',
  NSImageNameFolder: 'NSFolder',
  NSFilenamesPboardType: 'NSFilenamesPboardType',
  NSStringPboardType: 'NSStringPboardType',
  NSDisplayNameBindingOption: 'NSDisplayName',
  NSDisplayPatternBindingOption: 'NSDisplayPattern',
  NSMultipleValuesPlaceholderBindingOption: 'NSMultipleValuesPlaceholder',
  NSNoSelectionPlaceholderBindingOption: 'NSNoSelectionPlaceholder',
  NSNotApplicablePlaceholderBindingOption: 'NSNotApplicablePlaceholder',
  NSNullPlaceholderBindingOption: 'NSNullPlaceholder',
  NSObservedKeyPathKey: 'NSObservedKeyPath',
  NSObservedObjectKey: 'NSObservedObject',
  NSOptionsKey: 'NSOptions',
  NSTouchBarItemIdentifierCandidateList: 'NSTouchBarItemIdentifierCandidateList',
  NSTouchBarItemIdentifierCharacterPicker: 'NSTouchBarItemIdentifierCharacterPicker',
  NSTouchBarItemIdentifierFlexibleSpace: 'NSTouchBarItemIdentifierFlexibleSpace',
  NSSharingServiceNameAddToSafariReadingList: 'com.apple.share.System.add-to-safari-reading-list',
  NSSharingServiceNameComposeEmail: 'com.apple.share.Mail.compose',
  NSPrintAllPages: 'NSPrintAllPages',
  NSPrintFirstPage: 'NSPrintFirstPage',
  NSPrintLastPage: 'NSPrintLastPage',
  NSApplicationLaunchUserNotificationKey: 'NSApplicationLaunchUserNotificationKey',
  NSFontNameAttribute: 'NSFontNameAttribute',
  NSFontTraitsAttribute: 'NSCTFontTraitsAttribute',
  NSFontSymbolicTrait: 'NSCTFontSymbolicTrait',
  NSImageHintCTM: 'NSImageHintCTM',
  NSModalPanelRunLoopMode: 'NSModalPanelRunLoopMode',
};

// Names games import beyond the client's (Unity's player, Godot; tools/engine-gaps.js finds them).
const GAME_AX = [
  'NSAccessibilitySearchFieldSubrole', 'NSAccessibilityTabButtonSubrole', 'NSAccessibilityUIElementsKey',
  'NSAccessibilityUnknownSubrole', 'NSAccessibilityDialogSubrole', 'NSAccessibilityFontFamilyKey',
  'NSAccessibilityLanguageTextAttribute', 'NSAccessibilityStrikethroughColorTextAttribute', 'NSAccessibilitySwitchSubrole',
  'NSAccessibilityTableRowSubrole', 'NSAccessibilityTextAlignmentAttribute', 'NSAccessibilityToggleSubrole',
  'NSAccessibilityUnderlineColorTextAttribute', 'NSAccessibilityWindowRole',
];
const GAME_STRINGS = ['NSModalPanelRunLoopMode'];

// Notification names are their own identifiers.
const NOTIFICATIONS = [
  'NSApplicationDidBecomeActiveNotification', 'NSApplicationDidFinishLaunchingNotification',
  'NSApplicationDidHideNotification', 'NSApplicationDidResignActiveNotification',
  'NSApplicationWillBecomeActiveNotification', 'NSApplicationWillTerminateNotification',
  'NSPreferredScrollerStyleDidChangeNotification', 'NSSystemColorsDidChangeNotification',
  'NSWindowDidBecomeMainNotification', 'NSWindowDidChangeOcclusionStateNotification',
  'NSWindowDidDeminiaturizeNotification', 'NSWindowDidEndLiveResizeNotification',
  'NSWindowDidExposeNotification', 'NSWindowDidMiniaturizeNotification', 'NSWindowDidMoveNotification',
  'NSWindowDidResignMainNotification', 'NSWindowDidResizeNotification', 'NSWindowWillCloseNotification',
  'NSWindowWillMiniaturizeNotification', 'NSWindowWillMoveNotification', 'NSWindowWillStartLiveResizeNotification',
];

// NSFontWeight values match UIFontWeight's.
const FONT_WEIGHTS = {
  NSFontWeightUltraLight: -0.8, NSFontWeightThin: -0.6, NSFontWeightLight: -0.4, NSFontWeightRegular: 0,
  NSFontWeightMedium: 0.23, NSFontWeightSemibold: 0.3, NSFontWeightBold: 0.4, NSFontWeightHeavy: 0.56,
  NSFontWeightBlack: 0.62,
};

function main() {
  const gap = JSON.parse(fs.readFileSync('data/ios-gap.json', 'utf8')).libraries;
  const runtime = new Set();
  if (fs.existsSync('data/runtime-gap.json'))
    for (const l of Object.values(JSON.parse(fs.readFileSync('data/runtime-gap.json', 'utf8')).libraries))
      for (const s of l.presentAtRuntime) runtime.add(s.replace(/^_/, ''));
  const appkit = Object.values(gap).find(l => l.framework === 'AppKit').missing.map(s => s.replace(/^_/, ''));
  const ax = [...new Set([...appkit, ...GAME_AX])].filter(s => s.startsWith('NSAccessibility') && !AX_FUNCTIONS.has(s) && !runtime.has(s));

  const strings = [
    ...ax.map(n => [n, axValue(n)]),
    ...Object.entries(STRINGS),
    ...NOTIFICATIONS.map(n => [n, n]),
  ];
  // Only what the client (or a game, above) actually imports, so the file can't drift into defining extras.
  const wanted = new Set([...appkit, ...GAME_AX, ...GAME_STRINGS]);
  const kept = strings.filter(([n]) => wanted.has(n));

  let m = '// Generated by tools/gen-constants.js. Do not edit by hand.\n';
  m += '// AppKit constants the client and games import that iOS lacks. Values are AppKit\'s own.\n';
  m += '#import <Foundation/Foundation.h>\n#import <CoreGraphics/CoreGraphics.h>\n\n';
  for (const [n, v] of kept) m += `NSString *const ${n} = @"${v}";\n`;
  m += '\n// NSFontWeight values, the same as UIFontWeight\'s.\n';
  for (const [n, v] of Object.entries(FONT_WEIGHTS)) if (wanted.has(n)) m += `const CGFloat ${n} = ${v};\n`;
  m += '\n// The identity text matrix {a, b, c, d, tx, ty}.\n';
  m += 'static const CGFloat AKFontIdentityMatrix[6] = { 1, 0, 0, 1, 0, 0 };\n';
  m += 'const CGFloat *NSFontIdentityMatrix = AKFontIdentityMatrix;\n';

  let h = '// Generated by tools/gen-constants.js. Do not edit by hand.\n#import <Foundation/Foundation.h>\n#import <CoreGraphics/CoreGraphics.h>\n\n';
  for (const [n] of kept) h += `extern NSString *const ${n};\n`;
  for (const n of Object.keys(FONT_WEIGHTS)) if (wanted.has(n)) h += `extern const CGFloat ${n};\n`;
  h += 'extern const CGFloat *NSFontIdentityMatrix;\n';

  fs.writeFileSync('src/AppKitConstants.m', m);
  fs.writeFileSync('include/AppKitShim/AppKitConstants.h', h);
  const fw = Object.keys(FONT_WEIGHTS).filter(n => wanted.has(n)).length;
  console.log(`wrote ${kept.length} string constants, ${fw} font weights, NSFontIdentityMatrix`);
  console.log(JSON.stringify(kept.map(([n]) => n).concat(Object.keys(FONT_WEIGHTS).filter(n => wanted.has(n)), ['NSFontIdentityMatrix'])));
}
main();
