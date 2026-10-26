// On-screen controller for Persona 4 Golden, drawn in the game's own HUD style (touch_style.h: the weather badge, the
// speaker name plates, the date box, the clock ring). It feeds runtime/hle/input.c (input_touch_set) like a Switch
// controller:
//   left stick   floating: a touch in the lower left places it where the thumb lands
//   right stick  a drag on the right side away from the buttons (the camera in dungeons)
//   A B X Y      lower right, Switch layout       d-pad  left, above the stick
//   ZL L         top left                         ZR R   right, below the game's date and weather
//   - +          top centre                       L3 R3  bottom corners
// Hidden while a game controller is connected (Settings "Touch pad": Auto), or always shown / never.
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>
#include <SDL3/SDL.h>
#include <math.h>

#include "settings.h"
#include "touch_style.h"

void input_touch_set(uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry);

@interface P4GTouchView : UIView
@end

@implementation P4GTouchView {
    TouchLayout _lay;
    uint64_t _held;
    NSMapTable<UITouch *, NSNumber *> *_owner;  // touch -> control (button id, 100 = left stick, 101 = right stick)
    CGPoint _lsOrigin, _lsPos, _rsOrigin, _rsPos;
    UITouch *_lsTouch, *_rsTouch;
    UIImpactFeedbackGenerator *_haptic;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.multipleTouchEnabled = YES;
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _owner = [NSMapTable weakToStrongObjectsMapTable];
        _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UIEdgeInsets in = self.safeAreaInsets;
    touch_layout(&_lay, self.bounds.size.width, self.bounds.size.height, (TouchInsets){in.top, in.left, in.bottom, in.right},
                 g_settings.touch_scale);
    [self setNeedsDisplay];
}

- (CGFloat)stickRadius { return _lay.stick_r; }

- (void)drawRect:(CGRect)rect {
    CGFloat alpha = g_settings.touch_opacity > 0 ? g_settings.touch_opacity : 0.85;
    touch_draw(UIGraphicsGetCurrentContext(), &_lay, _held, alpha, _lsTouch != nil, _lsOrigin, _lsPos, _rsTouch != nil, _rsOrigin);
}

// ------------------------------------------------------------------ touches
- (int)buttonAt:(CGPoint)p {
    for (int i = 0; i < _lay.n; i++)
        if (CGRectContainsPoint(CGRectInset(_lay.btn[i].r, -6 * _lay.s, -6 * _lay.s), p)) return _lay.btn[i].id;
    return -1;
}

static int32_t axis(CGFloat v) { return (int32_t)lround(fmax(-1, fmin(1, v)) * 32767); }

- (void)publish {
    uint64_t held = 0;
    for (UITouch *t in _owner) {
        int c = [_owner objectForKey:t].intValue;
        if (c < NB) held |= 1ull << c;
    }
    if ((held & ~_held) && g_settings.touch_haptics) [_haptic impactOccurred];
    _held = held;
    CGFloat R = [self stickRadius];
    int32_t lx = 0, ly = 0, rx = 0, ry = 0;
    if (_lsTouch) {
        CGFloat dx = (_lsPos.x - _lsOrigin.x) / R, dy = (_lsPos.y - _lsOrigin.y) / R;
        lx = axis(dx), ly = axis(-dy);  // (the Switch's y is up)
    }
    if (_rsTouch) {
        CGFloat dx = (_rsPos.x - _rsOrigin.x) / (R * 0.8), dy = (_rsPos.y - _rsOrigin.y) / (R * 0.8);
        rx = axis(dx), ry = axis(-dy);
    }
    input_touch_set(held, lx, ly, rx, ry);
    [self setNeedsDisplay];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        int b = [self buttonAt:p];
        if (b >= 0) [_owner setObject:@(b) forKey:t];
        else if (!_lsTouch && p.x < W * 0.42 && p.y > H * 0.30) {  // left stick, placed where the thumb lands
            CGFloat R = [self stickRadius];
            _lsTouch = t;
            _lsOrigin = CGPointMake(fmax(p.x, R + 8), fmin(p.y, H - R - 8));
            _lsPos = p;
            [_owner setObject:@100 forKey:t];
        } else if (!_rsTouch && p.x > W * 0.5) {  // camera drag
            _rsTouch = t;
            _rsOrigin = _rsPos = p;
            [_owner setObject:@101 forKey:t];
        }
    }
    [self publish];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *t in touches) {
        NSNumber *o = [_owner objectForKey:t];
        if (!o) continue;
        CGPoint p = [t locationInView:self];
        if (t == _lsTouch) {
            CGFloat R = [self stickRadius], dx = p.x - _lsOrigin.x, dy = p.y - _lsOrigin.y, m = hypot(dx, dy);
            if (m > R) _lsOrigin = CGPointMake(p.x - dx / m * R, p.y - dy / m * R);  // (the base follows a long drag)
            _lsPos = p;
        } else if (t == _rsTouch) {
            _rsPos = p;
        } else {  // a finger sliding from one button to the next presses the new one
            int b = [self buttonAt:p];
            if (b >= 0 && b != o.intValue) [_owner setObject:@(b) forKey:t];
        }
    }
    [self publish];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *t in touches) {
        if (t == _lsTouch) _lsTouch = nil;
        if (t == _rsTouch) _rsTouch = nil;
        [_owner removeObjectForKey:t];
    }
    [self publish];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self touchesEnded:touches withEvent:event]; }
@end

// ------------------------------------------------------------------ attaching it to the game's window
static P4GTouchView *g_touch;

static void update_visibility(void) {
    bool pad = GCController.controllers.count > 0;
    bool show = g_settings.touch_mode == TOUCH_ON || (g_settings.touch_mode == TOUCH_AUTO && !pad);
    g_touch.hidden = !show;
    if (!show) input_touch_set(0, 0, 0, 0, 0);
}

// Called once the game's SDL window exists (runtime/nvn/metal.m ui_window_init)
void ios_touch_attach(SDL_Window *window) {
    UIWindow *w = (__bridge UIWindow *)SDL_GetPointerProperty(SDL_GetWindowProperties(window),
                                                              SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
    UIView *host = w.rootViewController.view ?: w;
    if (!host) return;
    g_touch = [[P4GTouchView alloc] initWithFrame:host.bounds];
    [host addSubview:g_touch];
    for (NSString *n in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification])
        [NSNotificationCenter.defaultCenter addObserverForName:n object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { update_visibility(); }];
    update_visibility();
}
