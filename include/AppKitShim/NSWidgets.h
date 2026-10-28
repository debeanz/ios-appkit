// The rest of AppKit's widget set. Steam draws its interface in Chromium, so these are
// mostly referenced rather than shown; each keeps a working model (values, selection, items)
// and the ones with an obvious iOS counterpart are backed by it (NSImageView -> UIImageView,
// NSScrollView -> UIScrollView).
#import "NSControls.h"
#import "NSViewController.h"
#import "NSMenu.h"

@class NSImage, NSTabViewItem, NSTableColumn, NSTouchBarItem;

#pragma mark Cells and buttons

@interface NSButtonCell : NSCell
@property (nonatomic) NSButtonType buttonType;
@end

@interface NSPopUpButtonCell : NSButtonCell
@property (nonatomic, strong) NSMenu *menu;
@property (nonatomic) BOOL pullsDown;
@end

@interface NSPopUpButton : NSButton
- (instancetype)initWithFrame:(NSRect)frame pullsDown:(BOOL)flag;
@property (nonatomic, strong) NSMenu *menu;
@property (nonatomic) BOOL pullsDown;
@property (nonatomic, readonly) NSInteger numberOfItems;
@property (nonatomic, readonly) NSInteger indexOfSelectedItem;
@property (nonatomic, readonly, strong) NSMenuItem *selectedItem;
@property (nonatomic, readonly, copy) NSString *titleOfSelectedItem;
@property (nonatomic, readonly, copy) NSArray<NSString *> *itemTitles;
- (void)addItemWithTitle:(NSString *)title;
- (void)addItemsWithTitles:(NSArray<NSString *> *)titles;
- (void)removeAllItems;
- (void)selectItemAtIndex:(NSInteger)index;
- (void)selectItemWithTitle:(NSString *)title;
- (BOOL)selectItemWithTag:(NSInteger)tag;
- (NSMenuItem *)itemAtIndex:(NSInteger)index;
@end

@interface NSComboBox : NSTextField
@property (nonatomic, readonly) NSInteger numberOfItems;
@property (nonatomic, readonly) NSInteger indexOfSelectedItem;
@property (nonatomic, readonly, copy) NSArray *objectValues;
@property (nonatomic) BOOL usesDataSource;
@property (nonatomic, weak) id dataSource;
- (void)addItemWithObjectValue:(id)object;
- (void)removeAllItems;
- (void)selectItemAtIndex:(NSInteger)index;
- (id)itemObjectValueAtIndex:(NSInteger)index;
@end

typedef NS_ENUM(NSUInteger, NSSegmentSwitchTracking) {
  NSSegmentSwitchTrackingSelectOne = 0, NSSegmentSwitchTrackingSelectAny = 1, NSSegmentSwitchTrackingMomentary = 2,
};

@interface NSSegmentedControl : NSControl
@property (nonatomic) NSInteger segmentCount;
@property (nonatomic) NSInteger selectedSegment;
@property (nonatomic) NSSegmentSwitchTracking trackingMode;
- (void)setLabel:(NSString *)label forSegment:(NSInteger)segment;
- (NSString *)labelForSegment:(NSInteger)segment;
- (void)setSelected:(BOOL)selected forSegment:(NSInteger)segment;
- (BOOL)isSelectedForSegment:(NSInteger)segment;
- (void)setEnabled:(BOOL)enabled forSegment:(NSInteger)segment;
- (BOOL)isEnabledForSegment:(NSInteger)segment;
@end

@interface NSMatrix : NSControl
- (instancetype)initWithFrame:(NSRect)frame mode:(NSInteger)mode cellClass:(Class)cellClass
                 numberOfRows:(NSInteger)rows numberOfColumns:(NSInteger)cols;
@property (nonatomic, readonly) NSInteger numberOfRows;
@property (nonatomic, readonly) NSInteger numberOfColumns;
@property (nonatomic, readonly, copy) NSArray<NSCell *> *cells;
- (NSCell *)cellAtRow:(NSInteger)row column:(NSInteger)col;
- (void)selectCellAtRow:(NSInteger)row column:(NSInteger)col;
@property (nonatomic, readonly, strong) NSCell *selectedCell;
@end

@interface NSPathControl : NSControl
@property (nonatomic, copy) NSURL *URL;
@property (nonatomic, weak) id delegate;
@end

#pragma mark Progress, images, boxes

typedef NS_ENUM(NSUInteger, NSProgressIndicatorStyle) {
  NSProgressIndicatorStyleBar = 0, NSProgressIndicatorStyleSpinning = 1,
};

@interface NSProgressIndicator : NSView
@property (nonatomic) double doubleValue;
@property (nonatomic) double minValue;
@property (nonatomic) double maxValue;
@property (nonatomic, getter=isIndeterminate) BOOL indeterminate;
@property (nonatomic) NSProgressIndicatorStyle style;
@property (nonatomic, getter=isDisplayedWhenStopped) BOOL displayedWhenStopped;
@property (nonatomic, readonly, getter=isAnimating) BOOL animating;
- (void)incrementBy:(double)delta;
- (void)startAnimation:(id)sender;
- (void)stopAnimation:(id)sender;
@end

@interface NSImageView : NSControl
@property (nonatomic, strong) NSImage *image;
@property (nonatomic) BOOL editable;
@property (nonatomic) BOOL animates;
@end

@interface NSBox : NSView
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) NSView *contentView;
@property (nonatomic) NSUInteger boxType;
@property (nonatomic) BOOL transparent;
@end

#pragma mark Scrolling

typedef NS_ENUM(NSInteger, NSScrollerStyle) { NSScrollerStyleLegacy = 0, NSScrollerStyleOverlay = 1 };

@interface NSScroller : NSControl
@property (class, readonly) NSScrollerStyle preferredScrollerStyle;
+ (CGFloat)scrollerWidthForControlSize:(NSInteger)controlSize scrollerStyle:(NSScrollerStyle)style;
@property (nonatomic) NSScrollerStyle scrollerStyle;
@property (nonatomic) CGFloat knobProportion;
@end

@interface NSScrollView : NSView
@property (nonatomic, strong) NSView *documentView;
@property (nonatomic) BOOL hasVerticalScroller;
@property (nonatomic) BOOL hasHorizontalScroller;
@property (nonatomic) BOOL autohidesScrollers;
@property (nonatomic) NSScrollerStyle scrollerStyle;
@property (nonatomic, readonly) NSRect documentVisibleRect;
@property (nonatomic, readonly) NSSize contentSize;
- (void)scrollToPoint:(NSPoint)point;
@end

#pragma mark Tabs and tables

@interface NSTabViewItem : NSObject
- (instancetype)initWithIdentifier:(id)identifier;
@property (nonatomic, strong) id identifier;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, strong) NSView *view;
@end

@interface NSTabView : NSView
@property (nonatomic, readonly, copy) NSArray<NSTabViewItem *> *tabViewItems;
@property (nonatomic, readonly, strong) NSTabViewItem *selectedTabViewItem;
@property (nonatomic, readonly) NSInteger numberOfTabViewItems;
@property (nonatomic, weak) id delegate;
- (void)addTabViewItem:(NSTabViewItem *)item;
- (void)removeTabViewItem:(NSTabViewItem *)item;
- (void)selectTabViewItem:(NSTabViewItem *)item;
- (void)selectTabViewItemAtIndex:(NSInteger)index;
- (NSInteger)indexOfTabViewItem:(NSTabViewItem *)item;
@end

@interface NSTableColumn : NSObject
- (instancetype)initWithIdentifier:(NSString *)identifier;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic) CGFloat width, minWidth, maxWidth;
@property (nonatomic, getter=isHidden) BOOL hidden;
@property (nonatomic, weak) id tableView;
@end

@interface NSTableView : NSControl
@property (nonatomic, weak) id dataSource;
@property (nonatomic, weak) id delegate;
@property (nonatomic, readonly, copy) NSArray<NSTableColumn *> *tableColumns;
@property (nonatomic, readonly) NSInteger numberOfRows;
@property (nonatomic, readonly) NSInteger numberOfColumns;
@property (nonatomic, readonly) NSInteger selectedRow;
@property (nonatomic, readonly, copy) NSIndexSet *selectedRowIndexes;
@property (nonatomic) BOOL allowsMultipleSelection;
@property (nonatomic) CGFloat rowHeight;
- (void)addTableColumn:(NSTableColumn *)column;
- (void)removeTableColumn:(NSTableColumn *)column;
- (NSTableColumn *)tableColumnWithIdentifier:(NSString *)identifier;
- (void)reloadData;
- (void)selectRowIndexes:(NSIndexSet *)indexes byExtendingSelection:(BOOL)extend;
- (void)deselectAll:(id)sender;
@end

#pragma mark Text

@interface NSText : NSView
@property (nonatomic, copy) NSString *string;
@property (nonatomic, strong) id font;
@property (nonatomic, strong) id textColor;
@property (nonatomic, getter=isEditable) BOOL editable;
@property (nonatomic, getter=isSelectable) BOOL selectable;
@property (nonatomic, getter=isRichText) BOOL richText;
@property (nonatomic) NSRange selectedRange;
@property (nonatomic, weak) id delegate;
- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)string;
- (void)selectAll:(id)sender;
@end

#pragma mark Window chrome, drag items, Touch Bar

// AppKit's private window-frame views. The client looks them up (Chromium subclasses the
// frame for custom title bars); here a window has no frame, so they are plain views.
@interface NSNextStepFrame : NSView
@end
@interface NSThemeFrame : NSNextStepFrame
@end

@interface NSTitlebarAccessoryViewController : NSViewController
@property (nonatomic) NSInteger layoutAttribute;
@property (nonatomic) CGFloat fullScreenMinHeight;
@property (nonatomic, getter=isHidden) BOOL hidden;
@end

@interface NSDraggingItem : NSObject
- (instancetype)initWithPasteboardWriter:(id)pasteboardWriter;
@property (nonatomic, readonly, strong) id item;
@property (nonatomic) NSRect draggingFrame;
- (void)setDraggingFrame:(NSRect)frame contents:(id)contents;
@end

// No Touch Bar on iOS; the objects exist so code that builds one runs unchanged.
@interface NSTouchBar : NSObject
@property (nonatomic, copy) NSArray<NSString *> *defaultItemIdentifiers;
@property (nonatomic, copy) NSString *customizationIdentifier;
@property (nonatomic, weak) id delegate;
@property (nonatomic, readonly, getter=isVisible) BOOL visible;
@end

@interface NSTouchBarItem : NSObject
- (instancetype)initWithIdentifier:(NSString *)identifier;
@property (nonatomic, readonly, copy) NSString *identifier;
@end
@interface NSCustomTouchBarItem : NSTouchBarItem
@property (nonatomic, strong) NSView *view;
@end
@interface NSGroupTouchBarItem : NSTouchBarItem
+ (instancetype)groupItemWithIdentifier:(NSString *)identifier items:(NSArray<NSTouchBarItem *> *)items;
@property (nonatomic, strong) NSTouchBar *groupTouchBar;
@end
@interface NSCandidateListTouchBarItem : NSTouchBarItem
@property (nonatomic, weak) id client;
- (void)setCandidates:(NSArray *)candidates forSelectedRange:(NSRange)range inString:(NSString *)string;
@end

#pragma mark Accessibility elements

@interface NSAccessibilityElement : NSObject
+ (instancetype)accessibilityElementWithRole:(NSString *)role frame:(NSRect)frame label:(NSString *)label parent:(id)parent;
@property (nonatomic, copy) NSString *accessibilityRole;
@property (nonatomic, copy) NSString *accessibilityLabel;
@property (nonatomic) NSRect accessibilityFrame;
@property (nonatomic, weak) id accessibilityParent;
@property (nonatomic, copy) NSArray *accessibilityChildren;
@end

// Cross-process accessibility (a helper process's elements shown in the host's tree).
// iOS apps can't expose elements across processes, so there is never a token.
@interface NSAccessibilityRemoteUIElement : NSObject
+ (BOOL)registerRemoteUIProcessIdentifier:(int)pid;
+ (NSData *)remoteTokenForLocalUIElement:(id)element;
- (instancetype)initWithRemoteToken:(NSData *)token;
@end

#pragma mark OpenGL

// Desktop OpenGL for the Mac games Steam starts, over AKOpenGL.framework (Mesa's OpenGL with
// Zink on MoltenVK; NSOpenGL.m). Outside a game the initialisers return nil, as AppKit does
// when no format matches, and callers fall back (Steam's own interface never draws with GL).
@interface NSOpenGLPixelFormat : NSObject
- (instancetype)initWithAttributes:(const uint32_t *)attribs;
- (instancetype)initWithCGLPixelFormatObj:(void *)pix;
- (void *)CGLPixelFormatObj;
- (void)getValues:(int32_t *)vals forAttribute:(uint32_t)attrib forVirtualScreen:(int32_t)screen;
@property (nonatomic, readonly) int32_t numberOfVirtualScreens;
@end

@interface NSOpenGLContext : NSObject
+ (NSOpenGLContext *)currentContext;
+ (void)clearCurrentContext;
- (instancetype)initWithFormat:(NSOpenGLPixelFormat *)format shareContext:(NSOpenGLContext *)share;
- (instancetype)initWithCGLContextObj:(void *)ctx;
- (void *)CGLContextObj;
@property (nonatomic, readonly) NSOpenGLPixelFormat *pixelFormat;
@property (nonatomic, weak) NSView *view;
- (void)makeCurrentContext;
- (void)flushBuffer;
- (void)update;
- (void)clearDrawable;
- (void)setValues:(const int32_t *)vals forParameter:(NSInteger)param;
- (void)getValues:(int32_t *)vals forParameter:(NSInteger)param;
@end

@interface NSOpenGLView : NSView
+ (NSOpenGLPixelFormat *)defaultPixelFormat;
- (instancetype)initWithFrame:(NSRect)frame pixelFormat:(NSOpenGLPixelFormat *)format;
@property (nonatomic, strong) NSOpenGLPixelFormat *pixelFormat;
@property (nonatomic, strong) NSOpenGLContext *openGLContext;
- (void)prepareOpenGL;
- (void)reshape;
- (void)update;
- (void)clearGLContext;
@end
