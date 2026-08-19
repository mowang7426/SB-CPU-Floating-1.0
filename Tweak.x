#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import <mach/mach.h>
#import <mach/mach_time.h>

#import <unistd.h>
#import <string.h>
#import <libproc.h>

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


    // 拖动
    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handlePan:)];

    [self addGestureRecognizer:pan];


    // 每秒刷新一次
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


#pragma mark - Mach time

- (uint64_t)wallToNsec:(uint64_t)t {

    return t *
        (uint64_t)_timebase.numer /
        (uint64_t)_timebase.denom;
}


#pragma mark - CPU

- (void)sample {

    /*
     * 当前 tweak 只注入 SpringBoard。
     *
     * mach_task_self() 获取当前进程，也就是 SpringBoard。
     *
     * 不进行进程枚举，因此不会因为扫描大量进程
     * 而额外增加 SpringBoard CPU。
     */

    task_thread_times_info_data_t info;

    mach_msg_type_number_t count =
        TASK_THREAD_TIMES_INFO_COUNT;


    kern_return_t kr =
        task_info(
            mach_task_self(),
            TASK_THREAD_TIMES_INFO,
            (task_info_t)&info,
            &count
        );


    if (kr != KERN_SUCCESS) {
        return;
    }


    uint64_t cpu =
        ((uint64_t)info.user_time.seconds * 1000000000ULL) +
        ((uint64_t)info.user_time.microseconds * 1000ULL) +
        ((uint64_t)info.system_time.seconds * 1000000000ULL) +
        ((uint64_t)info.system_time.microseconds * 1000ULL);


    uint64_t wall = mach_absolute_time();


    // 第一次采样，只保存基准
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


    if (dWall == 0) {
        return;
    }


    double cpuSeconds =
        (double)dCPU / 1000000000.0;


    double wallSeconds =
        (double)[self wallToNsec:dWall] /
        1000000000.0;


    if (wallSeconds <= 0.0) {
        return;
    }


    double percent =
        (cpuSeconds / wallSeconds) * 100.0;


    if (percent < 0.0) {
        percent = 0.0;
    }


    if (percent > 999.9) {
        percent = 999.9;
    }


    dispatch_async(dispatch_get_main_queue(), ^{

        self.label.text =
            [NSString stringWithFormat:@"SB CPU %5.1f%%",
                                       percent];

    });
}


#pragma mark - Drag

- (void)handlePan:(UIPanGestureRecognizer *)g {

    UIView *superview = self.superview;

    if (!superview) {
        return;
    }


    CGPoint t =
        [g translationInView:superview];


    self.center =
        CGPointMake(
            self.center.x + t.x,
            self.center.y + t.y
        );


    [g setTranslation:CGPointZero
             inView:superview];


    CGRect bounds =
        superview.bounds;


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



#pragma mark - Install

static void SBCPUInstall(void) {

    if (getpid() <= 0) {
        return;
    }


    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(1.0 * NSEC_PER_SEC)
        ),

        dispatch_get_main_queue(),

        ^{

            UIApplication *app =
                UIApplication.sharedApplication;


            if (!app) {
                return;
            }


            UIWindow *target = nil;


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



#pragma mark - Constructor

%ctor {

    /*
     * RootHide 可能会把 dylib 加载到多个进程。
     *
     * 这里只允许 SpringBoard 创建 CPU 监控。
     */

    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};


    int result =
        proc_pidpath(
            getpid(),
            path,
            sizeof(path)
        );


    if (result <= 0) {
        return;
    }


    NSString *exe =
        [NSString stringWithUTF8String:path];


    if ([exe.lastPathComponent
            isEqualToString:@"SpringBoard"]) {

        SBCPUInstall();
    }
}
