// The start screen, in Persona 4 Golden's own colours (the yellow and black of the TV world): whether the game files
// are in place, the save folder, the settings that matter on a phone, and Play.
#import <UIKit/UIKit.h>

#include "launcher.h"
#include "settings.h"

#define P4G_YELLOW [UIColor colorWithRed:1.0 green:0.894 blue:0.0 alpha:1]
#define P4G_BLACK [UIColor colorWithWhite:0.06 alpha:1]

// ------------------------------------------------------------------ the game files
typedef struct { BOOL exefs, romfs; int saves; } FilesState;

static FilesState files_state(NSString *game) {
    NSFileManager *fm = NSFileManager.defaultManager;
    FilesState st = {0};
    st.exefs = [fm fileExistsAtPath:[game stringByAppendingPathComponent:@"exefs/main"]] &&
               [fm fileExistsAtPath:[game stringByAppendingPathComponent:@"exefs/sdk"]] &&
               [fm fileExistsAtPath:[game stringByAppendingPathComponent:@"exefs/main.npdm"]];
    st.romfs = [fm fileExistsAtPath:[game stringByAppendingPathComponent:@"romfs/data.cpk"]];
    NSString *save = [[game stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Save"];
    for (NSString *f in [fm contentsOfDirectoryAtPath:save error:nil])
        if (![f hasPrefix:@"."]) st.saves++;
    return st;
}

// ------------------------------------------------------------------ split files
// The Mac's USB copy (devicectl, ios/push-game-files.sh) stops at 4 GB a file, so data.cpk (7.2 GB) goes over as
// data.cpk.part1, .part2, ...: joined here in place (the later parts appended to part1, each deleted once in), so it
// takes no extra space. Off the main thread, the launcher showing the progress.
static NSArray<NSString *> *split_files(NSString *dir) {  // the names that have a .part1 waiting
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil])
        if ([f hasSuffix:@".part1"]) [out addObject:[f substringToIndex:f.length - 6]];
    return out;
}

static volatile int g_join_pct = -1;  // -1: not joining
static NSString *g_join_error;

static void join_split_files(NSString *dir) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *name in split_files(dir)) {
        NSString *base = [dir stringByAppendingPathComponent:name];
        NSString *first = [base stringByAppendingString:@".part1"];
        unsigned long long total = 0;
        int n = 1;
        for (;; n++) {
            NSDictionary *a = [fm attributesOfItemAtPath:[base stringByAppendingFormat:@".part%d", n] error:nil];
            if (!a) break;
            total += a.fileSize;
        }
        n--;
        fprintf(stderr, "[files] joining %s from %d parts (%llu bytes)\n", name.UTF8String, n, total);
        FILE *out = fopen(first.fileSystemRepresentation, "ab");
        if (!out) { g_join_error = [NSString stringWithFormat:@"Couldn't open %@.part1", name]; return; }
        unsigned long long done = [fm attributesOfItemAtPath:first error:nil].fileSize;
        size_t chunk = 16 << 20;
        char *buf = malloc(chunk);
        for (int i = 2; i <= n; i++) {
            NSString *part = [base stringByAppendingFormat:@".part%d", i];
            FILE *in = fopen(part.fileSystemRepresentation, "rb");
            if (!in) { g_join_error = [NSString stringWithFormat:@"Couldn't read %@.part%d", name, i]; break; }
            size_t got;
            while ((got = fread(buf, 1, chunk, in)) > 0) {
                if (fwrite(buf, 1, got, out) != got) { g_join_error = @"Not enough space on the device to join the game files"; break; }
                done += got;
                g_join_pct = (int)(done * 100 / (total ? total : 1));
            }
            fclose(in);
            if (g_join_error) break;
            fflush(out);
            [fm removeItemAtPath:part error:nil];  // (appended: a crash from here on resumes at the next part)
        }
        free(buf);
        fclose(out);
        if (g_join_error) { fprintf(stderr, "[files] %s\n", g_join_error.UTF8String); return; }
        [fm removeItemAtPath:base error:nil];
        [fm moveItemAtPath:first toPath:base error:nil];
        fprintf(stderr, "[files] %s ready\n", name.UTF8String);
    }
}

// ------------------------------------------------------------------ the TV-static backdrop: diagonal stripes
@interface P4GStripes : UIView
@end
@implementation P4GStripes
- (void)drawRect:(CGRect)rect {
    CGContextRef g = UIGraphicsGetCurrentContext();
    [P4G_BLACK setFill];
    CGContextFillRect(g, self.bounds);
    [[P4G_YELLOW colorWithAlphaComponent:0.07] setFill];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    for (CGFloat x = -h; x < w; x += 46) {
        CGContextMoveToPoint(g, x, h);
        CGContextAddLineToPoint(g, x + 18, h);
        CGContextAddLineToPoint(g, x + 18 + h, 0);
        CGContextAddLineToPoint(g, x + h, 0);
        CGContextFillPath(g);
    }
}
@end

// ------------------------------------------------------------------ the screen
@interface P4GLauncher : UIViewController
@property(nonatomic, copy) NSString *game;
@property(nonatomic) BOOL done;
@end

@implementation P4GLauncher {
    UILabel *_status, *_saveLabel;
    UIButton *_play;
    UISegmentedControl *_fps, *_touch, *_res;
    UISwitch *_showFps;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }

static UILabel *label(NSString *text, CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.numberOfLines = 0;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

static UISegmentedControl *segments(NSArray<NSString *> *items, NSInteger selected) {
    UISegmentedControl *s = [[UISegmentedControl alloc] initWithItems:items];
    s.selectedSegmentIndex = selected;
    s.selectedSegmentTintColor = P4G_YELLOW;
    [s setTitleTextAttributes:@{NSForegroundColorAttributeName: P4G_BLACK,
                                NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightHeavy]}
                     forState:UIControlStateSelected];
    [s setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor,
                                NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]}
                     forState:UIControlStateNormal];
    s.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    s.translatesAutoresizingMaskIntoConstraints = NO;
    return s;
}

static UIStackView *row(NSString *title, UIView *control) {
    UILabel *t = label(title.uppercaseString, 12, UIFontWeightHeavy, [P4G_YELLOW colorWithAlphaComponent:0.9]);
    [t setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [t.widthAnchor constraintEqualToConstant:118].active = YES;
    UIStackView *r = [[UIStackView alloc] initWithArrangedSubviews:@[t, control]];
    r.axis = UILayoutConstraintAxisHorizontal;
    r.alignment = UIStackViewAlignmentCenter;
    r.spacing = 12;
    return r;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    P4GStripes *bg = [P4GStripes new];
    bg.frame = self.view.bounds;
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bg.contentMode = UIViewContentModeRedraw;
    [self.view addSubview:bg];

    // left: the title block, the status and Play
    UILabel *persona = label(@"PERSONA", 46, UIFontWeightBlack, P4G_YELLOW);
    persona.transform = CGAffineTransformMakeRotation(-0.05);
    UILabel *four = label(@"4", 74, UIFontWeightBlack, P4G_BLACK);
    four.textAlignment = NSTextAlignmentCenter;
    four.backgroundColor = P4G_YELLOW;
    four.layer.cornerRadius = 10;
    four.layer.masksToBounds = YES;
    [four.widthAnchor constraintEqualToConstant:84].active = YES;
    UILabel *golden = label(@"GOLDEN", 22, UIFontWeightHeavy, UIColor.whiteColor);
    UIStackView *title = [[UIStackView alloc] initWithArrangedSubviews:@[persona, four, golden]];
    title.axis = UILayoutConstraintAxisHorizontal;
    title.alignment = UIStackViewAlignmentCenter;
    title.spacing = 10;

    _status = label(@"", 13, UIFontWeightSemibold, UIColor.whiteColor);
    _saveLabel = label(@"", 12, UIFontWeightRegular, [UIColor colorWithWhite:1 alpha:0.75]);

    _play = [UIButton buttonWithType:UIButtonTypeSystem];
    [_play setTitle:@"PLAY" forState:UIControlStateNormal];
    _play.titleLabel.font = [UIFont systemFontOfSize:30 weight:UIFontWeightBlack];
    [_play setTitleColor:P4G_BLACK forState:UIControlStateNormal];
    [_play setTitleColor:[UIColor colorWithWhite:0.3 alpha:1] forState:UIControlStateDisabled];
    _play.backgroundColor = P4G_YELLOW;
    _play.layer.cornerRadius = 6;
    _play.layer.borderColor = UIColor.whiteColor.CGColor;
    _play.layer.borderWidth = 3;
    _play.transform = CGAffineTransformMakeRotation(-0.035);
    [_play.heightAnchor constraintEqualToConstant:64].active = YES;
    [_play.widthAnchor constraintEqualToConstant:230].active = YES;
    [_play addTarget:self action:@selector(play) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *left = [[UIStackView alloc] initWithArrangedSubviews:@[title, _status, _saveLabel, _play]];
    left.axis = UILayoutConstraintAxisVertical;
    left.alignment = UIStackViewAlignmentLeading;
    left.spacing = 16;
    left.translatesAutoresizingMaskIntoConstraints = NO;
    [left setCustomSpacing:26 afterView:_saveLabel];

    // right: settings
    _fps = segments(@[@"60 FPS", @"30 FPS"], g_settings.fps_cap == FPS_30 ? 1 : 0);
    _touch = segments(@[@"Auto", @"On", @"Off"], g_settings.touch_mode);
    _res = segments(@[@"Full", @"75%", @"50%"],
                    g_settings.res_auto || g_settings.res_mode == RES_MATCH ? 0 : g_settings.res_mode == RES_Q75 ? 1 : 2);
    _showFps = [UISwitch new];
    _showFps.on = g_settings.show_fps;
    _showFps.onTintColor = P4G_YELLOW;
    UILabel *hint = label(@"Touch controls hide while a controller is connected. Auto: shown without one.", 11,
                          UIFontWeightRegular, [UIColor colorWithWhite:1 alpha:0.6]);
    UIStackView *right = [[UIStackView alloc] initWithArrangedSubviews:@[
        row(@"Frame rate", _fps), row(@"Resolution", _res), row(@"Touch pad", _touch), row(@"Show FPS", _showFps), hint
    ]];
    right.axis = UILayoutConstraintAxisVertical;
    right.spacing = 14;
    right.translatesAutoresizingMaskIntoConstraints = NO;
    right.layoutMargins = UIEdgeInsetsMake(18, 18, 18, 18);
    right.layoutMarginsRelativeArrangement = YES;
    right.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    right.layer.cornerRadius = 12;
    right.layer.borderColor = [P4G_YELLOW colorWithAlphaComponent:0.5].CGColor;
    right.layer.borderWidth = 1.5;

    [self.view addSubview:left];
    [self.view addSubview:right];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [left.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:28],
        [left.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [left.trailingAnchor constraintLessThanOrEqualToAnchor:right.leadingAnchor constant:-24],
        [right.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [right.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [right.widthAnchor constraintEqualToConstant:380],
        [_status.widthAnchor constraintLessThanOrEqualToConstant:360],
        [_saveLabel.widthAnchor constraintLessThanOrEqualToConstant:360],
    ]];
    [self refresh];
    // the player adds the files from the Files app while this screen is up: look again when the app comes back
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh)
                                               name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)refresh {
    NSString *romfs = [self.game stringByAppendingPathComponent:@"romfs"];
    if (g_join_pct < 0 && !g_join_error && split_files(romfs).count) {  // files sent over in parts: join them first
        g_join_pct = 0;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            join_split_files(romfs);
            dispatch_async(dispatch_get_main_queue(), ^{ g_join_pct = -1; [self refresh]; });
        });
    }
    if (g_join_pct >= 0) {
        _status.text = [NSString stringWithFormat:@"Preparing the game files (joining data.cpk): %d%%", g_join_pct];
        _status.textColor = P4G_YELLOW;
        _play.enabled = NO;
        _play.alpha = 0.45;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{ [self refresh]; });
        return;
    }
    FilesState st = files_state(self.game);
    BOOL ready = st.exefs && st.romfs && !g_join_error;
    if (g_join_error) {
        _status.text = g_join_error;
        _status.textColor = P4G_YELLOW;
    } else if (ready) {
        _status.text = @"Game files found. Your save data stays in the Save folder.";
        _status.textColor = UIColor.whiteColor;
    } else {
        _status.text = [NSString stringWithFormat:
            @"Game files missing%@%@.\nFiles app → On My iPhone → Persona 4 Golden → game: put your own dump's exefs "
            @"(main, main.npdm, sdk, subsdk0) in game/exefs and its romfs (data.cpk, ...) in game/romfs.",
            st.exefs ? @"" : @": exefs", st.romfs ? @"" : (st.exefs ? @": romfs" : @", romfs")];
        _status.textColor = P4G_YELLOW;
    }
    _saveLabel.text = st.saves
        ? [NSString stringWithFormat:@"Save folder: %d file%s. Swap saves (e.g. from MeloNX) in Files → Persona 4 Golden → Save.",
                                     st.saves, st.saves == 1 ? "" : "s"]
        : @"No save yet. To continue a MeloNX / Ryujinx save, copy its files into Files → Persona 4 Golden → Save.";
    _play.enabled = ready;
    _play.alpha = ready ? 1 : 0.45;
}

- (void)play {
    g_settings.fps_cap = _fps.selectedSegmentIndex == 1 ? FPS_30 : FPS_60;
    g_settings.touch_mode = (int)_touch.selectedSegmentIndex;
    g_settings.show_fps = _showFps.on;
    if (_res.selectedSegmentIndex == 0) g_settings.res_auto = true, g_settings.res_mode = RES_MATCH;
    else g_settings.res_auto = false, g_settings.res_mode = _res.selectedSegmentIndex == 1 ? RES_Q75 : RES_Q50;
    settings_save();
    self.done = YES;
}
@end

// ------------------------------------------------------------------ showing it before the game's window exists
static UIWindowScene *active_scene(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)s;
    return nil;
}

static UIWindow *g_window;

static UIWindow *launcher_window(UIViewController *vc) {
    UIWindowScene *scene = nil;
    for (int i = 0; i < 200 && !(scene = active_scene()); i++)  // (the scene may still be connecting)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
    UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    w.rootViewController = vc;
    w.windowLevel = UIWindowLevelNormal + 1;
    [w makeKeyAndVisible];
    return w;
}

void p4g_launcher_run(NSString *game_dir) {
    if (getenv("P4G_SKIP_LAUNCHER") && files_state(game_dir).exefs && files_state(game_dir).romfs &&
        !split_files([game_dir stringByAppendingPathComponent:@"romfs"]).count) return;
    P4GLauncher *vc = [P4GLauncher new];
    vc.game = game_dir;
    g_window = launcher_window(vc);
    while (!vc.done) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    g_window.hidden = YES;
    g_window = nil;
}

void p4g_launcher_fatal(NSString *message) {
    UIViewController *vc = [UIViewController new];
    P4GStripes *bg = [P4GStripes new];
    vc.view = bg;
    UILabel *l = label(message, 17, UIFontWeightSemibold, P4G_YELLOW);
    l.textAlignment = NSTextAlignmentCenter;
    [bg addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.centerXAnchor constraintEqualToAnchor:bg.centerXAnchor], [l.centerYAnchor constraintEqualToAnchor:bg.centerYAnchor],
        [l.widthAnchor constraintLessThanOrEqualToAnchor:bg.widthAnchor multiplier:0.8],
    ]];
    g_window = launcher_window(vc);
    for (;;) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1, false);
}
