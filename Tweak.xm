#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <signal.h>

static NSString *P(NSString*k){return [@"SBCPUFloating." stringByAppendingString:k];}
static NSUserDefaults *U(void){return NSUserDefaults.standardUserDefaults;}
static BOOL B(NSString*k,BOOL d){NSString*p=P(k);if(![U() objectForKey:p])[U() setBool:d forKey:p];return [U() boolForKey:p];}
static double N(NSString*k,double d){NSString*p=P(k);if(![U() objectForKey:p])[U() setDouble:d forKey:p];return [U() doubleForKey:p];}
static void WB(NSString*k,BOOL v){[U() setBool:v forKey:P(k)];[U() synchronize];}
static void WN(NSString*k,double v){[U() setDouble:v forKey:P(k)];[U() synchronize];}

static uint64_t Net(BOOL out){
    struct ifaddrs*a=NULL;if(getifaddrs(&a)!=0||!a)return 0;uint64_t n=0;
    for(struct ifaddrs*p=a;p;p=p->ifa_next){
        if(!p->ifa_data||!(p->ifa_flags&IFF_UP))continue;
        if(p->ifa_addr&&p->ifa_addr->sa_family==AF_LINK){
            struct if_data*d=(struct if_data*)p->ifa_data;n+=out?d->ifi_obytes:d->ifi_ibytes;
        }
    }freeifaddrs(a);return n;
}

@class SBCPUFloatingView;

@interface SBCPUSettingsController:UITableViewController
@property(nonatomic,weak) SBCPUFloatingView *monitor;
@end

@interface SBCPUFloatingView:UIView
@property UILabel*label;
@property NSTimer*timer;
@property uint64_t lastCPU,lastWall,lastIn,lastOut;
@property mach_timebase_info_data_t tb;
@property NSMutableArray*history;
@property NSTimeInterval highSince,alertSince;
@property BOOL respringLatched,alertLatched;
@end

@implementation SBCPUFloatingView
- (instancetype)init{
    self=[super initWithFrame:CGRectMake(N(@"x",18),N(@"y",150),N(@"width",160),N(@"height",48))];
    if(!self)return nil;
    mach_timebase_info(&_tb);self.backgroundColor=UIColor.blackColor;
    self.layer.cornerRadius=N(@"corner",10);self.layer.masksToBounds=YES;self.alpha=N(@"alpha",.82);
    self.history=[NSMutableArray array];
    _label=[[UILabel alloc]initWithFrame:self.bounds];_label.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    _label.textAlignment=NSTextAlignmentCenter;_label.numberOfLines=3;
    _label.font=[UIFont monospacedDigitSystemFontOfSize:N(@"font",13) weight:UIFontWeightMedium];
    _label.textColor=UIColor.greenColor;_label.text=@"SB CPU --";[self addSubview:_label];
    UITapGestureRecognizer*dt=[[UITapGestureRecognizer alloc]initWithTarget:self action:@selector(doubleTap:)];
    dt.numberOfTapsRequired=2;[self addGestureRecognizer:dt];
    UIPanGestureRecognizer*pan=[[UIPanGestureRecognizer alloc]initWithTarget:self action:@selector(pan:)];
    [pan requireGestureRecognizerToFail:dt];[self addGestureRecognizer:pan];
    [self restartSampling];return self;
}
- (void)restartSampling{
    [_timer invalidate];
    _timer=[NSTimer scheduledTimerWithTimeInterval:MAX(.2,MIN(10,N(@"refresh",1))) target:self selector:@selector(sample) userInfo:nil repeats:YES];
}
- (uint64_t)toNS:(uint64_t)t{return t*_tb.numer/_tb.denom;}
- (void)applyAppearance{
    self.layer.cornerRadius=N(@"corner",10);self.alpha=N(@"alpha",.82);
    self.label.font=[UIFont monospacedDigitSystemFontOfSize:N(@"font",13) weight:UIFontWeightMedium];
    CGRect f=self.frame;f.size=CGSizeMake(N(@"width",160),N(@"height",48));self.frame=f;
}
- (void)sample{
    if(!B(@"enabled",YES)){self.hidden=YES;return;}self.hidden=NO;
    task_thread_times_info_data_t i;mach_msg_type_number_t c=TASK_THREAD_TIMES_INFO_COUNT;
    if(task_info(mach_task_self(),TASK_THREAD_TIMES_INFO,(task_info_t)&i,&c)!=KERN_SUCCESS)return;
    uint64_t cpu=(uint64_t)i.user_time.seconds*1000000000ULL+(uint64_t)i.user_time.microseconds*1000ULL+(uint64_t)i.system_time.seconds*1000000000ULL+(uint64_t)i.system_time.microseconds*1000ULL;
    uint64_t wall=mach_absolute_time(),ib=Net(NO),ob=Net(YES);
    if(!_lastWall){_lastCPU=cpu;_lastWall=wall;_lastIn=ib;_lastOut=ob;return;}
    double ws=(double)[self toNS:wall-_lastWall]/1e9,pct=ws>0?(double)(cpu-_lastCPU)/1e9/ws*100:0;
    double down=ws>0?(double)(ib-_lastIn)/ws:0,up=ws>0?(double)(ob-_lastOut)/ws:0;
    _lastCPU=cpu;_lastWall=wall;_lastIn=ib;_lastOut=ob;
    NSInteger maxN=MAX(1,(NSInteger)ceil(N(@"peakWindow",60)/MAX(.2,N(@"refresh",1))));
    [_history addObject:@(pct)];while(_history.count>maxN)[_history removeObjectAtIndex:0];
    double peak=0;for(NSNumber*x in _history)peak=MAX(peak,x.doubleValue);
    double low=N(@"low",30),high=N(@"high",70);
    _label.textColor=pct<low?UIColor.greenColor:(pct<high?UIColor.yellowColor:UIColor.redColor);
    NSString*net=@"";
    if(B(@"network",YES))net=[NSString stringWithFormat:@"\n↓ %.1f %@  ↑ %.1f %@",down>=1048576?down/1048576:down/1024,down>=1048576?@"MB/s":@"KB/s",up>=1048576?up/1048576:up/1024,up>=1048576?@"MB/s":@"KB/s"];
    NSString*pk=B(@"peak",YES)?[NSString stringWithFormat:@"\nPeak %.1f%%",peak]:@"";
    _label.text=[NSString stringWithFormat:@"SB CPU %.1f%%%@%@",pct,pk,net];
    NSTimeInterval now=NSDate.date.timeIntervalSince1970,ath=N(@"alertThreshold",80);
    if(B(@"alert",YES)&&pct>=ath){if(!_alertSince)_alertSince=now;if(!_alertLatched&&now-_alertSince>=N(@"alertDuration",5)){_alertLatched=YES;if(B(@"alertSound",YES))AudioServicesPlaySystemSound(1005);}}
    else if(pct<ath-5){_alertSince=0;_alertLatched=NO;}
    double rth=N(@"respringThreshold",90);
    if(B(@"autoRespring",NO)&&pct>=rth){if(!_highSince)_highSince=now;if(!_respringLatched&&now-_highSince>=N(@"respringDuration",10)){_respringLatched=YES;WB(@"autoRespring",NO);dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{kill(getpid(),SIGTERM);});}}
    else if(pct<rth-5){_highSince=0;_respringLatched=NO;}
}
- (void)pan:(UIPanGestureRecognizer*)g{
    if(B(@"passthrough",NO))return;UIView*s=self.superview;if(!s)return;
    CGPoint t=[g translationInView:s];self.center=CGPointMake(self.center.x+t.x,self.center.y+t.y);[g setTranslation:CGPointZero inView:s];
    CGRect b=s.bounds;CGFloat hw=self.bounds.size.width/2,hh=self.bounds.size.height/2;
    self.center=CGPointMake(MAX(hw,MIN(CGRectGetWidth(b)-hw,self.center.x)),MAX(hh,MIN(CGRectGetHeight(b)-hh,self.center.y)));
    WN(@"x",self.frame.origin.x);WN(@"y",self.frame.origin.y);
}
- (void)doubleTap:(UITapGestureRecognizer*)g{
    if(g.state!=UIGestureRecognizerStateRecognized||B(@"passthrough",NO))return;
    UIViewController*root=self.window.rootViewController;if(!root)return;
    SBCPUSettingsController*vc=[SBCPUSettingsController new];vc.monitor=self;vc.title=@"SB CPU Floating";
    UINavigationController*nav=[[UINavigationController alloc]initWithRootViewController:vc];nav.modalPresentationStyle=UIModalPresentationPageSheet;
    [root presentViewController:nav animated:YES completion:nil];
}
@end

@implementation SBCPUSettingsController
- (void)viewDidLoad{
    [super viewDidLoad];self.navigationItem.title=@"SB CPU Floating";
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc]initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
}
- (void)done{[self dismissViewControllerAnimated:YES completion:nil];}
- (NSInteger)numberOfSectionsInTableView:(UITableView*)t{return 6;}
- (NSString*)tableView:(UITableView*)t titleForHeaderInSection:(NSInteger)s{return @[@"基础",@"外观",@"CPU",@"提醒",@"自动注销",@"交互"][s];}
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s{return @[@4,@4,@5,@3,@3,@2][s];}
- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)p{
    UITableViewCell*c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    NSString*title=@"";NSString*val=@"";
    if(p.section==0){title=@[@"启用悬浮窗",@"显示网速",@"显示峰值",@"刷新间隔"][p.row];val=p.row==3?[NSString stringWithFormat:@"%.1f 秒",N(@"refresh",1)]:@"";}
    if(p.section==1){title=@[@"宽度",@"高度",@"透明度",@"圆角"][p.row];double v=@[N(@"width",160),N(@"height",48),N(@"alpha",.82),N(@"corner",10)][p.row];val=[NSString stringWithFormat:@"%.2f",v];}
    if(p.section==2){title=@[@"低 CPU 阈值",@"高 CPU 阈值",@"峰值统计时间",@"刷新间隔",@"字体大小"][p.row];double v=@[N(@"low",30),N(@"high",70),N(@"peakWindow",60),N(@"refresh",1),N(@"font",13)][p.row];val=[NSString stringWithFormat:@"%.1f",v];}
    if(p.section==3){title=@[@"高 CPU 提醒",@"提醒阈值",@"持续时间"][p.row];}
    if(p.section==4){title=@[@"自动注销",@"注销阈值",@"持续时间"][p.row];}
    if(p.section==5){title=@[@"穿透模式",@"拖动位置"][p.row];}
    c.textLabel.text=title;
    BOOL sw=(p.section==0&&p.row<3)||(p.section==3&&p.row==0)||(p.section==4&&p.row==0)||(p.section==5&&p.row==0);
    if(sw){
        UISwitch*s=[UISwitch new];BOOL on=NO;
        if(p.section==0)on=B(@[@"enabled",@"network",@"peak"][p.row],YES);
        if(p.section==3)on=B(@"alert",YES);
        if(p.section==4)on=B(@"autoRespring",NO);
        if(p.section==5)on=B(@"passthrough",NO);
        s.on=on;s.tag=p.section*100+p.row;[s addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];c.accessoryView=s;
    }else c.detailTextLabel.text=val;
    return c;
}
- (void)toggle:(UISwitch*)s{
    NSInteger sec=s.tag/100,row=s.tag%100;
    if(sec==0)WB(@[@"enabled",@"network",@"peak"][row],s.on);
    if(sec==3)WB(@"alert",s.on);
    if(sec==4)WB(@"autoRespring",s.on);
    if(sec==5)WB(@"passthrough",s.on);
    [self.tableView reloadData];
}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)p{
    [t deselectRowAtIndexPath:p animated:YES];
    if(p.section==5)return;
    NSString*key=nil;double min=0,max=0,cur=0;NSString*title=@"";
    NSArray*keys=@[@[@"enabled",@"network",@"peak",@"refresh"],@[@"width",@"height",@"alpha",@"corner"],@[@"low",@"high",@"peakWindow",@"refresh",@"font"],@[@"alert",@"alertThreshold",@"alertDuration"],@[@"autoRespring",@"respringThreshold",@"respringDuration"]];
    if((p.section==0&&p.row==3)){key=@"refresh";min=.2;max=10;cur=N(key,1);title=@"刷新间隔（秒）";}
    else if(p.section==1){key=keys[1][p.row];min=p.row==2?.2:1;max=p.row==0?300:p.row==1?150:p.row==2?1:40;cur=N(key,@[@160,@48,@.82,@10][p.row].doubleValue);title=@[@"宽度",@"高度",@"透明度",@"圆角"][p.row];}
    else if(p.section==2){key=keys[2][p.row];min=p.row<2?1:p.row==2?5:p.row==3?.2:9;max=p.row<2?100:p.row==2?600:p.row==3?10:24;cur=N(key,@[@30,@70,@60,@1,@13][p.row].doubleValue);title=@[@"低 CPU 阈值 %",@"高 CPU 阈值 %",@"峰值统计秒数",@"刷新间隔秒",@"字体大小"][p.row];}
    else if(p.section==3&&p.row>0){key=keys[3][p.row];min=1;max=p.row==1?100:300;cur=N(key,p.row==1?80:5);title=p.row==1?@"提醒阈值（%）":@"提醒持续时间（秒）";}
    else if(p.section==4&&p.row>0){key=keys[4][p.row];min=1;max=p.row==1?100:300;cur=N(key,p.row==1?90:10);title=p.row==1?@"自动注销阈值（%）":@"自动注销持续时间（秒）";}
    else return;
    UIAlertController*a=[UIAlertController alertControllerWithTitle:title message:[NSString stringWithFormat:@"范围 %.1f ～ %.1f",min,max] preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField*x){x.text=[NSString stringWithFormat:@"%.2f",cur];x.keyboardType=UIKeyboardTypeDecimalPad;}];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction*x){double v=MAX(min,MIN(max,a.textFields.firstObject.text.doubleValue));WN(key,v);if([key isEqualToString:@"refresh"])[self.monitor restartSampling];[self.monitor applyAppearance];[t reloadData];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

static void Install(void){
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)1*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        UIApplication*app=UIApplication.sharedApplication;if(!app)return;UIWindow*t=nil;
        for(UIWindow*w in app.windows)if(!w.hidden&&w.alpha>0&&w.windowLevel==UIWindowLevelNormal){t=w;break;}
        if(!t)return;for(UIView*v in t.subviews)if(v.tag==0x53424350)return;
        SBCPUFloatingView*v=[SBCPUFloatingView new];v.tag=0x53424350;[t addSubview:v];
    });
}
%ctor{
    if(![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"])return;
    B(@"enabled",YES);B(@"network",YES);B(@"peak",YES);B(@"alert",YES);B(@"alertSound",YES);B(@"autoRespring",NO);B(@"passthrough",NO);
    N(@"refresh",1);N(@"peakWindow",60);N(@"low",30);N(@"high",70);N(@"alertThreshold",80);N(@"alertDuration",5);N(@"respringThreshold",90);N(@"respringDuration",10);
    N(@"width",160);N(@"height",48);N(@"alpha",.82);N(@"corner",10);N(@"font",13);N(@"x",18);N(@"y",150);
    Install();
}
