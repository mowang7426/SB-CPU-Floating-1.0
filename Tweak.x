#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import <mach/mach.h>
#import <mach/mach_time.h>

#import <unistd.h>
#import <dispatch/dispatch.h>

@interface SBCPUFloatingView : UIView

@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) CADisplayLink *timer;

@property(nonatomic) uint64_t lastCPU;
@property(nonatomic) uint64_t lastWall;
@property(nonatomic) mach_timebase_info_data_t timebase;

@end


@implementation SBCPUFloatingView

- (instancetype)init {
    self = [super initWithFrame:CGRectMake(18, 150, 118, 36)];

    if (!self) {
        return nil;
    }

    mach_timebase_info(&_timebase);

    self.backgroundColor =
        [[UIColor blackColor] colorWithAlphaComponent:0.78];

    self.layer.cornerRadius = 9.0;
    self.layer.masksToBounds = YES;

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


    // 拖动悬浮窗
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


- (void)dealloc {
    [_timer invalidate];
}


// mach_absolute_time 间隔转换为纳秒
- (double)secondsFromMachTime:(uint64_t)t {

    if (_timebase.denom == 0) {
        return 0.0;
    }

    double nanos =
        ((double)t *
         (double)_timebase.numer) /
        (double)_timebase.denom;

    return nanos / 1000000000.0;
}


// 获取 SpringBoard 当前进程 CPU 使用率
- (void)sample {

    task_thread_times_info_data_t info;

    mach_msg_type_number_t count =
        TASK_THREAD_TIMES_INFO_COUNT;


    kern_return_t kr =
        task_info(mach_task_self(),
                  TASK_THREAD_TIMES_INFO,
                  (task_info_t)&info,
                  &count);


    if (kr != KERN_SUCCESS) {
        return;
    }


    // 当前 SpringBoard 进程累计 CPU 时间
    uint64_t userNsec =
        ((uint64_t)info.user_time.seconds * 1000000000ULL) +
        ((uint64_t)info.user_time.microseconds * 1000ULL);


    uint64_t systemNsec =
        ((uint64_t)info.system_time.seconds * 1000000000ULL) +
        ((uint64_t)info.system_time.microseconds * 1000ULL);


    uint64_t cpu = userNsec + systemNsec;


    // 当前时间
    uint64_t wall = mach_absolute_time();


    // 第一次采样只记录数据
    if (_lastCPU == 0 || _lastWall == 0) {

        _lastCPU = cpu;
        _lastWall = wall;

        self.label.text = @"SB CPU --";

        return;
    }


    // CPU 时间增量
    uint64_t dCPU = cpu - _lastCPU;

    // 实际经过时间
    uint64_t dWall = wall - _lastWall;


    _lastCPU = cpu;
    _lastWall = wall;


    double cpuSeconds =
        (double)dCPU / 1000000000.0;


    double wallSeconds =
        [self secondsFromMachTime:dWall];


    if (wallSeconds <= 0.0) {
        return;
    }


    // CPU 使用率
    //
    // 100% = 一个 CPU 核心满载
    // 多核心情况下可能超过 100%
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


// 拖动悬浮窗
- (void)handlePan:(UIPanGestureRecognizer *)g {

    UIView *superview = self.superview;

    if (!superview) {
        return;
    }


    CGPoint t =
        [g translationInView:superview];


    self.center =
        CGPointMake(self.center.x + t.x,
                    self.center.y + t.y);


    [g setTranslation:CGPointZero
             inView:superview];


    // 防止拖出屏幕
    CGRect bounds = superview.bounds;


    CGFloat hw =
        self.bounds.size.width / 2.0;


    CGFloat hh =
        self.bounds.size.height / 2.0;


    self.center =
        CGPointMake(
            MAX(hw,
                MIN(CGRectGetWidth(bounds) - hw,
                    self.center.x)),

            MAX(hh,
                MIN(CGRectGetHeight(bounds) - hh,
                    self.center.y))
        );
}

@end



// 安装悬浮窗
static void SBCPUInstall(void) {

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


            // 寻找 SpringBoard 当前正常窗口
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



// RootHide 注入入口
//
// 不再使用：
// proc_pidpath()
// libproc.h
//
// 因为这个 Tweak 本身就是给 SpringBoard 注入的。
// 只有 SpringBoard 加载这个 Tweak 时才需要创建悬浮窗。
%ctor {

    SBCPUInstall();
}
