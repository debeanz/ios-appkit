#import "AKShimPrivate.h"
#import "AppKitShim/NSWidgets.h"
#import "AppKitShim/NSGraphics.h"

#pragma mark Cells and buttons

@implementation NSButtonCell
@end

@implementation NSPopUpButtonCell
@end

@implementation NSPopUpButton {
  NSInteger _selected;
}

- (instancetype)initWithFrame:(NSRect)frame { return [self initWithFrame:frame pullsDown:NO]; }

- (instancetype)initWithFrame:(NSRect)frame pullsDown:(BOOL)flag {
  if ((self = [super initWithFrame:frame])) {
    _menu = [[NSMenu alloc] initWithTitle:@""];
    _pullsDown = flag;
    _selected = -1;
  }
  return self;
}

- (NSInteger)numberOfItems { return _menu.numberOfItems; }
- (NSInteger)indexOfSelectedItem { return _selected < self.numberOfItems ? _selected : -1; }
- (NSMenuItem *)selectedItem { return [_menu itemAtIndex:self.indexOfSelectedItem]; }
- (NSString *)titleOfSelectedItem { return self.selectedItem.title; }
- (NSMenuItem *)itemAtIndex:(NSInteger)index { return [_menu itemAtIndex:index]; }

- (NSArray<NSString *> *)itemTitles {
  NSMutableArray *titles = [NSMutableArray array];
  for (NSMenuItem *item in _menu.itemArray) [titles addObject:item.title];
  return titles;
}

// The first item added becomes the selection, as with AppKit's pop-up buttons.
- (void)addItemWithTitle:(NSString *)title {
  [_menu addItemWithTitle:title ?: @"" action:NULL keyEquivalent:@""];
  if (_selected < 0) [self selectItemAtIndex:0];
}

- (void)addItemsWithTitles:(NSArray<NSString *> *)titles { for (NSString *t in titles) [self addItemWithTitle:t]; }

- (void)removeAllItems {
  [_menu removeAllItems];
  _selected = -1;
}

- (void)selectItemAtIndex:(NSInteger)index {
  _selected = (index >= 0 && index < self.numberOfItems) ? index : -1;
  for (NSInteger i = 0; i < self.numberOfItems; i++)
    [_menu itemAtIndex:i].state = (i == _selected) ? NSControlStateValueOn : NSControlStateValueOff;
  if (!_pullsDown) self.title = self.titleOfSelectedItem ?: @"";
}

- (void)selectItemWithTitle:(NSString *)title {
  NSMenuItem *item = [_menu itemWithTitle:title];
  [self selectItemAtIndex:item ? [_menu indexOfItem:item] : -1];
}

- (BOOL)selectItemWithTag:(NSInteger)tag {
  NSMenuItem *item = [_menu itemWithTag:tag];
  if (!item) return NO;
  [self selectItemAtIndex:[_menu indexOfItem:item]];
  return YES;
}

@end

@implementation NSComboBox {
  NSMutableArray *_items;
  NSInteger _selected;
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) { _items = [NSMutableArray array]; _selected = -1; self.editable = YES; }
  return self;
}

- (NSInteger)numberOfItems { return (NSInteger)_items.count; }
- (NSInteger)indexOfSelectedItem { return _selected; }
- (NSArray *)objectValues { return [_items copy]; }
- (void)addItemWithObjectValue:(id)object { if (object) [_items addObject:object]; }
- (void)removeAllItems { [_items removeAllObjects]; _selected = -1; }
- (id)itemObjectValueAtIndex:(NSInteger)index { return (index >= 0 && index < self.numberOfItems) ? _items[(NSUInteger)index] : nil; }

- (void)selectItemAtIndex:(NSInteger)index {
  id value = [self itemObjectValueAtIndex:index];
  _selected = value ? index : -1;
  if (value) self.stringValue = [value description];
}

@end

@implementation NSSegmentedControl {
  NSMutableArray<NSString *> *_labels;
  NSMutableArray<NSNumber *> *_selected, *_enabled;
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _labels = [NSMutableArray array]; _selected = [NSMutableArray array]; _enabled = [NSMutableArray array];
  }
  return self;
}

- (void)setSegmentCount:(NSInteger)count {
  _segmentCount = MAX(0, count);
  while ((NSInteger)_labels.count < _segmentCount) { [_labels addObject:@""]; [_selected addObject:@NO]; [_enabled addObject:@YES]; }
  while ((NSInteger)_labels.count > _segmentCount) { [_labels removeLastObject]; [_selected removeLastObject]; [_enabled removeLastObject]; }
}

- (BOOL)_valid:(NSInteger)s { return s >= 0 && s < _segmentCount; }

- (void)setLabel:(NSString *)label forSegment:(NSInteger)s { if ([self _valid:s]) _labels[(NSUInteger)s] = label ?: @""; }
- (NSString *)labelForSegment:(NSInteger)s { return [self _valid:s] ? _labels[(NSUInteger)s] : nil; }
- (void)setEnabled:(BOOL)e forSegment:(NSInteger)s { if ([self _valid:s]) _enabled[(NSUInteger)s] = @(e); }
- (BOOL)isEnabledForSegment:(NSInteger)s { return [self _valid:s] && _enabled[(NSUInteger)s].boolValue; }
- (BOOL)isSelectedForSegment:(NSInteger)s { return [self _valid:s] && _selected[(NSUInteger)s].boolValue; }

// In select-one mode choosing a segment clears the others.
- (void)setSelected:(BOOL)sel forSegment:(NSInteger)s {
  if (![self _valid:s]) return;
  if (sel && _trackingMode == NSSegmentSwitchTrackingSelectOne)
    for (NSUInteger i = 0; i < _selected.count; i++) _selected[i] = @NO;
  _selected[(NSUInteger)s] = @(sel);
}

- (NSInteger)selectedSegment {
  for (NSUInteger i = 0; i < _selected.count; i++) if (_selected[i].boolValue) return (NSInteger)i;
  return -1;
}

- (void)setSelectedSegment:(NSInteger)s {
  for (NSUInteger i = 0; i < _selected.count; i++) _selected[i] = @NO;
  if ([self _valid:s]) _selected[(NSUInteger)s] = @YES;
}

@end

@implementation NSMatrix {
  NSMutableArray<NSCell *> *_cells;
  NSInteger _selectedIndex;
}

- (instancetype)initWithFrame:(NSRect)frame mode:(NSInteger)mode cellClass:(Class)cellClass
                 numberOfRows:(NSInteger)rows numberOfColumns:(NSInteger)cols {
  if ((self = [super initWithFrame:frame])) {
    _numberOfRows = MAX(0, rows);
    _numberOfColumns = MAX(0, cols);
    _cells = [NSMutableArray array];
    Class cls = [cellClass isSubclassOfClass:NSCell.class] ? cellClass : NSCell.class;
    for (NSInteger i = 0; i < _numberOfRows * _numberOfColumns; i++) [_cells addObject:[cls new]];
    _selectedIndex = -1;
  }
  return self;
}

- (NSArray<NSCell *> *)cells { return [_cells copy]; }

- (NSCell *)cellAtRow:(NSInteger)row column:(NSInteger)col {
  if (row < 0 || col < 0 || row >= _numberOfRows || col >= _numberOfColumns) return nil;
  return _cells[(NSUInteger)(row * _numberOfColumns + col)];
}

- (void)selectCellAtRow:(NSInteger)row column:(NSInteger)col {
  NSCell *cell = [self cellAtRow:row column:col];
  _selectedIndex = cell ? row * _numberOfColumns + col : -1;
}

- (NSCell *)selectedCell { return _selectedIndex >= 0 ? _cells[(NSUInteger)_selectedIndex] : nil; }

@end

@implementation NSPathControl
@end

#pragma mark Progress, images, boxes

@implementation NSProgressIndicator

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) { _maxValue = 100; _indeterminate = YES; _displayedWhenStopped = YES; }
  return self;
}

- (void)setDoubleValue:(double)v { _doubleValue = MAX(_minValue, MIN(_maxValue, v)); }
- (void)incrementBy:(double)delta { self.doubleValue = _doubleValue + delta; }
- (void)startAnimation:(id)sender { _animating = YES; }
- (void)stopAnimation:(id)sender { _animating = NO; }

@end

@implementation NSImageView {
  UIImageView *_imageView;
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _imageView = [[UIImageView alloc] initWithFrame:self.backingView.bounds];
    _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    [self.backingView addSubview:_imageView];
  }
  return self;
}

- (void)setImage:(NSImage *)image {
  _image = image;
  CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
  _imageView.image = cg ? [UIImage imageWithCGImage:cg scale:UIScreen.mainScreen.scale orientation:UIImageOrientationUp] : nil;
}

@end

@implementation NSBox

- (void)setContentView:(NSView *)contentView {
  [_contentView removeFromSuperview];
  _contentView = contentView;
  if (!contentView) return;
  contentView.frame = self.bounds;
  contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [self addSubview:contentView];
}

@end

#pragma mark Scrolling

@implementation NSScroller

// iOS scroll indicators overlay the content, like macOS's overlay scrollers.
+ (NSScrollerStyle)preferredScrollerStyle { return NSScrollerStyleOverlay; }

+ (CGFloat)scrollerWidthForControlSize:(NSInteger)controlSize scrollerStyle:(NSScrollerStyle)style {
  return style == NSScrollerStyleOverlay ? 0 : 15;
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) _scrollerStyle = NSScrollerStyleOverlay;
  return self;
}

@end

@implementation NSScrollView {
  UIScrollView *_scroll;
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _scroll = [[UIScrollView alloc] initWithFrame:self.backingView.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.backingView addSubview:_scroll];
    _scrollerStyle = NSScrollerStyleOverlay;
    self.hasVerticalScroller = YES;
  }
  return self;
}

// The document view stays an NSView subview (so it finds its window and responder chain),
// but its backing view lives inside the UIScrollView, which does the actual scrolling.
- (void)setDocumentView:(NSView *)documentView {
  [_documentView removeFromSuperview];
  _documentView = documentView;
  if (!documentView) { _scroll.contentSize = CGSizeZero; return; }
  [self addSubview:documentView];
  [_scroll addSubview:documentView.backingView];
  _scroll.contentSize = documentView.frame.size;
}

- (void)setHasVerticalScroller:(BOOL)flag { _hasVerticalScroller = flag; _scroll.showsVerticalScrollIndicator = flag; }
- (void)setHasHorizontalScroller:(BOOL)flag { _hasHorizontalScroller = flag; _scroll.showsHorizontalScrollIndicator = flag; }

- (NSSize)contentSize { return _scroll.bounds.size; }

- (NSRect)documentVisibleRect {
  _scroll.contentSize = _documentView.frame.size; // follow document resizes
  return (NSRect){ _scroll.contentOffset, _scroll.bounds.size };
}

- (void)scrollToPoint:(NSPoint)point {
  _scroll.contentSize = _documentView.frame.size;
  CGFloat maxX = MAX(0, _scroll.contentSize.width - _scroll.bounds.size.width);
  CGFloat maxY = MAX(0, _scroll.contentSize.height - _scroll.bounds.size.height);
  [_scroll setContentOffset:CGPointMake(MAX(0, MIN(maxX, point.x)), MAX(0, MIN(maxY, point.y))) animated:NO];
}

@end

#pragma mark Tabs and tables

@implementation NSTabViewItem
- (instancetype)init { return [self initWithIdentifier:nil]; }
- (instancetype)initWithIdentifier:(id)identifier {
  if ((self = [super init])) { _identifier = identifier; _label = @""; }
  return self;
}
@end

@implementation NSTabView {
  NSMutableArray<NSTabViewItem *> *_items;
  NSTabViewItem *_selected;
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) _items = [NSMutableArray array];
  return self;
}

- (NSArray<NSTabViewItem *> *)tabViewItems { return [_items copy]; }
- (NSInteger)numberOfTabViewItems { return (NSInteger)_items.count; }
- (NSTabViewItem *)selectedTabViewItem { return _selected; }

- (NSInteger)indexOfTabViewItem:(NSTabViewItem *)item {
  NSUInteger i = [_items indexOfObjectIdenticalTo:item];
  return i == NSNotFound ? -1 : (NSInteger)i;
}

- (void)addTabViewItem:(NSTabViewItem *)item {
  if (!item) return;
  [_items addObject:item];
  if (!_selected) [self selectTabViewItem:item];
}

- (void)removeTabViewItem:(NSTabViewItem *)item {
  [_items removeObjectIdenticalTo:item];
  if (_selected == item) {
    [item.view removeFromSuperview];
    _selected = nil;
    if (_items.count) [self selectTabViewItem:_items.firstObject];
  }
}

// Only the selected tab's view is in the view tree.
- (void)selectTabViewItem:(NSTabViewItem *)item {
  if (!item || [self indexOfTabViewItem:item] < 0 || item == _selected) return;
  [_selected.view removeFromSuperview];
  _selected = item;
  if (item.view) {
    item.view.frame = self.bounds;
    item.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:item.view];
  }
}

- (void)selectTabViewItemAtIndex:(NSInteger)index {
  if (index >= 0 && index < (NSInteger)_items.count) [self selectTabViewItem:_items[(NSUInteger)index]];
}

@end

@implementation NSTableColumn
- (instancetype)init { return [self initWithIdentifier:@""]; }
- (instancetype)initWithIdentifier:(NSString *)identifier {
  if ((self = [super init])) { _identifier = [identifier copy]; _title = @""; _width = 100; _minWidth = 10; _maxWidth = 1000; }
  return self;
}
@end

@implementation NSTableView {
  NSMutableArray<NSTableColumn *> *_columns;
  NSMutableIndexSet *_selection;
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _columns = [NSMutableArray array];
    _selection = [NSMutableIndexSet indexSet];
    _rowHeight = 17;
  }
  return self;
}

- (NSArray<NSTableColumn *> *)tableColumns { return [_columns copy]; }
- (NSInteger)numberOfColumns { return (NSInteger)_columns.count; }

- (void)addTableColumn:(NSTableColumn *)column {
  if (!column) return;
  column.tableView = self;
  [_columns addObject:column];
}

- (void)removeTableColumn:(NSTableColumn *)column { [_columns removeObjectIdenticalTo:column]; }

- (NSTableColumn *)tableColumnWithIdentifier:(NSString *)identifier {
  for (NSTableColumn *c in _columns) if ([c.identifier isEqualToString:identifier]) return c;
  return nil;
}

// Row count comes from the data source, as in AppKit.
- (NSInteger)numberOfRows {
  id ds = self.dataSource;
  SEL sel = NSSelectorFromString(@"numberOfRowsInTableView:");
  if (![ds respondsToSelector:sel]) return 0;
  return ((NSInteger (*)(id, SEL, id))[ds methodForSelector:sel])(ds, sel, self);
}

// Rows that no longer exist drop out of the selection.
- (void)reloadData {
  NSUInteger rows = (NSUInteger)MAX(0, self.numberOfRows);
  [_selection removeIndexesInRange:NSMakeRange(rows, (NSUInteger)NSIntegerMax - rows)];
}

- (NSIndexSet *)selectedRowIndexes { return [_selection copy]; }
- (NSInteger)selectedRow { return _selection.count ? (NSInteger)_selection.lastIndex : -1; }

- (void)selectRowIndexes:(NSIndexSet *)indexes byExtendingSelection:(BOOL)extend {
  if (!extend || !_allowsMultipleSelection) [_selection removeAllIndexes];
  NSInteger rows = self.numberOfRows;
  [indexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) { if ((NSInteger)i < rows) [self->_selection addIndex:i]; }];
  if (!_allowsMultipleSelection && _selection.count > 1) {
    NSUInteger last = _selection.lastIndex;
    [_selection removeAllIndexes];
    [_selection addIndex:last];
  }
}

- (void)deselectAll:(id)sender { [_selection removeAllIndexes]; }

@end

#pragma mark Text

@implementation NSText {
  NSMutableString *_text;
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) { _text = [NSMutableString string]; _editable = YES; _selectable = YES; }
  return self;
}

- (NSString *)string { return [_text copy]; }

- (void)setString:(NSString *)string {
  [_text setString:string ?: @""];
  _selectedRange = NSMakeRange(_text.length, 0);
}

- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)string {
  if (NSMaxRange(range) > _text.length) return;
  [_text replaceCharactersInRange:range withString:string ?: @""];
  _selectedRange = NSMakeRange(range.location + string.length, 0);
}

- (void)selectAll:(id)sender { _selectedRange = NSMakeRange(0, _text.length); }

@end

#pragma mark Window chrome, drag items, Touch Bar

@implementation NSNextStepFrame
@end
@implementation NSThemeFrame
@end
@implementation NSTitlebarAccessoryViewController
@end

@implementation NSDraggingItem
- (instancetype)initWithPasteboardWriter:(id)pasteboardWriter {
  if ((self = [super init])) _item = pasteboardWriter;
  return self;
}
- (void)setDraggingFrame:(NSRect)frame contents:(id)contents { _draggingFrame = frame; }
@end

@implementation NSTouchBar
- (BOOL)isVisible { return NO; }
@end

@implementation NSTouchBarItem
- (instancetype)init { return [self initWithIdentifier:@""]; }
- (instancetype)initWithIdentifier:(NSString *)identifier {
  if ((self = [super init])) _identifier = [identifier copy];
  return self;
}
@end

@implementation NSCustomTouchBarItem
@end

@implementation NSGroupTouchBarItem
+ (instancetype)groupItemWithIdentifier:(NSString *)identifier items:(NSArray<NSTouchBarItem *> *)items {
  NSGroupTouchBarItem *g = [[self alloc] initWithIdentifier:identifier];
  g.groupTouchBar = [NSTouchBar new];
  NSMutableArray *ids = [NSMutableArray array];
  for (NSTouchBarItem *i in items) [ids addObject:i.identifier];
  g.groupTouchBar.defaultItemIdentifiers = ids;
  return g;
}
@end

@implementation NSCandidateListTouchBarItem
- (void)setCandidates:(NSArray *)candidates forSelectedRange:(NSRange)range inString:(NSString *)string {}
@end

#pragma mark Accessibility elements

@implementation NSAccessibilityElement
+ (instancetype)accessibilityElementWithRole:(NSString *)role frame:(NSRect)frame label:(NSString *)label parent:(id)parent {
  NSAccessibilityElement *e = [self new];
  e.accessibilityRole = role;
  e.accessibilityFrame = frame;
  e.accessibilityLabel = label;
  e.accessibilityParent = parent;
  return e;
}
@end

@implementation NSAccessibilityRemoteUIElement
+ (BOOL)registerRemoteUIProcessIdentifier:(int)pid { return NO; }
+ (NSData *)remoteTokenForLocalUIElement:(id)element { return nil; }
- (instancetype)initWithRemoteToken:(NSData *)token { return nil; }
@end

#pragma mark OpenGL

@implementation NSOpenGLPixelFormat
- (instancetype)initWithAttributes:(const uint32_t *)attribs { return nil; }
@end

@implementation NSOpenGLContext
+ (NSOpenGLContext *)currentContext { return nil; }
+ (void)clearCurrentContext {}
- (instancetype)initWithFormat:(NSOpenGLPixelFormat *)format shareContext:(NSOpenGLContext *)share { return nil; }
- (void)makeCurrentContext {}
- (void)flushBuffer {}
@end

@implementation NSOpenGLView
@end
