#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>

#import <mach/mach.h>
#import <mach/mach_time.h>

@interface SBCPUFloatingView : UIView

@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) CADisplayLink *timer;

@property(nonatomic) uint64_t lastCPU;
@property(nonatomic) uint64_t lastWall;

@property(nonatomic) mach_timebase_info_data_t timebase;

@end


@implementation SBCPUFloatingView

- (instancetype)init
{
    self = [super initWithFrame:CGRectMake(18, 150, 118, 36)];

    if (!self) {
        return nil;
    }

    mach_timebase_info(&_timebase);

    // 外观
    self.backgroundColor =
        [[UIColor blackColor] colorWithAlphaComponent:0.78];

    self.layer.cornerRadius = 9.0;
    self.layer.masksToBounds = YES;

    // CPU文字
    _label = [[UILabel alloc] initWithFrame:self.bounds];

    _label.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;

    _label.textAlignment = NSTextAlignmentCenter;

    _label.font =
        [UIFont monospacedDigitSystemFontOfSize:13
                                         weight:UIFontWeightMedium];

    _label.textColor = UIColor.whiteColor;

    _label.text = @"SB CPU --";

    [self addSubview:_label];


    // 拖动
    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handlePan:)];

    [self addGestureRecognizer:pan];


    // 每秒采样一次
    _timer =
        [CADisplayLink displayLinkWithTarget:self
                                    selector:@selector(sample)];

    _timer.preferredFramesPerSecond = 1;

    [_timer addToRunLoop:[NSRunLoop mainRunLoop]
                 forMode:NSRunLoopCommonModes];

    return self;
}


- (void)dealloc
{
    [_timer invalidate];
}


#pragma mark - Mach time 转纳秒

- (uint64_t)wallToNsec:(uint64_t)t
{
    return t *
           (uint64_t)_timebase.numer /
           (uint64_t)_timebase.denom;
}


#pragma mark - CPU采样

- (void)sample
{
    task_thread_times_info_data_t info;

    mach_msg_type_number_t count =
        TASK_THREAD_TIMES_INFO_COUNT;

    kern_return_t result =
        task_info(mach_task_self(),
                  TASK_THREAD_TIMES_INFO,
                  (task_info_t)&info,
                  &count);

    if (result != KERN_SUCCESS) {
        return;
    }


    // 用户态CPU时间
    uint64_t userCPU =
        ((uint64_t)info.user_time.seconds * 1000000000ULL) +
        ((uint64_t)info.user_time.microseconds * 1000ULL);


    // 内核态CPU时间
    uint64_t systemCPU =
        ((uint64_t)info.system_time.seconds * 1000000000ULL) +
        ((uint64_t)info.system_time.microseconds * 1000ULL);


    // 总CPU时间
    uint64_t cpu = userCPU + systemCPU;


    // 当前墙钟时间
    uint64_t wall = mach_absolute_time();


    // 第一次采样只记录基准
    if (_lastCPU == 0 || _lastWall == 0) {

        _lastCPU = cpu;
        _lastWall = wall;

        return;
    }


    uint64_t dCPU =
        cpu - _lastCPU;

    uint64_t dWall =
        wall - _lastWall;


    _lastCPU = cpu;
    _lastWall = wall;


    // CPU时间 → 秒
    double cpuSeconds =
        (double)dCPU / 1000000000.0;


    // 墙钟时间 → 纳秒 → 秒
    double wallSeconds =
        (double)[self wallToNsec:dWall]
        / 1000000000.0;


    if (wallSeconds <= 0.0) {
        return;
    }


    // SpringBoard当前进程CPU占用
    double percent =
        (cpuSeconds / wallSeconds) * 100.0;


    if (percent < 0.0) {
        percent = 0.0;
    }


    if (percent > 999.9) {
        percent = 999.9;
    }


    self.label.text =
        [NSString stringWithFormat:@"SB CPU %5.1f%%",
                                   percent];
}


#pragma mark - 拖动

- (void)handlePan:(UIPanGestureRecognizer *)g
{
    UIView *superview = self.superview;

    if (!superview) {
        return;
    }


    CGPoint translation =
        [g translationInView:superview];


    self.center =
        CGPointMake(self.center.x + translation.x,
                    self.center.y + translation.y);


    [g setTranslation:CGPointZero
             inView:superview];


    // 防止拖出屏幕
    CGRect bounds =
        superview.bounds;


    CGFloat halfWidth =
        self.bounds.size.width / 2.0;


    CGFloat halfHeight =
        self.bounds.size.height / 2.0;


    self.center =
        CGPointMake(
            MAX(halfWidth,
                MIN(CGRectGetWidth(bounds) - halfWidth,
                    self.center.x)),

            MAX(halfHeight,
                MIN(CGRectGetHeight(bounds) - halfHeight,
                    self.center.y))
        );
}

@end



#pragma mark - 安装悬浮窗

static void SBCPUInstall(void)
{
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(1.0 * NSEC_PER_SEC)),

        dispatch_get_main_queue(),

        ^{

            UIApplication *app =
                UIApplication.sharedApplication;


            if (!app) {
                return;
            }


            UIWindow *target = nil;


            // 找正常的SpringBoard窗口
            for (UIWindow *window in app.windows) {

                if (!window.hidden &&
                    window.alpha > 0.0 &&
                    window.windowLevel == UIWindowLevelNormal) {

                    target = window;

                    break;
                }
            }


            if (!target) {
                target = app.keyWindow;
            }


            if (!target) {
                return;
            }


            // 防止重复创建
            for (UIView *subview in target.subviews) {

                if (subview.tag == 0x53424350) {
                    return;
                }
            }


            SBCPUFloatingView *view =
                [[SBCPUFloatingView alloc] init];


            view.tag = 0x53424350;


            [target addSubview:view];
        }
    );
}



#pragma mark - RootHide注入入口

%ctor
{
    /*
     不再使用：

     proc_pidpath()
     libproc.h

     因此不需要libproc.h。
    */


    NSString *processName =
        [NSProcessInfo processInfo].processName;


    /*
     RootHide可能把Tweak注入多个进程。
     只有SpringBoard才启动悬浮CPU监控。
    */

    if ([processName isEqualToString:@"SpringBoard"]) {

        SBCPUInstall();
    }
}
