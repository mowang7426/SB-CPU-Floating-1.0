#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <libproc.h>

// ===== SB CPU Floating 1.1.0 configuration =====
// plist:
// /var/mobile/Library/Preferences/com.sbcpufloating.monitor.plist
//
// CPUThreshold: Number (default 85)
// HoldTime: Number seconds (default 10)
// AutoRespring: Boolean (default NO)
// RefreshInterval: Number seconds (default 1)

static NSDictionary *SBCPUConfig(void) {
    NSString *p = @"/var/mobile/Library/Preferences/com.sbcpufloating.monitor.plist";
    return [NSDictionary dictionaryWithContentsOfFile:p] ?: @{};
}

static double SBCPUThresholdValue(void) {
    NSNumber *n = SBCPUConfig()[@"CPUThreshold"];
    return n ? n.doubleValue : 85.0;
}

static double SBCPUHoldTimeValue(void) {
    NSNumber *n = SBCPUConfig()[@"HoldTime"];
    return n ? n.doubleValue : 10.0;
}

static BOOL SBCAutoRespringValue(void) {
    NSNumber *n = SBCPUConfig()[@"AutoRespring"];
    return n ? n.boolValue : NO;
}

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <unistd.h>
#import <string.h>

@interface SBCPUFloatingView : UIView
@property(nonatomic,strong) UILabel *label;
@property(nonatomic,strong) CADisplayLink *timer;
@property(nonatomic) uint64_t lastCPU;
@property(nonatomic) uint64_t lastWall;
@property(nonatomic) mach_timebase_info_data_t timebase;
@end

@implementation SBCPUFloatingView

- (instancetype)init {
    self = [super initWithFrame:CGRectMake(18, 150, 118, 36)];
    if (!self) return nil;

    mach_timebase_info(&_timebase);

    self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
    self.layer.cornerRadius = 9.0;
    self.layer.masksToBounds = YES;

    _label = [[UILabel alloc] initWithFrame:self.bounds];
    _label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _label.textAlignment = NSTextAlignmentCenter;
    _label.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    _label.textColor = UIColor.whiteColor;
    _label.text = @"SB CPU --";
    [self addSubview:_label];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:pan];

    _timer = [CADisplayLink displayLinkWithTarget:self selector:@selector(sample)];
    _timer.preferredFramesPerSecond = 1;
    [_timer addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    return self;
}

- (void)dealloc {
    [_timer invalidate];
}

- (uint64_t)wallToNsec:(uint64_t)t {
    return t * (uint64_t)_timebase.numer / (uint64_t)_timebase.denom;
}

- (void)sample {
    // The tweak is only installed/displayed inside SpringBoard.
    // Use the current process directly; no process enumeration is needed.
    task_thread_times_info_data_t info;
    mach_msg_type_number_t count = TASK_THREAD_TIMES_INFO_COUNT;

    if (task_info(mach_task_self(), TASK_THREAD_TIMES_INFO,
                  (task_info_t)&info, &count) != KERN_SUCCESS) {
        return;
    }

    uint64_t cpu =
        ((uint64_t)info.user_time.seconds * 1000000000ULL) +
        ((uint64_t)info.user_time.microseconds * 1000ULL) +
        ((uint64_t)info.system_time.seconds * 1000000000ULL) +
        ((uint64_t)info.system_time.microseconds * 1000ULL);

    uint64_t wall = mach_absolute_time();

    if (_lastCPU == 0 || _lastWall == 0) {
        _lastCPU = cpu;
        _lastWall = wall;
        return;
    }

    uint64_t dCPU = cpu - _lastCPU;
    uint64_t dWall = wall - _lastWall;
    _lastCPU = cpu;
    _lastWall = wall;

    double cpuSeconds = (double)dCPU / 1000000000.0;
    double wallSeconds = (double)[self wallToNsec:dWall] / 1000000000.0;
    double percent = wallSeconds > 0.0 ? (cpuSeconds / wallSeconds) * 100.0 : 0.0;

    if (percent < 0.0) percent = 0.0;
    if (percent > 999.9) percent = 999.9;

    self.label.text = [NSString stringWithFormat:@"SB CPU %5.1f%%", percent];
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    UIView *superview = self.superview;
    if (!superview) return;

    CGPoint t = [g translationInView:superview];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [g setTranslation:CGPointZero inView:superview];

    CGRect bounds = superview.bounds;
    CGFloat hw = self.bounds.size.width / 2.0;
    CGFloat hh = self.bounds.size.height / 2.0;

    self.center = CGPointMake(
        MAX(hw, MIN(CGRectGetWidth(bounds) - hw, self.center.x)),
        MAX(hh, MIN(CGRectGetHeight(bounds) - hh, self.center.y))
    );
}

@end

static void SBCPUInstall(void) {
    if (getpid() <= 0) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIApplication *app = UIApplication.sharedApplication;
        if (!app) return;

        UIWindow *target = nil;
        for (UIWindow *window in app.windows) {
            if (!window.hidden && window.alpha > 0.0 &&
                window.windowLevel == UIWindowLevelNormal) {
                target = window;
                break;
            }
        }

        if (!target) target = app.keyWindow;
        if (!target) return;

        for (UIView *subview in target.subviews) {
            if (subview.tag == 0x53424350) return;
        }

        SBCPUFloatingView *view =
            [[SBCPUFloatingView alloc] init];
        view.tag = 0x53424350;
        [target addSubview:view];
    });
}

%ctor {
    // RootHide/Bootstrap may inject the dylib into multiple targets.
    // Only create the monitor when the current executable is SpringBoard.
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    proc_pidpath(getpid(), path, sizeof(path));
    NSString *exe = [NSString stringWithUTF8String:path] ?: @"";

    if ([exe.lastPathComponent isEqualToString:@"SpringBoard"]) {
        SBCPUInstall();
    }
}
