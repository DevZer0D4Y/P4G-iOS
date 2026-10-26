// The start screen, in Persona 4 Golden's own colours (the yellow and black of the TV world): whether the game files
// are in place, importing them from the player's dump, the save folder, the settings that matter on a phone, and Play.
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "gamelib.h"
#include "importer.h"
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

// ------------------------------------------------------------------ importing the game from an NSP / NSZ / XCI / XCZ
// The dump is picked in the Files picker (read where it is, not copied), or found in the app's own folder (Files → On
// My iPhone → Persona 4 Golden). prod.keys likewise: picked along with it (kept in the app's private Library), or in
// the folder. ios/src/importer.c unpacks it into Documents/.import, then that replaces game/exefs and game/romfs.
static ImportJob g_imp;
static volatile BOOL g_importing;

static NSString *private_dir(void) {  // Library/Application Support: picked keys (not shown in Files)
    NSString *d = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
                   stringByAppendingPathComponent:@"keys"];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static NSString *find_keys(NSString *docs) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *p in @[[docs stringByAppendingPathComponent:@"prod.keys"], [docs stringByAppendingPathComponent:@"keys.txt"],
                          [private_dir() stringByAppendingPathComponent:@"prod.keys"]])
        if ([fm fileExistsAtPath:p]) return p;
    for (NSString *f in [fm contentsOfDirectoryAtPath:docs error:nil])
        if ([f.pathExtension.lowercaseString isEqualToString:@"keys"] && ![f.lowercaseString isEqualToString:@"title.keys"])
            return [docs stringByAppendingPathComponent:f];
    return nil;
}

static NSString *find_dump(NSString *docs) {  // a dump put in the app's folder (the largest, if there are several)
    NSString *best = nil;
    unsigned long long best_size = 0;
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:docs error:nil]) {
        if (!import_is_game_file(f.fileSystemRepresentation)) continue;
        NSString *p = [docs stringByAppendingPathComponent:f];
        unsigned long long sz = [NSFileManager.defaultManager attributesOfItemAtPath:p error:nil].fileSize;
        if (sz >= best_size) best = p, best_size = sz;
    }
    return best;
}

extern const GameLibTables *p4g_game_tables(void);

// after the ExeFS: the game's build must be the one this app's code was made from
static bool check_build(const char *exefs, char *why, size_t why_size) {
    char dir[1100], want[GAMELIB_FULL_ID_SIZE] = "";
    snprintf(dir, sizeof dir, "%s", exefs);
    char *slash = strrchr(dir, '/');
    if (slash) *slash = 0;
    if (!gamelib_full_id(dir, want, sizeof want)) {
        snprintf(why, why_size, "The game's code didn't unpack correctly.");
        return false;
    }
    const char *have = strrchr(p4g_game_tables()->id, '-'), *got = strrchr(want, '-');
    if (!have || !got || strcmp(have, got)) {
        snprintf(why, why_size, "That's another version of the game (build %s). This app runs version 1.0.0: pick the "
                                "base game without updates.", got ? got + 1 : "?");
        return false;
    }
    return true;
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
@interface P4GLauncher : UIViewController <UIDocumentPickerDelegate>
@property(nonatomic, copy) NSString *game;
@property(nonatomic) BOOL done;
@end

@implementation P4GLauncher {
    UILabel *_status, *_saveLabel;
    UIButton *_play, *_import;
    UIProgressView *_progress;
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

    _import = [UIButton buttonWithType:UIButtonTypeSystem];
    _import.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy];
    _import.titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_import setTitleColor:P4G_YELLOW forState:UIControlStateNormal];
    _import.backgroundColor = P4G_BLACK;
    _import.layer.cornerRadius = 6;
    _import.layer.borderColor = P4G_YELLOW.CGColor;
    _import.layer.borderWidth = 2;
    _import.contentEdgeInsets = UIEdgeInsetsMake(0, 16, 0, 16);
    [_import.heightAnchor constraintEqualToConstant:42].active = YES;
    [_import.widthAnchor constraintLessThanOrEqualToConstant:360].active = YES;
    [_import addTarget:self action:@selector(importTapped) forControlEvents:UIControlEventTouchUpInside];
    _progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progress.progressTintColor = P4G_YELLOW;
    _progress.trackTintColor = [UIColor colorWithWhite:1 alpha:0.15];
    [_progress.widthAnchor constraintEqualToConstant:320].active = YES;

    UIStackView *left = [[UIStackView alloc] initWithArrangedSubviews:@[title, _status, _progress, _saveLabel, _import, _play]];
    left.axis = UILayoutConstraintAxisVertical;
    left.alignment = UIStackViewAlignmentLeading;
    left.spacing = 16;
    left.translatesAutoresizingMaskIntoConstraints = NO;
    [left setCustomSpacing:22 afterView:_import];

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
    NSString *docs = [self.game stringByDeletingLastPathComponent];
    if (g_importing) {
        double f = g_imp.total > 0 ? (double)g_imp.done / (double)g_imp.total : 0;
        _status.text = [NSString stringWithFormat:@"Importing the game: %s… %d%%\nKeep the app open; it takes a few minutes.",
                                                  (const char *)g_imp.phase, (int)(fmin(f, 1) * 100)];
        _status.textColor = P4G_YELLOW;
        _progress.hidden = NO;
        _progress.progress = (float)fmin(f, 1);
        _import.hidden = YES;
        _play.enabled = NO;
        _play.alpha = 0.45;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{ [self refresh]; });
        return;
    }
    _progress.hidden = YES;
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
    NSString *dump = find_dump(docs), *keys = find_keys(docs);
    _import.hidden = ready;
    [_import setTitle:dump ? [NSString stringWithFormat:@"IMPORT %@", dump.lastPathComponent.uppercaseString]
                           : @"IMPORT GAME (NSP / NSZ / XCI)" forState:UIControlStateNormal];
    if (g_imp.error[0]) {
        _status.text = [NSString stringWithFormat:@"Import failed: %s", g_imp.error];
        _status.textColor = P4G_YELLOW;
    } else if (g_join_error) {
        _status.text = g_join_error;
        _status.textColor = P4G_YELLOW;
    } else if (ready) {
        _status.text = @"Game files found. Your save data stays in the Save folder.";
        _status.textColor = UIColor.whiteColor;
    } else {
        _status.text = dump && !keys
            ? [NSString stringWithFormat:@"Found %@. Now add your console's prod.keys: put it in the same folder, or tap "
                                         @"Import and pick it.", dump.lastPathComponent]
            : dump ? @"Your game dump is ready to import: tap Import."
            : @"No game files yet. Tap Import and pick your own Persona 4 Golden dump (NSP, NSZ, XCI or XCZ, version 1.0.0) "
              @"together with your prod.keys. Or put both in Files → On My iPhone → Persona 4 Golden.";
        _status.textColor = P4G_YELLOW;
    }
    _saveLabel.text = st.saves
        ? [NSString stringWithFormat:@"Save folder: %d file%s. Swap saves (e.g. from MeloNX) in Files → Persona 4 Golden → Save.",
                                     st.saves, st.saves == 1 ? "" : "s"]
        : @"No save yet. To continue a MeloNX / Ryujinx save, copy its files into Files → Persona 4 Golden → Save.";
    _play.enabled = ready;
    _play.alpha = ready ? 1 : 0.45;
}

// ------------------------------------------------------------------ import
- (void)importTapped {
    NSString *docs = [self.game stringByDeletingLastPathComponent];
    NSString *dump = find_dump(docs);
    if (dump && find_keys(docs)) { [self importFrom:[NSURL fileURLWithPath:dump] scoped:NO]; return; }
    UIDocumentPickerViewController *pick = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeItem] asCopy:NO];  // (read in place: the dump is ~9 GB)
    pick.allowsMultipleSelection = YES;
    pick.delegate = self;
    [self presentViewController:pick animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSString *docs = [self.game stringByDeletingLastPathComponent];
    NSURL *dump = nil;
    for (NSURL *u in urls) {
        NSString *name = u.lastPathComponent.lowercaseString;
        if (import_is_game_file(name.fileSystemRepresentation)) { dump = u; continue; }
        if (![name hasSuffix:@".keys"] && ![name hasSuffix:@".txt"]) continue;
        // keys: copied into the app's private Library (small; the picked file may not stay reachable)
        BOOL scoped = [u startAccessingSecurityScopedResource];
        NSData *d = [NSData dataWithContentsOfURL:u];
        if (scoped) [u stopAccessingSecurityScopedResource];
        NSString *to = [private_dir() stringByAppendingPathComponent:[name isEqualToString:@"title.keys"] ? @"title.keys" : @"prod.keys"];
        if (d) [d writeToFile:to atomically:YES];
    }
    g_imp.error[0] = 0;
    if (!dump && find_dump(docs)) dump = [NSURL fileURLWithPath:find_dump(docs)];
    if (dump && find_keys(docs)) [self importFrom:dump scoped:YES];
    else {
        snprintf(g_imp.error, sizeof g_imp.error, "%s", !dump ? "pick the game (an NSP, NSZ, XCI or XCZ file) too."
                                                             : "pick your prod.keys too (select both files in the picker).");
        [self refresh];
    }
}

- (void)importFrom:(NSURL *)url scoped:(BOOL)scoped {
    NSString *docs = [self.game stringByDeletingLastPathComponent], *keys = find_keys(docs), *game = self.game;
    NSString *tmp = [docs stringByAppendingPathComponent:@".import"];
    BOOL in_docs = [url.path.stringByStandardizingPath hasPrefix:docs.stringByStandardizingPath];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:tmp error:nil];
    memset(&g_imp, 0, sizeof g_imp);
    g_imp.check_exefs = check_build;
    g_imp.phase = "Opening the game file";
    g_importing = YES;
    UIApplication.sharedApplication.idleTimerDisabled = YES;  // (the screen locking would suspend it)
    __block UIBackgroundTaskIdentifier bg = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
        [UIApplication.sharedApplication endBackgroundTask:bg];
    }];
    [self refresh];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL access = scoped && [url startAccessingSecurityScopedResource];
        __block BOOL ok = NO;
        NSError *err = nil;
        // (coordinated: a file in iCloud Drive is downloaded first)
        [[NSFileCoordinator new] coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges error:&err
                                                 byAccessor:^(NSURL *u) {
            ok = import_game(u.path.fileSystemRepresentation, keys.fileSystemRepresentation, tmp.fileSystemRepresentation, &g_imp);
        }];
        if (err && !g_imp.error[0]) snprintf(g_imp.error, sizeof g_imp.error, "%s", err.localizedDescription.UTF8String);
        if (access) [url stopAccessingSecurityScopedResource];
        if (ok) {  // the new files replace the old ones
            [fm createDirectoryAtPath:game withIntermediateDirectories:YES attributes:nil error:nil];
            for (NSString *part in @[@"exefs", @"romfs"]) {
                NSString *to = [game stringByAppendingPathComponent:part];
                [fm removeItemAtPath:to error:nil];
                if (![fm moveItemAtPath:[tmp stringByAppendingPathComponent:part] toPath:to error:nil]) {
                    ok = NO;
                    snprintf(g_imp.error, sizeof g_imp.error, "Couldn't move the game files into place.");
                }
            }
        }
        [fm removeItemAtPath:tmp error:nil];
        fprintf(stderr, "[import] %s\n", ok ? "done" : g_imp.error);
        dispatch_async(dispatch_get_main_queue(), ^{
            g_importing = NO;
            UIApplication.sharedApplication.idleTimerDisabled = NO;
            [UIApplication.sharedApplication endBackgroundTask:bg];
            [self refresh];
            if (ok && in_docs) [self offerDelete:url.path];
        });
    });
}

- (void)offerDelete:(NSString *)path {
    unsigned long long sz = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileSize;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Game imported"
        message:[NSString stringWithFormat:@"The game no longer needs %@ (%.1f GB). Delete it to free the space?",
                                           path.lastPathComponent, sz / 1e9]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Keep" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        [self refresh];
    }]];
    [self presentViewController:a animated:YES completion:nil];
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
