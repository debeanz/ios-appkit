// NSAnimationContext (grouped implicit animations, over CATransaction) and NSAnimation
// (a timed progress driver that subclasses and delegates hook into).
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

@interface NSAnimationContext : NSObject
@property (class, readonly, strong) NSAnimationContext *currentContext;
+ (void)beginGrouping;
+ (void)endGrouping;
+ (void)runAnimationGroup:(void (^)(NSAnimationContext *context))changes completionHandler:(void (^)(void))completionHandler;
+ (void)runAnimationGroup:(void (^)(NSAnimationContext *context))changes;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, strong) CAMediaTimingFunction *timingFunction;
@property (nonatomic, assign) BOOL allowsImplicitAnimation;
@property (nonatomic, copy) void (^completionHandler)(void);
@end

typedef NS_ENUM(NSUInteger, NSAnimationCurve) {
  NSAnimationEaseInOut = 0, NSAnimationEaseIn = 1, NSAnimationEaseOut = 2, NSAnimationLinear = 3,
};
typedef NS_ENUM(NSUInteger, NSAnimationBlockingMode) {
  NSAnimationBlocking = 0, NSAnimationNonblocking = 1, NSAnimationNonblockingThreaded = 2,
};
typedef float NSAnimationProgress;

@class NSAnimation;
@protocol NSAnimationDelegate <NSObject>
@optional
- (BOOL)animationShouldStart:(NSAnimation *)animation;
- (void)animationDidStop:(NSAnimation *)animation;
- (void)animationDidEnd:(NSAnimation *)animation;
- (float)animation:(NSAnimation *)animation valueForProgress:(NSAnimationProgress)progress;
@end

@interface NSAnimation : NSObject
- (instancetype)initWithDuration:(NSTimeInterval)duration animationCurve:(NSAnimationCurve)curve;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) NSAnimationCurve animationCurve;
@property (nonatomic, assign) float frameRate;
@property (nonatomic, assign) NSAnimationBlockingMode animationBlockingMode;
@property (nonatomic, weak) id<NSAnimationDelegate> delegate;
@property (nonatomic, assign) NSAnimationProgress currentProgress; // subclasses override the setter
@property (nonatomic, readonly) float currentValue;
@property (nonatomic, readonly, getter=isAnimating) BOOL animating;
- (void)startAnimation;
- (void)stopAnimation;
@end
