#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <signal.h>

#pragma mark - Preferences

static NSString *P(NSString *key) {
    return [@"SBCPUFloating." stringByAppendingString:key];
}

static NSUserDefaults *U(void) {
    return [NSUserDefaults standardUserDefaults];
}

static BOOL B(NSString *key, BOOL defaultValue) {
    NSString *p = P(key);

    if (![U() objectForKey:p]) {
        [U() setBool:defaultValue forKey:p];
        [U() synchronize];
    }

    return [U() boolForKey:p];
}

static double N(NSString *key, double defaultValue) {
    NSString *p = P(key);

    if (![U() objectForKey:p]) {
        [U() setDouble:defaultValue forKey:p];
        [U() synchronize];
    }

    return [U() doubleForKey:p];
}

static void WB(NSString *key, BOOL value) {
    [U() setBool:value forKey:P(key)];
    [U() synchronize];
}

static void WN(NSString *key, double value) {
    [U() setDouble:value forKey:P(key)];
    [U() synchronize];
}

#pragma mark - Network

static uint64_t NetBytes(BOOL outgoing) {

    struct ifaddrs *interfaces = NULL;

    if (getifaddrs(&interfaces) != 0 || interfaces == NULL) {
        return 0;
    }

    uint64_t total = 0;

    for (struct ifaddrs *p = interfaces; p != NULL; p = p->ifa_next) {

        if (!p->ifa_data) {
            continue;
        }

        if (!(p->ifa_flags & IFF_UP)) {
            continue;
        }

        if (p->ifa_addr &&
            p->ifa_addr->sa_family == AF_LINK) {

            struct if_data *data =
                (struct if_data *)p->ifa_data;

            if (outgoing) {
                total += data->ifi_obytes;
            } else {
                total += data->ifi_ibytes;
            }
        }
    }

    freeifaddrs(interfaces);

    return total;
}

#pragma mark - Forward

@class SBCPUFloatingView;

@interface SBCPUSettingsController : UITableViewController

@property(nonatomic, weak) SBCPUFloatingView *monitor;

@end

#pragma mark - Floating View

@interface SBCPUFloatingView : UIView

@property(nonatomic,strong) UILabel *label;
@property(nonatomic,strong) NSTimer *timer;

@property(nonatomic) uint64_t lastCPU;
@property(nonatomic) uint64_t lastWall;
@property(nonatomic) uint64_t lastIn;
@property(nonatomic) uint64_t lastOut;

@property(nonatomic) mach_timebase_info_data_t tb;

@property(nonatomic,strong) NSMutableArray *history;

@property(nonatomic) NSTimeInterval highSince;
@property(nonatomic) NSTimeInterval alertSince;

@property(nonatomic) BOOL respringLatched;
@property(nonatomic) BOOL alertLatched;

@end

#pragma mark - Floating View Implementation

@implementation SBCPUFloatingView

- (instancetype)init {

    CGRect frame = CGRectMake(
        N(@"x", 18),
        N(@"y", 150),
        N(@"width", 160),
        N(@"height", 48)
    );

    self = [super initWithFrame:frame];

    if (!self) {
        return nil;
    }

    mach_timebase_info(&_tb);

    self.backgroundColor = UIColor.blackColor;

    self.layer.cornerRadius = N(@"corner", 10);
    self.layer.masksToBounds = YES;

    self.alpha = N(@"alpha", 0.82);

    self.history = [NSMutableArray array];

    #pragma mark Label

    _label = [[UILabel alloc] initWithFrame:self.bounds];

    _label.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;

    _label.textAlignment = NSTextAlignmentCenter;

    _label.numberOfLines = 3;

    _label.font =
        [UIFont monospacedDigitSystemFontOfSize:N(@"font", 13)
                                         weight:UIFontWeightMedium];

    _label.textColor = UIColor.greenColor;

    _label.text = @"SB CPU --";

    [self addSubview:_label];

    #pragma mark Double Tap

    UITapGestureRecognizer *doubleTap =
        [[UITapGestureRecognizer alloc]
            initWithTarget:self
            action:@selector(doubleTap:)];

    doubleTap.numberOfTapsRequired = 2;

    [self addGestureRecognizer:doubleTap];

    #pragma mark Pan

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc]
            initWithTarget:self
            action:@selector(pan:)];

    [pan requireGestureRecognizerToFail:doubleTap];

    [self addGestureRecognizer:pan];

    [self updateInteractionState];

    [self restartSampling];

    return self;
}

#pragma mark - Interaction

- (void)updateInteractionState {

    /*
     穿透模式开启时：

     userInteractionEnabled = NO

     这样触摸事件会真正交给下面的 App。
    */

    BOOL passthrough = B(@"passthrough", NO);

    self.userInteractionEnabled = !passthrough;
}

#pragma mark - Sampling

- (void)restartSampling {

    [_timer invalidate];
    _timer = nil;

    double refresh = N(@"refresh", 1.0);

    refresh = MAX(0.2, MIN(10.0, refresh));

    _timer =
        [NSTimer scheduledTimerWithTimeInterval:refresh
                                         target:self
                                       selector:@selector(sample)
                                       userInfo:nil
                                        repeats:YES];
}

#pragma mark - Time

- (uint64_t)toNS:(uint64_t)value {

    if (_tb.denom == 0) {
        return 0;
    }

    return value * _tb.numer / _tb.denom;
}

#pragma mark - Appearance

- (void)applyAppearance {

    self.layer.cornerRadius =
        N(@"corner", 10);

    self.alpha =
        N(@"alpha", 0.82);

    self.label.font =
        [UIFont monospacedDigitSystemFontOfSize:
            N(@"font", 13)
                                         weight:UIFontWeightMedium];

    CGRect frame = self.frame;

    frame.size.width =
        N(@"width", 160);

    frame.size.height =
        N(@"height", 48);

    self.frame = frame;

    [self updateInteractionState];
}

#pragma mark - CPU Sample

- (void)sample {

    if (!B(@"enabled", YES)) {

        self.hidden = YES;

        return;
    }

    self.hidden = NO;

    task_thread_times_info_data_t info;

    mach_msg_type_number_t count =
        TASK_THREAD_TIMES_INFO_COUNT;

    kern_return_t result =
        task_info(
            mach_task_self(),
            TASK_THREAD_TIMES_INFO,
            (task_info_t)&info,
            &count
        );

    if (result != KERN_SUCCESS) {
        return;
    }

    uint64_t cpu =
        (uint64_t)info.user_time.seconds *
        1000000000ULL;

    cpu +=
        (uint64_t)info.user_time.microseconds *
        1000ULL;

    cpu +=
        (uint64_t)info.system_time.seconds *
        1000000000ULL;

    cpu +=
        (uint64_t)info.system_time.microseconds *
        1000ULL;

    uint64_t wall =
        mach_absolute_time();

    uint64_t inputBytes =
        NetBytes(NO);

    uint64_t outputBytes =
        NetBytes(YES);

    /*
     第一次采样只建立基准。
    */

    if (_lastWall == 0) {

        _lastCPU = cpu;
        _lastWall = wall;

        _lastIn = inputBytes;
        _lastOut = outputBytes;

        return;
    }

    double wallSeconds =
        (double)[self toNS:(wall - _lastWall)]
        / 1000000000.0;

    if (wallSeconds <= 0) {
        return;
    }

    double cpuPercent =
        (double)(cpu - _lastCPU)
        / 1000000000.0
        / wallSeconds
        * 100.0;

    /*
     防止异常情况下出现负值。
    */

    if (cpuPercent < 0) {
        cpuPercent = 0;
    }

    double download =
        (double)(inputBytes - _lastIn)
        / wallSeconds;

    double upload =
        (double)(outputBytes - _lastOut)
        / wallSeconds;

    _lastCPU = cpu;
    _lastWall = wall;

    _lastIn = inputBytes;
    _lastOut = outputBytes;

    #pragma mark Peak

    double refresh =
        MAX(0.2, N(@"refresh", 1));

    double peakWindow =
        MAX(1, N(@"peakWindow", 60));

    NSInteger maxHistory =
        MAX(
            1,
            (NSInteger)ceil(
                peakWindow / refresh
            )
        );

    [_history addObject:@(cpuPercent)];

    while (_history.count > maxHistory) {
        [_history removeObjectAtIndex:0];
    }

    double peak = 0;

    for (NSNumber *number in _history) {

        peak =
            MAX(
                peak,
                [number doubleValue]
            );
    }

    #pragma mark Color

    double low =
        N(@"low", 30);

    double high =
        N(@"high", 70);

    if (cpuPercent < low) {

        self.label.textColor =
            UIColor.greenColor;

    } else if (cpuPercent < high) {

        self.label.textColor =
            UIColor.yellowColor;

    } else {

        self.label.textColor =
            UIColor.redColor;
    }

    #pragma mark Network Text

    NSString *networkText = @"";

    if (B(@"network", YES)) {

        double downValue;
        double upValue;

        NSString *downUnit;
        NSString *upUnit;

        if (download >= 1048576.0) {

            downValue =
                download / 1048576.0;

            downUnit = @"MB/s";

        } else {

            downValue =
                download / 1024.0;

            downUnit = @"KB/s";
        }

        if (upload >= 1048576.0) {

            upValue =
                upload / 1048576.0;

            upUnit = @"MB/s";

        } else {

            upValue =
                upload / 1024.0;

            upUnit = @"KB/s";
        }

        networkText =
            [NSString stringWithFormat:
                @"\n↓ %.1f %@ ↑ %.1f %@",
                downValue,
                downUnit,
                upValue,
                upUnit];
    }

    #pragma mark Peak Text

    NSString *peakText = @"";

    if (B(@"peak", YES)) {

        peakText =
            [NSString stringWithFormat:
                @"\nPeak %.1f%%",
                peak];
    }

    self.label.text =
        [NSString stringWithFormat:
            @"SB CPU %.1f%%%@%@",
            cpuPercent,
            peakText,
            networkText];

    #pragma mark High CPU Alert

    NSTimeInterval now =
        [[NSDate date] timeIntervalSince1970];

    double alertThreshold =
        N(@"alertThreshold", 80);

    double alertDuration =
        N(@"alertDuration", 5);

    if (B(@"alert", YES) &&
        cpuPercent >= alertThreshold) {

        if (_alertSince == 0) {
            _alertSince = now;
        }

        if (!_alertLatched &&
            now - _alertSince >= alertDuration) {

            _alertLatched = YES;

            if (B(@"alertSound", YES)) {

                AudioServicesPlaySystemSound(1005);
            }
        }

    } else if (cpuPercent < alertThreshold - 5) {

        _alertSince = 0;

        _alertLatched = NO;
    }

    #pragma mark Automatic Logout / Respring

    double respringThreshold =
        N(@"respringThreshold", 90);

    double respringDuration =
        N(@"respringDuration", 10);

    if (B(@"autoRespring", NO) &&
        cpuPercent >= respringThreshold) {

        if (_highSince == 0) {
            _highSince = now;
        }

        if (!_respringLatched &&
            now - _highSince >= respringDuration) {

            _respringLatched = YES;

            /*
             执行一次后自动关闭开关，
             防止 SpringBoard 重启后再次触发。
            */

            WB(@"autoRespring", NO);

            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    (int64_t)(0.5 *
                    NSEC_PER_SEC)
                ),
                dispatch_get_main_queue(),
                ^{

                    kill(
                        getpid(),
                        SIGTERM
                    );
                }
            );
        }

    } else if (cpuPercent < respringThreshold - 5) {

        _highSince = 0;

        _respringLatched = NO;
    }
}

#pragma mark - Drag

- (void)pan:(UIPanGestureRecognizer *)gesture {

    if (B(@"passthrough", NO)) {
        return;
    }

    UIView *superview =
        self.superview;

    if (!superview) {
        return;
    }

    CGPoint translation =
        [gesture translationInView:superview];

    CGPoint newCenter =
        CGPointMake(
            self.center.x + translation.x,
            self.center.y + translation.y
        );

    self.center = newCenter;

    [gesture
        setTranslation:CGPointZero
        inView:superview];

    /*
     限制悬浮窗不能拖出屏幕。
    */

    CGRect bounds =
        superview.bounds;

    CGFloat halfWidth =
        self.bounds.size.width / 2.0;

    CGFloat halfHeight =
        self.bounds.size.height / 2.0;

    self.center =
        CGPointMake(
            MAX(
                halfWidth,
                MIN(
                    CGRectGetWidth(bounds) - halfWidth,
                    self.center.x
                )
            ),
            MAX(
                halfHeight,
                MIN(
                    CGRectGetHeight(bounds) - halfHeight,
                    self.center.y
                )
            )
        );

    /*
     保存位置。
    */

    WN(@"x", self.frame.origin.x);
    WN(@"y", self.frame.origin.y);
}

#pragma mark - Double Tap

- (void)doubleTap:(UITapGestureRecognizer *)gesture {

    if (B(@"passthrough", NO)) {
        return;
    }

    if (gesture.state !=
        UIGestureRecognizerStateRecognized) {
        return;
    }

    UIViewController *root =
        self.window.rootViewController;

    if (!root) {
        return;
    }

    SBCPUSettingsController *settings =
        [SBCPUSettingsController new];

    settings.monitor = self;

    settings.title =
        @"SB CPU Floating";

    UINavigationController *navigation =
        [[UINavigationController alloc]
            initWithRootViewController:settings];

    navigation.modalPresentationStyle =
        UIModalPresentationPageSheet;

    [root
        presentViewController:navigation
                     animated:YES
                   completion:nil];
}

@end

#pragma mark - Settings Controller

@implementation SBCPUSettingsController

#pragma mark View

- (void)viewDidLoad {

    [super viewDidLoad];

    self.navigationItem.title =
        @"SB CPU Floating";

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:
                UIBarButtonSystemItemDone
            target:self
            action:@selector(done)];

    self.tableView =
        [[UITableView alloc]
            initWithFrame:CGRectZero
            style:UITableViewStyleInsetGrouped];
}

- (void)done {

    [self dismissViewControllerAnimated:YES
                             completion:nil];
}

#pragma mark Sections

- (NSInteger)numberOfSectionsInTableView:
    (UITableView *)tableView {

    return 6;
}

- (NSString *)tableView:
    (UITableView *)tableView
    titleForHeaderInSection:
    (NSInteger)section {

    NSArray *titles = @[
        @"基础",
        @"外观",
        @"CPU",
        @"提醒",
        @"自动注销",
        @"交互"
    ];

    return [titles objectAtIndex:section];
}

- (NSInteger)tableView:
    (UITableView *)tableView
    numberOfRowsInSection:
    (NSInteger)section {

    NSArray *counts = @[
        @4,
        @4,
        @5,
        @3,
        @3,
        @2
    ];

    NSNumber *number =
        [counts objectAtIndex:section];

    return [number integerValue];
}

#pragma mark Cell

- (UITableViewCell *)tableView:
    (UITableView *)tableView
    cellForRowAtIndexPath:
    (NSIndexPath *)indexPath {

    UITableViewCell *cell =
        [[UITableViewCell alloc]
            initWithStyle:
                UITableViewCellStyleValue1
            reuseIdentifier:nil];

    NSString *title = @"";
    NSString *value = @"";

    NSInteger section =
        indexPath.section;

    NSInteger row =
        indexPath.row;

    #pragma mark Basic

    if (section == 0) {

        NSArray *titles = @[
            @"启用悬浮窗",
            @"显示网速",
            @"显示峰值",
            @"刷新间隔"
        ];

        title =
            [titles objectAtIndex:row];

        if (row == 3) {

            value =
                [NSString stringWithFormat:
                    @"%.1f 秒",
                    N(@"refresh", 1)];
        }
    }

    #pragma mark Appearance

    else if (section == 1) {

        NSArray *titles = @[
            @"宽度",
            @"高度",
            @"透明度",
            @"圆角"
        ];

        title =
            [titles objectAtIndex:row];

        NSArray *values = @[
            @(N(@"width", 160)),
            @(N(@"height", 48)),
            @(N(@"alpha", 0.82)),
            @(N(@"corner", 10))
        ];

        NSNumber *number =
            [values objectAtIndex:row];

        value =
            [NSString stringWithFormat:
                @"%.2f",
                [number doubleValue]];
    }

    #pragma mark CPU

    else if (section == 2) {

        NSArray *titles = @[
            @"低 CPU 阈值",
            @"高 CPU 阈值",
            @"峰值统计时间",
            @"刷新间隔",
            @"字体大小"
        ];

        title =
            [titles objectAtIndex:row];

        NSArray *values = @[
            @(N(@"low", 30)),
            @(N(@"high", 70)),
            @(N(@"peakWindow", 60)),
            @(N(@"refresh", 1)),
            @(N(@"font", 13))
        ];

        NSNumber *number =
            [values objectAtIndex:row];

        value =
            [NSString stringWithFormat:
                @"%.1f",
                [number doubleValue]];
    }

    #pragma mark Alert

    else if (section == 3) {

        NSArray *titles = @[
            @"高 CPU 提醒",
            @"提醒阈值",
            @"持续时间"
        ];

        title =
            [titles objectAtIndex:row];

        if (row == 1) {

            value =
                [NSString stringWithFormat:
                    @"%.1f%%",
                    N(@"alertThreshold", 80)];

        } else if (row == 2) {

            value =
                [NSString stringWithFormat:
                    @"%.1f 秒",
                    N(@"alertDuration", 5)];
        }
    }

    #pragma mark Auto Respring

    else if (section == 4) {

        NSArray *titles = @[
            @"CPU 达标后自动注销",
            @"注销阈值",
            @"持续时间"
        ];

        title =
            [titles objectAtIndex:row];

        if (row == 1) {

            value =
                [NSString stringWithFormat:
                    @"%.1f%%",
                    N(@"respringThreshold", 90)];

        } else if (row == 2) {

            value =
                [NSString stringWithFormat:
                    @"%.1f 秒",
                    N(@"respringDuration", 10)];
        }
    }

    #pragma mark Interaction

    else if (section == 5) {

        NSArray *titles = @[
            @"穿透模式",
            @"拖动位置"
        ];

        title =
            [titles objectAtIndex:row];

        if (row == 1) {

            value = @"拖动悬浮窗即可保存";
        }
    }

    cell.textLabel.text =
        title;

    /*
     Switch
    */

    BOOL isSwitch = NO;

    if (section == 0 &&
        row < 3) {

        isSwitch = YES;

    } else if (section == 3 &&
               row == 0) {

        isSwitch = YES;

    } else if (section == 4 &&
               row == 0) {

        isSwitch = YES;

    } else if (section == 5 &&
               row == 0) {

        isSwitch = YES;
    }

    if (isSwitch) {

        UISwitch *switchControl =
            [UISwitch new];

        BOOL on = NO;

        if (section == 0) {

            NSArray *keys = @[
                @"enabled",
                @"network",
                @"peak"
            ];

            NSString *key =
                [keys objectAtIndex:row];

            on = B(key, YES);

        } else if (section == 3) {

            on = B(@"alert", YES);

        } else if (section == 4) {

            on = B(@"autoRespring", NO);

        } else if (section == 5) {

            on = B(@"passthrough", NO);
        }

        switchControl.on = on;

        switchControl.tag =
            section * 100 + row;

        [switchControl
            addTarget:self
            action:@selector(toggle:)
            forControlEvents:UIControlEventValueChanged];

        cell.accessoryView =
            switchControl;

    } else {

        cell.detailTextLabel.text =
            value;
    }

    return cell;
}

#pragma mark Toggle

- (void)toggle:(UISwitch *)sender {

    NSInteger section =
        sender.tag / 100;

    NSInteger row =
        sender.tag % 100;

    if (section == 0) {

        NSArray *keys = @[
            @"enabled",
            @"network",
            @"peak"
        ];

        NSString *key =
            [keys objectAtIndex:row];

        WB(key, sender.on);

    } else if (section == 3) {

        WB(@"alert", sender.on);

    } else if (section == 4) {

        WB(@"autoRespring", sender.on);

    } else if (section == 5) {

        WB(@"passthrough", sender.on);

        [self.monitor
            updateInteractionState];
    }

    [self.tableView reloadData];
}

#pragma mark Edit

- (void)tableView:
    (UITableView *)tableView
    didSelectRowAtIndexPath:
    (NSIndexPath *)indexPath {

    [tableView
        deselectRowAtIndexPath:indexPath
        animated:YES];

    NSInteger section =
        indexPath.section;

    NSInteger row =
        indexPath.row;

    /*
     位置说明不需要编辑。
    */

    if (section == 5) {
        return;
    }

    NSString *key = nil;

    double minimum = 0;
    double maximum = 0;
    double current = 0;

    NSString *title = nil;

    #pragma mark Refresh

    if (section == 0 &&
        row == 3) {

        key = @"refresh";

        minimum = 0.2;
        maximum = 10;

        current =
            N(key, 1);

        title =
            @"刷新间隔（秒）";
    }

    #pragma mark Appearance

    else if (section == 1) {

        NSArray *keys = @[
            @"width",
            @"height",
            @"alpha",
            @"corner"
        ];

        NSArray *defaults = @[
            @160,
            @48,
            @0.82,
            @10
        ];

        key =
            [keys objectAtIndex:row];

        NSNumber *defaultNumber =
            [defaults objectAtIndex:row];

        current =
            N(key,
              [defaultNumber doubleValue]);

        if (row == 0) {

            minimum = 80;
            maximum = 400;

        } else if (row == 1) {

            minimum = 30;
            maximum = 200;

        } else if (row == 2) {

            minimum = 0.1;
            maximum = 1.0;

        } else {

            minimum = 0;
            maximum = 50;
        }

        NSArray *titles = @[
            @"宽度",
            @"高度",
            @"透明度",
            @"圆角"
        ];

        title =
            [titles objectAtIndex:row];
    }

    #pragma mark CPU

    else if (section == 2) {

        NSArray *keys = @[
            @"low",
            @"high",
            @"peakWindow",
            @"refresh",
            @"font"
        ];

        NSArray *defaults = @[
            @30,
            @70,
            @60,
            @1,
            @13
        ];

        key =
            [keys objectAtIndex:row];

        NSNumber *defaultNumber =
            [defaults objectAtIndex:row];

        current =
            N(key,
              [defaultNumber doubleValue]);

        if (row < 2) {

            minimum = 1;
            maximum = 100;

        } else if (row == 2) {

            minimum = 5;
            maximum = 600;

        } else if (row == 3) {

            minimum = 0.2;
            maximum = 10;

        } else {

            minimum = 9;
            maximum = 30;
        }

        NSArray *titles = @[
            @"低 CPU 阈值（%）",
            @"高 CPU 阈值（%）",
            @"峰值统计时间（秒）",
            @"刷新间隔（秒）",
            @"字体大小"
        ];

        title =
            [titles objectAtIndex:row];
    }

    #pragma mark Alert

    else if (section == 3 &&
             row > 0) {

        NSArray *keys = @[
            @"alert",
            @"alertThreshold",
            @"alertDuration"
        ];

        key =
            [keys objectAtIndex:row];

        if (row == 1) {

            minimum = 1;
            maximum = 100;

            current =
                N(key, 80);

            title =
                @"提醒阈值（%）";

        } else {

            minimum = 1;
            maximum = 300;

            current =
                N(key, 5);

            title =
                @"提醒持续时间（秒）";
        }
    }

    #pragma mark Auto Respring

    else if (section == 4 &&
             row > 0) {

        NSArray *keys = @[
            @"autoRespring",
            @"respringThreshold",
            @"respringDuration"
        ];

        key =
            [keys objectAtIndex:row];

        if (row == 1) {

            minimum = 1;
            maximum = 100;

            current =
                N(key, 90);

            title =
                @"自动注销阈值（%）";

        } else {

            minimum = 1;
            maximum = 300;

            current =
                N(key, 10);

            title =
                @"自动注销持续时间（秒）";
        }
    }

    else {

        return;
    }

    UIAlertController *alert =
        [UIAlertController
            alertControllerWithTitle:title
            message:
                [NSString stringWithFormat:
                    @"范围 %.1f ～ %.1f",
                    minimum,
                    maximum]
            preferredStyle:
                UIAlertControllerStyleAlert];

    [alert
        addTextFieldWithConfigurationHandler:
        ^(UITextField *textField) {

            textField.text =
                [NSString stringWithFormat:
                    @"%.2f",
                    current];

            textField.keyboardType =
                UIKeyboardTypeDecimalPad;
        }];

    __weak typeof(self) weakSelf =
        self;

    [alert
        addAction:
        [UIAlertAction
            actionWithTitle:@"保存"
            style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {

                double value =
                    alert.textFields.firstObject.text.doubleValue;

                value =
                    MAX(
                        minimum,
                        MIN(
                            maximum,
                            value
                        )
                    );

                WN(key, value);

                SBCPUFloatingView *monitor =
                    weakSelf.monitor;

                if ([key isEqualToString:@"refresh"]) {

                    [monitor restartSampling];
                }

                [monitor applyAppearance];

                [weakSelf.tableView reloadData];
            }]];

    [alert
        addAction:
        [UIAlertAction
            actionWithTitle:@"取消"
            style:UIAlertActionStyleCancel
            handler:nil]];

    [self
        presentViewController:alert
                     animated:YES
                   completion:nil];
}

@end

#pragma mark - Install

static void InstallSBCPUFloating(void) {

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(1 *
            NSEC_PER_SEC)
        ),
        dispatch_get_main_queue(),
        ^{

            UIApplication *application =
                UIApplication.sharedApplication;

            if (!application) {
                return;
            }

            UIWindow *targetWindow = nil;

            for (UIWindow *window
                 in application.windows) {

                if (!window.hidden &&
                    window.alpha > 0 &&
                    window.windowLevel ==
                        UIWindowLevelNormal) {

                    targetWindow = window;

                    break;
                }
            }

            if (!targetWindow) {
                return;
            }

            for (UIView *view
                 in targetWindow.subviews) {

                if (view.tag ==
                    0x53424350) {

                    return;
                }
            }

            SBCPUFloatingView *view =
                [SBCPUFloatingView new];

            view.tag =
                0x53424350;

            [targetWindow
                addSubview:view];
        }
    );
}

#pragma mark - Constructor

%ctor {

    /*
     只注入 SpringBoard。
    */

    if (![[NSProcessInfo processInfo].processName
            isEqualToString:@"SpringBoard"]) {

        return;
    }

    /*
     基础设置
    */

    B(@"enabled", YES);
    B(@"network", YES);
    B(@"peak", YES);

    /*
     高 CPU 提醒
    */

    B(@"alert", YES);
    B(@"alertSound", YES);

    /*
     自动注销
    */

    B(@"autoRespring", NO);

    /*
     穿透
    */

    B(@"passthrough", NO);

    /*
     CPU
    */

    N(@"refresh", 1);
    N(@"peakWindow", 60);

    N(@"low", 30);
    N(@"high", 70);

    /*
     Alert
    */

    N(@"alertThreshold", 80);
    N(@"alertDuration", 5);

    /*
     Auto Respring
    */

    N(@"respringThreshold", 90);
    N(@"respringDuration", 10);

    /*
     Appearance
    */

    N(@"width", 160);
    N(@"height", 48);
    N(@"alpha", 0.82);
    N(@"corner", 10);
    N(@"font", 13);

    /*
     Position
    */

    N(@"x", 18);
    N(@"y", 150);

    InstallSBCPUFloating();
}
