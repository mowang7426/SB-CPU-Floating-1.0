#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <signal.h>

static NSString *K(NSString *s){ return [@"SBCPUFloating." stringByAppendingString:s]; }
static NSUserDefaults *UD(void){ return [NSUserDefaults standardUserDefaults]; }
static double GD(NSString *k,double d){ NSString *x=K(k); if([UD() objectForKey:x]==nil)[UD() setDouble:d forKey:x]; return [UD() doubleForKey:x]; }
static BOOL GB(NSString *k,BOOL d){ NSString *x=K(k); if([UD() objectForKey:x]==nil)[UD() setBool:d forKey:x]; return [UD() boolForKey:x]; }
static void SD(NSString*k,double v){[UD() setDouble:v forKey:K(k)];[UD() synchronize];}
static void SB(NSString*k,BOOL v){[UD() setBool:v forKey:K(k)];[UD() synchronize];}

static uint64_t NetBytes(BOOL out){
    struct ifaddrs *a=NULL; if(getifaddrs(&a)!=0||!a)return 0;
    uint64_t n=0;
    for(struct ifaddrs *p=a;p;p=p->ifa_next){
        if(!p->ifa_data || !(p->ifa_flags&IFF_UP))continue;
        if(p->ifa_addr && p->ifa_addr->sa_family==AF_LINK){
            struct if_data *d=(struct if_data*)p->ifa_data;
            n += out ? d->ifi_obytes : d->ifi_ibytes;
        }
    }
    freeifaddrs(a); return n;
}

@interface SBCPUFloatingView:UIView
@property UILabel *label;
@property CADisplayLink *timer;
@property mach_timebase_info_data_t tb;
@property uint64_t lastCPU,lastWall,lastIn,lastOut;
@property NSMutableArray *peaks;
@property NSTimeInterval highSince,alertSince;
@property BOOL respringLatched,alertLatched;
@end

@implementation SBCPUFloatingView

- (instancetype)init{
    CGFloat w=GD(@"width",150), h=GD(@"height",48);
    self=[super initWithFrame:CGRectMake(GD(@"x",18),GD(@"y",150),w,h)];
    if(!self)return nil;
    mach_timebase_info(&_tb);
    self.backgroundColor=[[UIColor blackColor] colorWithAlphaComponent:1];
    self.layer.cornerRadius=GD(@"corner",10);
    self.layer.masksToBounds=YES;
    self.alpha=GD(@"alpha",.82);
    self.peaks=[NSMutableArray array];

    _label=[[UILabel alloc]initWithFrame:self.bounds];
    _label.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    _label.textAlignment=NSTextAlignmentCenter;
    _label.numberOfLines=3;
    _label.font=[UIFont monospacedDigitSystemFontOfSize:GD(@"font",13) weight:UIFontWeightMedium];
    _label.textColor=UIColor.whiteColor;
    _label.text=@"SB CPU --";
    [self addSubview:_label];

    UITapGestureRecognizer *dt=[[UITapGestureRecognizer alloc]initWithTarget:self action:@selector(openSettings)];
    dt.numberOfTapsRequired=2;
    [self addGestureRecognizer:dt];

    UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc]initWithTarget:self action:@selector(pan:)];
    [pan requireGestureRecognizerToFail:dt];
    [self addGestureRecognizer:pan];

    [self restartTimer];
    return self;
}

- (void)restartTimer{
    [_timer invalidate];
    _timer=[CADisplayLink displayLinkWithTarget:self selector:@selector(sample)];
    double interval=MAX(.2,MIN(5,GD(@"refresh",1)));
    _timer.preferredFramesPerSecond=MAX(1,MIN(10,(NSInteger)llround(1.0/interval)));
    [_timer addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)dealloc{[_timer invalidate];}
- (uint64_t)ns:(uint64_t)t{return t*_tb.numer/_tb.denom;}

- (void)sample{
    if(!GB(@"enabled",YES)){self.hidden=YES;return;} self.hidden=NO;
    task_thread_times_info_data_t i; mach_msg_type_number_t c=TASK_THREAD_TIMES_INFO_COUNT;
    if(task_info(mach_task_self(),TASK_THREAD_TIMES_INFO,(task_info_t)&i,&c)!=KERN_SUCCESS)return;
    uint64_t cpu=(uint64_t)i.user_time.seconds*1000000000ULL+(uint64_t)i.user_time.microseconds*1000ULL+
                 (uint64_t)i.system_time.seconds*1000000000ULL+(uint64_t)i.system_time.microseconds*1000ULL;
    uint64_t wall=mach_absolute_time(), ib=NetBytes(NO), ob=NetBytes(YES);
    if(!_lastWall){_lastCPU=cpu;_lastWall=wall;_lastIn=ib;_lastOut=ob;return;}
    double ws=(double)[self ns:wall-_lastWall]/1e9;
    double pct=ws>0?(double)(cpu-_lastCPU)/1e9/ws*100:0;
    double down=ws>0?(double)(ib-_lastIn)/ws:0;
    double up=ws>0?(double)(ob-_lastOut)/ws:0;
    _lastCPU=cpu;_lastWall=wall;_lastIn=ib;_lastOut=ob;

    NSInteger maxN=MAX(1,(NSInteger)ceil(GD(@"peakWindow",60)/MAX(.2,GD(@"refresh",1))));
    [_peaks addObject:@(pct)]; while(_peaks.count>maxN)[_peaks removeObjectAtIndex:0];
    double peak=0;for(NSNumber*n in _peaks)peak=MAX(peak,n.doubleValue);

    double low=GD(@"low",30),high=GD(@"high",70);
    _label.textColor=pct<low?UIColor.greenColor:(pct<high?UIColor.yellowColor:UIColor.redColor);

    NSString *net=@"";
    if(GB(@"network",YES)){
        net=[NSString stringWithFormat:@"\n↓ %.1f %@  ↑ %.1f %@",down>=1048576?down/1048576:down/1024,down>=1048576?@"MB/s":@"KB/s",up>=1048576?up/1048576:up/1024,up>=1048576?@"MB/s":@"KB/s"];
    }
    NSString *pk=GB(@"peak",YES)?[NSString stringWithFormat:@"\nPeak %.1f%%",peak]:@"";
    _label.text=[NSString stringWithFormat:@"SB CPU %.1f%%%@%@",pct,pk,net];

    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    double ath=GD(@"alertThreshold",80);
    if(GB(@"alert",YES)&&pct>=ath){if(!_alertSince)_alertSince=now;if(!_alertLatched&&now-_alertSince>=GD(@"alertDuration",5)){_alertLatched=YES;AudioServicesPlaySystemSound(1005);}}
    else if(pct<ath-5){_alertSince=0;_alertLatched=NO;}

    double rth=GD(@"respringThreshold",90);
    if(GB(@"autoRespring",NO)&&pct>=rth){
        if(!_highSince)_highSince=now;
        if(!_respringLatched&&now-_highSince>=GD(@"respringDuration",10)){
            _respringLatched=YES;SB(@"autoRespring",NO);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{kill(getpid(),SIGTERM);});
        }
    }else if(pct<rth-5){_highSince=0;_respringLatched=NO;}
}

- (void)pan:(UIPanGestureRecognizer*)g{
    if(GB(@"passthrough",NO))return;
    UIView*s=self.superview;if(!s)return;
    CGPoint t=[g translationInView:s];self.center=CGPointMake(self.center.x+t.x,self.center.y+t.y);
    [g setTranslation:CGPointZero inView:s];
    CGRect b=s.bounds;CGFloat hw=self.bounds.size.width/2,hh=self.bounds.size.height/2;
    self.center=CGPointMake(MAX(hw,MIN(CGRectGetWidth(b)-hw,self.center.x)),MAX(hh,MIN(CGRectGetHeight(b)-hh,self.center.y)));
    SD(@"x",self.frame.origin.x);SD(@"y",self.frame.origin.y);
}

- (void)openSettings{
    UIViewController *vc=self.window.rootViewController;if(!vc)return;
    UIAlertController*a=[UIAlertController alertControllerWithTitle:@"SB CPU Floating 2.0" message:@"双击打开设置。自动注销默认关闭；触发后会自动关闭，防止循环注销。" preferredStyle:UIAlertControllerStyleAlert];

    [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"网速：%@",GB(@"network",YES)?@"开":@"关"] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction*x){SB(@"network",!GB(@"network",YES));}]];
    [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"峰值：%@",GB(@"peak",YES)?@"开":@"关"] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction*x){SB(@"peak",!GB(@"peak",YES));}]];
    [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"穿透：%@",GB(@"passthrough",NO)?@"开":@"关"] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction*x){SB(@"passthrough",!GB(@"passthrough",NO));}]];

    [a addAction:[UIAlertAction actionWithTitle:@"刷新间隔" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction*x){
        UIAlertController*b=[UIAlertController alertControllerWithTitle:@"刷新间隔（秒）" message:@"0.2～5 秒，默认 1 秒" preferredStyle:UIAlertControllerStyleAlert];
        [b addTextFieldWithConfigurationHandler:^(UITextField*t){t.text=[NSString stringWithFormat:@"%.1f",GD(@"refresh",1)];t.keyboardType=UIKeyboardTypeDecimalPad;}];
        [b addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction*x){SD(@"refresh",MAX(.2,MIN(5,b.textFields.firstObject.text.doubleValue)));[self restartTimer];}]];
        [b addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[vc presentViewController:b animated:YES completion:nil];
    }]];

    [a addAction:[UIAlertAction actionWithTitle:@"外观" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction*x){
        UIAlertController*b=[UIAlertController alertControllerWithTitle:@"外观" message:@"输入：透明度(0.2-1)、圆角、字体大小" preferredStyle:UIAlertControllerStyleAlert];
        for(NSString*v in @[[NSString stringWithFormat:@"%.2f",GD(@"alpha",.82)],[NSString stringWithFormat:@"%.0f",GD(@"corner",10)],[NSString stringWithFormat:@"%.0f",GD(@"font",13)]]) [b addTextFieldWithConfigurationHandler:^(UITextField*t){t.text=v;t.keyboardType=UIKeyboardTypeDecimalPad;}];
        [b addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction*x){SD(@"alpha",MAX(.2,MIN(1,b.textFields[0].text.doubleValue)));SD(@"corner",MAX(0,MIN(30,b.textFields[1].text.doubleValue)));SD(@"font",MAX(9,MIN(24,b.textFields[2].text.doubleValue)));self.alpha=GD(@"alpha",.82);self.layer.cornerRadius=GD(@"corner",10);self.label.font=[UIFont monospacedDigitSystemFontOfSize:GD(@"font",13) weight:UIFontWeightMedium];}]];
        [b addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[vc presentViewController:b animated:YES completion:nil];
    }]];

    [a addAction:[UIAlertAction actionWithTitle:@"高 CPU / 自动注销" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction*x){
        UIAlertController*b=[UIAlertController alertControllerWithTitle:@"保护设置" message:@"依次输入：提醒阈值%、自动注销阈值%、持续秒数" preferredStyle:UIAlertControllerStyleAlert];
        for(NSString*v in @[[NSString stringWithFormat:@"%.0f",GD(@"alertThreshold",80)],[NSString stringWithFormat:@"%.0f",GD(@"respringThreshold",90)],[NSString stringWithFormat:@"%.0f",GD(@"respringDuration",10)]]) [b addTextFieldWithConfigurationHandler:^(UITextField*t){t.text=v;t.keyboardType=UIKeyboardTypeDecimalPad;}];
        [b addAction:[UIAlertAction actionWithTitle:@"保存并开启自动注销" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction*x){SD(@"alertThreshold",MAX(1,b.textFields[0].text.doubleValue));SD(@"respringThreshold",MAX(1,b.textFields[1].text.doubleValue));SD(@"respringDuration",MAX(1,b.textFields[2].text.doubleValue));SB(@"autoRespring",YES);}]];
        [b addAction:[UIAlertAction actionWithTitle:@"仅保存并关闭自动注销" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction*x){SD(@"alertThreshold",MAX(1,b.textFields[0].text.doubleValue));SD(@"respringThreshold",MAX(1,b.textFields[1].text.doubleValue));SD(@"respringDuration",MAX(1,b.textFields[2].text.doubleValue));SB(@"autoRespring",NO);}]];
        [b addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[vc presentViewController:b animated:YES completion:nil];
    }]];

    [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}
@end

static void Install(void){
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        UIApplication*app=UIApplication.sharedApplication;if(!app)return;
        UIWindow*t=nil;for(UIWindow*w in app.windows)if(!w.hidden&&w.alpha>0&&w.windowLevel==UIWindowLevelNormal){t=w;break;}
        if(!t)return;for(UIView*v in t.subviews)if(v.tag==0x53424350)return;
        SBCPUFloatingView*v=[[SBCPUFloatingView alloc]init];v.tag=0x53424350;[t addSubview:v];
    });
}

%ctor{
    if(![[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"])return;
    GB(@"enabled",YES);GB(@"network",YES);GB(@"peak",YES);GB(@"alert",YES);GB(@"autoRespring",NO);GB(@"passthrough",NO);
    GD(@"refresh",1);GD(@"low",30);GD(@"high",70);GD(@"peakWindow",60);GD(@"alertThreshold",80);GD(@"alertDuration",5);
    GD(@"respringThreshold",90);GD(@"respringDuration",10);GD(@"alpha",.82);GD(@"font",13);GD(@"corner",10);GD(@"width",150);GD(@"height",48);
    Install();
}
