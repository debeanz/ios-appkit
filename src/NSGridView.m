// NSGridView over frames. See NSGridView.h.
#import "AKShimPrivate.h"
#import "AppKitShim/NSGridView.h"

const CGFloat NSGridViewSizeForContent = 10000;

@interface NSGridView ()
- (void)akLayoutCells;
@end

@implementation NSGridCell

+ (NSView *)emptyContentView {
  static NSView *empty;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ empty = [[NSView alloc] initWithFrame:NSZeroRect]; });
  return empty;
}

@end

@interface NSGridRow ()
@property (nonatomic, weak) NSGridView *gridView;
@end

@interface NSGridColumn ()
@property (nonatomic, weak) NSGridView *gridView;
@end

@implementation NSGridView {
  NSMutableArray<NSGridRow *> *_rows;
  NSMutableArray<NSGridColumn *> *_columns;
  NSMutableArray<NSMutableArray<NSGridCell *> *> *_cells;   // [row][column]
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _rows = [NSMutableArray array];
    _columns = [NSMutableArray array];
    _cells = [NSMutableArray array];
    _xPlacement = NSGridCellPlacementLeading;
    _yPlacement = NSGridCellPlacementCenter;
    _rowSpacing = 6;
    _columnSpacing = 6;
  }
  return self;
}

+ (instancetype)gridViewWithNumberOfColumns:(NSInteger)columnCount rows:(NSInteger)rowCount {
  NSGridView *grid = [[self alloc] initWithFrame:NSZeroRect];
  for (NSInteger r = 0; r < rowCount; r++) [grid addRowWithViews:@[]];
  while (grid.numberOfColumns < columnCount) [grid addColumnWithViews:@[]];
  return grid;
}

+ (instancetype)gridViewWithViews:(NSArray<NSArray<NSView *> *> *)rows {
  NSGridView *grid = [[self alloc] initWithFrame:NSZeroRect];
  for (NSArray<NSView *> *row in rows) [grid addRowWithViews:row];
  return grid;
}

- (NSInteger)numberOfRows { return (NSInteger)_rows.count; }
- (NSInteger)numberOfColumns { return (NSInteger)_columns.count; }
- (NSGridRow *)rowAtIndex:(NSInteger)index { return _rows[(NSUInteger)index]; }
- (NSInteger)indexOfRow:(NSGridRow *)row { NSUInteger i = [_rows indexOfObjectIdenticalTo:row]; return i == NSNotFound ? -1 : (NSInteger)i; }
- (NSGridColumn *)columnAtIndex:(NSInteger)index { return _columns[(NSUInteger)index]; }
- (NSInteger)indexOfColumn:(NSGridColumn *)column { NSUInteger i = [_columns indexOfObjectIdenticalTo:column]; return i == NSNotFound ? -1 : (NSInteger)i; }
- (NSGridCell *)cellAtColumnIndex:(NSInteger)c rowIndex:(NSInteger)r { return _cells[(NSUInteger)r][(NSUInteger)c]; }

- (NSGridCell *)cellForView:(NSView *)view {
  for (NSArray<NSGridCell *> *row in _cells)
    for (NSGridCell *cell in row)
      for (NSView *v = view; v; v = v.superview)
        if (cell.contentView == v) return cell;
  return nil;
}

- (NSGridColumn *)newColumn {
  NSGridColumn *c = [NSGridColumn new];
  c.gridView = self;
  c.width = NSGridViewSizeForContent;
  return c;
}

// Columns enough for `count` cells in a row.
- (void)widenTo:(NSUInteger)count {
  while (_columns.count < count) {
    [_columns addObject:[self newColumn]];
    for (NSMutableArray *row in _cells) [row addObject:[NSGridCell new]];
  }
}

- (void)place:(NSView *)view inCell:(NSGridCell *)cell {
  if (view == NSGridCell.emptyContentView) view = nil;
  [cell.contentView removeFromSuperview];
  cell.contentView = view;
  if (view) [self addSubview:view];
}

- (NSGridRow *)insertRowAtIndex:(NSInteger)index withViews:(NSArray<NSView *> *)views {
  [self widenTo:views.count];
  NSGridRow *row = [NSGridRow new];
  row.gridView = self;
  row.height = NSGridViewSizeForContent;
  NSMutableArray<NSGridCell *> *cells = [NSMutableArray array];
  for (NSUInteger c = 0; c < _columns.count; c++) {
    NSGridCell *cell = [NSGridCell new];
    if (c < views.count) [self place:views[c] inCell:cell];
    [cells addObject:cell];
  }
  NSUInteger at = (NSUInteger)MAX(0, MIN(index, (NSInteger)_rows.count));
  [_rows insertObject:row atIndex:at];
  [_cells insertObject:cells atIndex:at];
  [self akLayoutCells];
  return row;
}

- (NSGridRow *)addRowWithViews:(NSArray<NSView *> *)views { return [self insertRowAtIndex:self.numberOfRows withViews:views]; }

- (void)removeRowAtIndex:(NSInteger)index {
  for (NSGridCell *cell in _cells[(NSUInteger)index]) [cell.contentView removeFromSuperview];
  [_cells removeObjectAtIndex:(NSUInteger)index];
  [_rows removeObjectAtIndex:(NSUInteger)index];
  [self akLayoutCells];
}

- (NSGridColumn *)insertColumnAtIndex:(NSInteger)index withViews:(NSArray<NSView *> *)views {
  while (_rows.count < views.count) [self addRowWithViews:@[]];
  NSGridColumn *column = [self newColumn];
  NSUInteger at = (NSUInteger)MAX(0, MIN(index, (NSInteger)_columns.count));
  [_columns insertObject:column atIndex:at];
  for (NSUInteger r = 0; r < _cells.count; r++) {
    NSGridCell *cell = [NSGridCell new];
    if (r < views.count) [self place:views[r] inCell:cell];
    [_cells[r] insertObject:cell atIndex:at];
  }
  [self akLayoutCells];
  return column;
}

- (NSGridColumn *)addColumnWithViews:(NSArray<NSView *> *)views { return [self insertColumnAtIndex:self.numberOfColumns withViews:views]; }

- (void)removeColumnAtIndex:(NSInteger)index {
  for (NSMutableArray<NSGridCell *> *row in _cells) {
    [row[(NSUInteger)index].contentView removeFromSuperview];
    [row removeObjectAtIndex:(NSUInteger)index];
  }
  [_columns removeObjectAtIndex:(NSUInteger)index];
  [self akLayoutCells];
}

- (void)mergeCellsInHorizontalRange:(NSRange)hRange verticalRange:(NSRange)vRange {}

- (void)setFrameSize:(NSSize)size {
  [super setFrameSize:size];
  [self akLayoutCells];
}

- (void)setRowSpacing:(CGFloat)spacing { _rowSpacing = spacing; [self akLayoutCells]; }
- (void)setColumnSpacing:(CGFloat)spacing { _columnSpacing = spacing; [self akLayoutCells]; }

static CGFloat placed(CGFloat start, CGFloat room, CGFloat size, NSGridCellPlacement p, CGFloat *outSize) {
  *outSize = p == NSGridCellPlacementFill ? room : MIN(size, room);
  switch (p) {
    case NSGridCellPlacementTrailing: return start + room - *outSize;
    case NSGridCellPlacementCenter: return start + (room - *outSize) / 2;
    default: return start;
  }
}

// Columns as wide as their widest view, rows as tall as their tallest, from the top-left.
- (void)akLayoutCells {
  if (!_cells) return;   // still in -initWithFrame:
  NSUInteger nr = _rows.count, nc = _columns.count;
  CGFloat widths[nc ? nc : 1], heights[nr ? nr : 1];
  for (NSUInteger c = 0; c < nc; c++) {
    NSGridColumn *column = _columns[c];
    widths[c] = 0;
    if (column.hidden) continue;
    if (column.width != NSGridViewSizeForContent) widths[c] = column.width;
    else for (NSUInteger r = 0; r < nr; r++) widths[c] = MAX(widths[c], _cells[r][c].contentView.frame.size.width);
    widths[c] += column.leadingPadding + column.trailingPadding;
  }
  for (NSUInteger r = 0; r < nr; r++) {
    NSGridRow *row = _rows[r];
    heights[r] = 0;
    if (row.hidden) continue;
    if (row.height != NSGridViewSizeForContent) heights[r] = row.height;
    else for (NSUInteger c = 0; c < nc; c++) heights[r] = MAX(heights[r], _cells[r][c].contentView.frame.size.height);
    heights[r] += row.topPadding + row.bottomPadding;
  }
  CGFloat contentW = 0, contentH = 0;
  for (NSUInteger c = 0; c < nc; c++) contentW += widths[c] + (c ? _columnSpacing : 0);
  for (NSUInteger r = 0; r < nr; r++) contentH += heights[r] + (r ? _rowSpacing : 0);
  NSRect frame = self.frame;
  if (frame.size.width < contentW || frame.size.height < contentH) {
    [super setFrameSize:NSMakeSize(MAX(frame.size.width, contentW), MAX(frame.size.height, contentH))];
  }
  CGFloat height = self.bounds.size.height, top = 0;
  for (NSUInteger r = 0; r < nr; r++) {
    NSGridRow *row = _rows[r];
    CGFloat left = 0;
    for (NSUInteger c = 0; c < nc; c++) {
      NSGridColumn *column = _columns[c];
      NSGridCell *cell = _cells[r][c];
      NSView *view = cell.contentView;
      view.hidden = row.hidden || column.hidden;
      if (view && !view.hidden) {
        NSGridCellPlacement x = cell.xPlacement ?: column.xPlacement ?: _xPlacement;
        NSGridCellPlacement y = cell.yPlacement ?: row.yPlacement ?: _yPlacement;
        CGFloat w, h;
        CGFloat vx = placed(left + column.leadingPadding, widths[c] - column.leadingPadding - column.trailingPadding, view.frame.size.width, x, &w);
        CGFloat vy = placed(top + row.topPadding, heights[r] - row.topPadding - row.bottomPadding, view.frame.size.height, y, &h);
        // Rows run down from the top; an unflipped view's y runs up.
        view.frame = NSMakeRect(vx, self.isFlipped ? vy : height - vy - h, w, h);
      }
      left += widths[c] + _columnSpacing;
    }
    top += heights[r] + _rowSpacing;
  }
}

@end

@implementation NSGridRow
- (NSInteger)numberOfCells { return self.gridView.numberOfColumns; }
- (NSGridCell *)cellAtIndex:(NSInteger)index { return [self.gridView cellAtColumnIndex:index rowIndex:[self.gridView indexOfRow:self]]; }
- (void)setHidden:(BOOL)hidden { _hidden = hidden; [self.gridView akLayoutCells]; }
@end

@implementation NSGridColumn
- (NSInteger)numberOfCells { return self.gridView.numberOfRows; }
- (NSGridCell *)cellAtIndex:(NSInteger)index { return [self.gridView cellAtColumnIndex:[self.gridView indexOfColumn:self] rowIndex:index]; }
- (void)setHidden:(BOOL)hidden { _hidden = hidden; [self.gridView akLayoutCells]; }
@end
