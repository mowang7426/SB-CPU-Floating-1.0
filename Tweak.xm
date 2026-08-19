#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <mach/mach_time.h>

@interface SBCPUFloatingView : UIView

@property(nonatomic,strong) UILabel *label;
@property(nonatomic,strong) CADisplayLink *timer;

@property(nonatomic) uint64_t lastCPU;
@property(nonatomic) uint64_t lastWall;

@property(nonatomic) mach_timebase_info_data_t timebase;

@end


@implementation SBCPUFloatingView

- (instancetype)init
{
    self = [super initWithFrame:CGRectMake(18, 150, 118, 36)];

    if (!self)
        return nil;

    mach_timebase_info(&_timebase);

    /*
     * 浮窗外观
     */
    self.backgroundColor =
        [[UIColor blackColor] colorWithAlphaComponent:0.78];

    self.layer.cornerRadius = 9.0;
    self.layer.masksToBounds = YES;

    /*
     * CPU文字
     */
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


    /*
     * 拖动手势
     */
    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handlePan:)];

    [self addGestureRecognizer:pan];


    /*
     * 每秒刷新一次
     */
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


/*
 * mach_absolute_time 转纳秒
 */
- (uint64_t)wallToNsec:(uint64_t)t
{
    return t *
        (uint64_t)_timebase.numer /
        (uint64_t)_timebase.denom;
}


/*
 * 获取 SpringBoard 当前 CPU 使用率
 */
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

    if (result != KERN_SUCCESS)
        return;


    /*
     * 用户态 CPU 时间
     */
    uint64_t userCPU =
        ((uint64_t)info.user_time.seconds * 1000000000ULL) +
        ((uint64_t)info.user_time.microseconds * 1000ULL);


    /*
     * 系统态 CPU 时间
     */
    uint64_t systemCPU =
        ((uint64_t)info.system_time.seconds * 1000000000ULL) +
        ((uint64_t)info.system_time.microseconds * 1000ULL);


    uint64_t cpu = userCPU + systemCPU;

    uint64_t wall = mach_absolute_time();


    /*
     * 第一次采样只记录基准
     */
    if (_lastCPU == 0 || _lastWall == 0)
    {
        _lastCPU = cpu;
        _lastWall = wall;
        return;
    }


    /*
     * 计算时间差
     */
    uint64_t dCPU =
        cpu - _lastCPU;

    uint64_t dWall =
        wall - _lastWall;


    _lastCPU = cpu;
    _lastWall = wall;


    /*
     * CPU 秒数
     */
    double cpuSeconds =
        (double)dCPU / 1000000000.0;


    /*
     * 实际经过的墙钟时间
     */
    double wallSeconds =
        (double)[self wallToNsec:dWall]
        / 1000000000.0;


    /*
     * CPU 百分比
     */
    double percent = 0.0;

    if (wallSeconds > 0.0)
    {
        percent =
            (cpuSeconds / wallSeconds) * 100.0;
    }


    /*
     * 防止异常值
     */
    if (percent < 0.0)
        percent = 0.0;

    if (percent > 999.9)
        percent = 999.9;


    /*
     * 显示
     */
    self.label.text =
        [NSString stringWithFormat:@"SB CPU %5.1f%%",
                                   percent];
}


/*
 * 拖动浮窗
 */
- (void)handlePan:(UIPanGestureRecognizer *)g
{
    UIView *superview = self.superview;

    if (!superview)
        return;


    CGPoint t =
        [g translationInView:superview];


    self.center =
        CGPointMake(self.center.x + t.x,
                    self.center.y + t.y);


    [g setTranslation:CGPointZero
             inView:superview];


    /*
     * 限制浮窗不能拖出屏幕
     */
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



/*
 * 安装 CPU 浮窗
 */
static void SBCPUInstall(void)
{
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(1.0 * NSEC_PER_SEC)),

        dispatch_get_main_queue(),
        ^{

            UIApplication *app =
                UIApplication.sharedApplication;

            if (!app)
                return;


            UIWindow *target = nil;


            /*
             * 优先寻找正常 UIWindow
             */
            for (UIWindow *window in app.windows)
            {
                if (!window.hidden &&
                    window.alpha > 0.0 &&
                    window.windowLevel == UIWindowLevelNormal)
                {
                    target = window;
                    break;
                }
            }


            /*
             * 如果没找到，就寻找任意可见窗口
             */
            if (!target)
            {
                for (UIWindow *window in app.windows)
                {
                    if (!window.hidden &&
                        window.alpha > 0.0)
                    {
                        target = window;
                        break;
                    }
                }
            }


            if (!target)
                return;


            /*
             * 防止重复创建
             */
            for (UIView *subview in target.subviews)
            {
                if (subview.tag == 0x53424350)
                    return;
            }


            /*
             * 创建 CPU 浮窗
             */
            SBCPUFloatingView *view =
                [[SBCPUFloatingView alloc] init];

            view.tag = 0x53424350;


            [target addSubview:view];
        }
    );
}



/*
 * RootHide 注入后：
 *
 * 这里只在 SpringBoard 进程运行。
 *
 * 不再使用：
 * PROC_PIDPATHINFO_MAXSIZE
 * proc_pidpath()
 *
 * 避免 SDK 缺少相关声明导致编译失败。
 */
%ctor
{
    NSString *processName =
        [NSProcessInfo processInfo].processName;


    if (![processName isEqualToString:@"SpringBoard"])
        return;


    SBCPUInstall();
}
