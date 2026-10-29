// NSGridView — views in rows and columns (Godot builds its file dialogs' option panes with one).
// The shim's views have no Auto Layout, so the grid lays its cells out with frames: each column
// as wide as its widest view (or its set width), each row as tall as its tallest, spacing between,
// rows from the top. A grid smaller than its content grows to fit it.
#import "NSView.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NSGridCellPlacement) {
  NSGridCellPlacementInherited = 0,
  NSGridCellPlacementNone,
  NSGridCellPlacementLeading,
  NSGridCellPlacementTop = NSGridCellPlacementLeading,
  NSGridCellPlacementTrailing,
  NSGridCellPlacementBottom = NSGridCellPlacementTrailing,
  NSGridCellPlacementCenter,
  NSGridCellPlacementFill,
};

typedef NS_ENUM(NSInteger, NSGridRowAlignment) {
  NSGridRowAlignmentInherited = 0,
  NSGridRowAlignmentNone,
  NSGridRowAlignmentFirstBaseline,
  NSGridRowAlignmentLastBaseline,
};

// A row's height or a column's width that follows its content.
extern const CGFloat NSGridViewSizeForContent;

@class NSGridView;

@interface NSGridCell : NSObject
@property (class, readonly, strong) NSView *emptyContentView;
@property (nonatomic, strong, nullable) NSView *contentView;
@property (nonatomic) NSGridCellPlacement xPlacement;
@property (nonatomic) NSGridCellPlacement yPlacement;
@property (nonatomic) NSGridRowAlignment rowAlignment;
@end

@interface NSGridRow : NSObject
@property (nonatomic, readonly, weak) NSGridView *gridView;
@property (nonatomic, readonly) NSInteger numberOfCells;
- (NSGridCell *)cellAtIndex:(NSInteger)index;
@property (nonatomic) NSGridCellPlacement yPlacement;
@property (nonatomic) NSGridRowAlignment rowAlignment;
@property (nonatomic) CGFloat height;
@property (nonatomic) CGFloat topPadding;
@property (nonatomic) CGFloat bottomPadding;
@property (nonatomic, getter=isHidden) BOOL hidden;
@end

@interface NSGridColumn : NSObject
@property (nonatomic, readonly, weak) NSGridView *gridView;
@property (nonatomic, readonly) NSInteger numberOfCells;
- (NSGridCell *)cellAtIndex:(NSInteger)index;
@property (nonatomic) NSGridCellPlacement xPlacement;
@property (nonatomic) CGFloat width;
@property (nonatomic) CGFloat leadingPadding;
@property (nonatomic) CGFloat trailingPadding;
@property (nonatomic, getter=isHidden) BOOL hidden;
@end

@interface NSGridView : NSView
+ (instancetype)gridViewWithNumberOfColumns:(NSInteger)columnCount rows:(NSInteger)rowCount;
+ (instancetype)gridViewWithViews:(NSArray<NSArray<NSView *> *> *)rows;

@property (nonatomic, readonly) NSInteger numberOfRows;
@property (nonatomic, readonly) NSInteger numberOfColumns;
- (NSGridRow *)rowAtIndex:(NSInteger)index;
- (NSInteger)indexOfRow:(NSGridRow *)row;
- (NSGridColumn *)columnAtIndex:(NSInteger)index;
- (NSInteger)indexOfColumn:(NSGridColumn *)column;
- (NSGridCell *)cellAtColumnIndex:(NSInteger)columnIndex rowIndex:(NSInteger)rowIndex;
- (nullable NSGridCell *)cellForView:(NSView *)view;

- (NSGridRow *)addRowWithViews:(NSArray<NSView *> *)views;
- (NSGridRow *)insertRowAtIndex:(NSInteger)index withViews:(NSArray<NSView *> *)views;
- (void)removeRowAtIndex:(NSInteger)index;
- (NSGridColumn *)addColumnWithViews:(NSArray<NSView *> *)views;
- (NSGridColumn *)insertColumnAtIndex:(NSInteger)index withViews:(NSArray<NSView *> *)views;
- (void)removeColumnAtIndex:(NSInteger)index;
// Merged cells keep their own frames here (the first cell's view spans nothing more).
- (void)mergeCellsInHorizontalRange:(NSRange)hRange verticalRange:(NSRange)vRange;

@property (nonatomic) NSGridCellPlacement xPlacement;
@property (nonatomic) NSGridCellPlacement yPlacement;
@property (nonatomic) NSGridRowAlignment rowAlignment;
@property (nonatomic) CGFloat rowSpacing;
@property (nonatomic) CGFloat columnSpacing;
@end

NS_ASSUME_NONNULL_END
