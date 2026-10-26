// The on-screen controller's layout and look, in plain CoreGraphics / CoreText so the same code draws it in the app
// (touch_controls.m) and in the Mac preview (ios/tools/touch_preview.c). The look borrows the game's own HUD:
//   face buttons   the weather badge: a black disc in a yellow ring with a thin orange rim, white heavy letters
//   L R ZL ZR - +  the speaker name plate: a slanted yellow-to-orange tab with a hard black shadow
//   d-pad, L3 R3   the date box: dark rounded panels with a light rim, yellow arrows
//   stick          the clock ring: orange and yellow arcs round a dark disc, a yellow knob
// Pressed controls swap to the other colour (yellow parts go black, black parts go yellow), as the game's menus do.
// Coordinates are top-left origin (UIKit's): the preview flips its bitmap context to match.
#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>

enum { B_A, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN, NB };
enum { SHAPE_FACE, SHAPE_PLATE, SHAPE_DPAD, SHAPE_SMALL };

typedef struct { int id; CGRect r; int shape; const char *label; } TouchBtn;
typedef struct {
    TouchBtn btn[NB];
    int n;
    CGFloat s;            // scale (Settings: touch size)
    CGPoint stick_home;   // where the left stick rests until a thumb places it
    CGFloat stick_r;
} TouchLayout;

typedef struct { CGFloat top, left, bottom, right; } TouchInsets;

static inline void touch_layout(TouchLayout *L, CGFloat W, CGFloat H, TouchInsets in, CGFloat scale) {
    CGFloat s = L->s = scale > 0 ? scale : 1;
    CGFloat d = 60 * s, gap = 4 * s;
    CGFloat lx = fmax(in.left, 18), rx = W - fmax(in.right, 18), by = H - fmax(in.bottom, 14), top = fmax(in.top, 10);
    L->n = 0;
#define ADD(i, x, y, w, h, shape, lab) (L->btn[L->n++] = (TouchBtn){i, CGRectMake(x, y, w, h), shape, lab})
    // face buttons: a diamond in the lower right, Switch positions (A right, B bottom, X top, Y left)
    CGFloat cx = rx - d * 1.5 - 6 * s, cy = by - d * 1.5 - 4 * s;
    ADD(B_A, cx + d / 2 + gap, cy - d / 2, d, d, SHAPE_FACE, "A");
    ADD(B_B, cx - d / 2, cy + d / 2 + gap, d, d, SHAPE_FACE, "B");
    ADD(B_X, cx - d / 2, cy - d * 1.5 - gap, d, d, SHAPE_FACE, "X");
    ADD(B_Y, cx - d * 1.5 - gap, cy - d / 2, d, d, SHAPE_FACE, "Y");
    // d-pad: left, above the stick
    CGFloat p = 42 * s, px = lx + 22 * s + p, py = fmax(H * 0.40, top + 2 * 34 * s + 7 * s + 12 * s + p);
    ADD(B_UP, px, py - p, p, p, SHAPE_DPAD, "U");
    ADD(B_DOWN, px, py + p, p, p, SHAPE_DPAD, "D");
    ADD(B_LEFT, px - p, py, p, p, SHAPE_DPAD, "L");
    ADD(B_RIGHT, px + p, py, p, p, SHAPE_DPAD, "R");
    // shoulders: name plates, ZL over L in the top left corner; R ZR on the right below the game's date and weather
    // display (the top right quarter of the picture), ZR over R as on the controller
    CGFloat sw = 84 * s, sh = 34 * s, rtop = fmax(top, H * 0.255);
    ADD(B_ZL, lx, top, sw, sh, SHAPE_PLATE, "ZL");
    ADD(B_L, lx, top + sh + 7 * s, sw, sh, SHAPE_PLATE, "L");
    ADD(B_ZR, rx - sw, rtop, sw, sh, SHAPE_PLATE, "ZR");
    ADD(B_R, rx - sw, rtop + sh + 7 * s, sw, sh, SHAPE_PLATE, "R");
    CGFloat mw = 54 * s, mh = 30 * s;
    ADD(B_MINUS, W / 2 - mw - 10 * s, top, mw, mh, SHAPE_PLATE, "−");
    ADD(B_PLUS, W / 2 + 10 * s, top, mw, mh, SHAPE_PLATE, "+");
    // stick clicks: small date-box panels in the bottom corners
    ADD(B_LS, lx, by - 28 * s, 44 * s, 28 * s, SHAPE_SMALL, "L3");
    ADD(B_RS, cx - d * 1.5 - gap - 52 * s, by - 28 * s, 44 * s, 28 * s, SHAPE_SMALL, "R3");
#undef ADD
    L->stick_r = 64 * s;
    L->stick_home = CGPointMake(lx + L->stick_r + 44 * s, by - L->stick_r - 20 * s);
}

// ------------------------------------------------------------------ colours
static inline void ts_rgb(CGContextRef g, bool fill, int rgb, CGFloat a) {
    CGFloat c[4] = {((rgb >> 16) & 255) / 255.0, ((rgb >> 8) & 255) / 255.0, (rgb & 255) / 255.0, a};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGColorRef col = CGColorCreate(cs, c);
    if (fill) CGContextSetFillColorWithColor(g, col);
    else CGContextSetStrokeColorWithColor(g, col);
    CGColorRelease(col);
    CGColorSpaceRelease(cs);
}
#define TS_YELLOW 0xFFE100
#define TS_ORANGE 0xFF9900
#define TS_INK    0x111111
#define TS_PANEL  0x2B2B2B
#define TS_WHITE  0xFFFFFF

// ------------------------------------------------------------------ text
static inline void ts_text(CGContextRef g, const char *s, CGPoint centre, CGFloat size, int rgb, CGFloat skew) {
    CTFontRef f = CTFontCreateWithName(CFSTR("AvenirNext-Heavy"), size, NULL);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat c[4] = {((rgb >> 16) & 255) / 255.0, ((rgb >> 8) & 255) / 255.0, (rgb & 255) / 255.0, 1};
    CGColorRef col = CGColorCreate(cs, c);
    CFStringRef str = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
    CFStringRef keys[] = {kCTFontAttributeName, kCTForegroundColorAttributeName};
    CFTypeRef vals[] = {f, col};
    CFDictionaryRef attr = CFDictionaryCreate(NULL, (const void **)keys, (const void **)vals, 2, &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef as = CFAttributedStringCreate(NULL, str, attr);
    CTLineRef line = CTLineCreateWithAttributedString(as);
    CGRect b = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);  // (y-up, from the baseline)
    CGContextSaveGState(g);
    // top-left origin: CoreText draws upright in a y-up space, so flip around the text's own baseline
    CGContextTranslateCTM(g, centre.x, centre.y);
    CGContextScaleCTM(g, 1, -1);
    CGAffineTransform m = CGAffineTransformMake(1, 0, skew, 1, 0, 0);  // (the plates' italic lean)
    CGContextSetTextMatrix(g, m);
    CGContextSetTextPosition(g, -b.origin.x - b.size.width / 2 - skew * (b.origin.y + b.size.height / 2),
                             -b.origin.y - b.size.height / 2);
    CTLineDraw(line, g);
    CGContextRestoreGState(g);
    CFRelease(line); CFRelease(as); CFRelease(attr); CFRelease(str); CGColorRelease(col); CGColorSpaceRelease(cs); CFRelease(f);
}

// ------------------------------------------------------------------ shapes
static inline void ts_circle(CGContextRef g, CGPoint c, CGFloat r) { CGContextAddEllipseInRect(g, CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r)); }

static inline void ts_round_rect(CGContextRef g, CGRect r, CGFloat rad) {
    CGPathRef p = CGPathCreateWithRoundedRect(r, rad, rad, NULL);
    CGContextAddPath(g, p);
    CGPathRelease(p);
}

// a parallelogram leaning right (the name plate), its slant `k` wide
static inline void ts_plate_path(CGContextRef g, CGRect r, CGFloat k) {
    CGContextMoveToPoint(g, r.origin.x + k, r.origin.y);
    CGContextAddLineToPoint(g, CGRectGetMaxX(r), r.origin.y);
    CGContextAddLineToPoint(g, CGRectGetMaxX(r) - k, CGRectGetMaxY(r));
    CGContextAddLineToPoint(g, r.origin.x, CGRectGetMaxY(r));
    CGContextClosePath(g);
}

static inline void ts_face(CGContextRef g, const TouchBtn *b, bool on, CGFloat s) {
    CGPoint c = CGPointMake(CGRectGetMidX(b->r), CGRectGetMidY(b->r));
    CGFloat r = b->r.size.width / 2;
    // hard shadow down-right, then the orange rim, the yellow ring, the disc
    ts_rgb(g, true, 0x000000, 0.45); ts_circle(g, CGPointMake(c.x + 3 * s, c.y + 3 * s), r); CGContextFillPath(g);
    ts_rgb(g, true, TS_ORANGE, 1); ts_circle(g, c, r); CGContextFillPath(g);
    ts_rgb(g, true, on ? TS_INK : TS_YELLOW, 1); ts_circle(g, c, r - 3 * s); CGContextFillPath(g);
    ts_rgb(g, true, on ? TS_YELLOW : TS_INK, on ? 1 : 0.86); ts_circle(g, c, r - 9 * s); CGContextFillPath(g);
    ts_text(g, b->label, c, 27 * s, on ? TS_INK : TS_WHITE, 0);
}

static inline void ts_plate(CGContextRef g, const TouchBtn *b, bool on, CGFloat s) {
    CGRect r = b->r;
    CGFloat k = r.size.height * 0.32;
    CGContextSaveGState(g);
    ts_rgb(g, true, 0x000000, 0.55);
    ts_plate_path(g, CGRectOffset(r, 4 * s, 4 * s), k); CGContextFillPath(g);
    ts_plate_path(g, r, k);
    if (on) { ts_rgb(g, true, TS_INK, 1); CGContextFillPath(g); }
    else {  // the plate's yellow fading to orange at its foot
        CGContextClip(g);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGFloat comps[] = {1.0, 0.882, 0.0, 1, 1.0, 0.6, 0.0, 1};
        CGFloat locs[] = {0.35, 1};
        CGGradientRef gr = CGGradientCreateWithColorComponents(cs, comps, locs, 2);
        CGContextDrawLinearGradient(g, gr, r.origin, CGPointMake(r.origin.x, CGRectGetMaxY(r)), 0);
        CGGradientRelease(gr);
        CGColorSpaceRelease(cs);
    }
    CGContextRestoreGState(g);
    ts_plate_path(g, r, k);
    ts_rgb(g, false, on ? TS_YELLOW : TS_INK, 1);
    CGContextSetLineWidth(g, 2 * s);
    CGContextStrokePath(g);
    ts_text(g, b->label, CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)), r.size.height * 0.56, on ? TS_YELLOW : TS_INK, 0.2);
}

static inline void ts_panel(CGContextRef g, CGRect r, bool on, CGFloat s, CGFloat rad) {
    ts_rgb(g, true, 0x000000, 0.4); ts_round_rect(g, CGRectOffset(r, 3 * s, 3 * s), rad); CGContextFillPath(g);
    ts_rgb(g, true, on ? TS_YELLOW : TS_PANEL, on ? 1 : 0.82); ts_round_rect(g, r, rad); CGContextFillPath(g);
    ts_rgb(g, false, on ? TS_INK : 0x9A9A9A, 1); CGContextSetLineWidth(g, 2 * s); ts_round_rect(g, CGRectInset(r, 1 * s, 1 * s), rad);
    CGContextStrokePath(g);
}

static inline void ts_dpad(CGContextRef g, const TouchBtn *b, bool on, CGFloat s) {
    CGRect r = CGRectInset(b->r, 1 * s, 1 * s);
    ts_panel(g, r, on, s, 7 * s);
    // a yellow arrowhead pointing outward
    CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
    CGFloat a = b->id == B_UP ? -M_PI / 2 : b->id == B_DOWN ? M_PI / 2 : b->id == B_LEFT ? M_PI : 0, t = 11 * s;
    CGContextMoveToPoint(g, c.x + cos(a) * t, c.y + sin(a) * t);
    CGContextAddLineToPoint(g, c.x + cos(a + 2.3) * t, c.y + sin(a + 2.3) * t);
    CGContextAddLineToPoint(g, c.x + cos(a - 2.3) * t, c.y + sin(a - 2.3) * t);
    CGContextClosePath(g);
    ts_rgb(g, true, on ? TS_INK : TS_YELLOW, 1);
    CGContextFillPath(g);
}

static inline void ts_small(CGContextRef g, const TouchBtn *b, bool on, CGFloat s) {
    ts_panel(g, b->r, on, s, b->r.size.height / 2);
    ts_text(g, b->label, CGPointMake(CGRectGetMidX(b->r), CGRectGetMidY(b->r)), 14 * s, on ? TS_INK : TS_WHITE, 0);
}

// the stick: the clock ring round a dark disc, eight ticks, the knob at `knob`
static inline void ts_stick(CGContextRef g, CGPoint o, CGFloat R, CGPoint knob, bool active, CGFloat s) {
    ts_rgb(g, true, TS_INK, active ? 0.6 : 0.45); ts_circle(g, o, R); CGContextFillPath(g);
    CGContextSetLineWidth(g, 5 * s);
    ts_rgb(g, false, TS_ORANGE, 1); ts_circle(g, o, R - 2.5 * s); CGContextStrokePath(g);
    CGContextSetLineWidth(g, 4 * s);
    ts_rgb(g, false, TS_YELLOW, 1); ts_circle(g, o, R - 7.5 * s); CGContextStrokePath(g);
    CGContextSetLineWidth(g, 2.5 * s);
    for (int k = 0; k < 8; k++) {
        CGFloat a = k * M_PI / 4, r0 = R - (k % 2 ? 16 : 20) * s, r1 = R - 12 * s;
        CGContextMoveToPoint(g, o.x + cos(a) * r0, o.y + sin(a) * r0);
        CGContextAddLineToPoint(g, o.x + cos(a) * r1, o.y + sin(a) * r1);
    }
    CGContextStrokePath(g);
    CGFloat kr = 27 * s;
    ts_rgb(g, true, 0x000000, 0.45); ts_circle(g, CGPointMake(knob.x + 3 * s, knob.y + 3 * s), kr); CGContextFillPath(g);
    ts_rgb(g, true, TS_ORANGE, 1); ts_circle(g, knob, kr); CGContextFillPath(g);
    ts_rgb(g, true, TS_YELLOW, 1); ts_circle(g, knob, kr - 3 * s); CGContextFillPath(g);
    ts_rgb(g, true, TS_INK, 1); ts_circle(g, knob, kr * 0.34); CGContextFillPath(g);
}

// the camera drag's start: a thin yellow ring
static inline void ts_drag_ring(CGContextRef g, CGPoint o, CGFloat s) {
    CGContextSetLineWidth(g, 3 * s);
    ts_rgb(g, false, TS_YELLOW, 0.9); ts_circle(g, o, 34 * s); CGContextStrokePath(g);
    ts_rgb(g, false, TS_ORANGE, 0.9); ts_circle(g, o, 39 * s); CGContextStrokePath(g);
}

// Everything, at `alpha` (Settings: touch opacity). `held` is the pressed controls' bit mask.
static inline void touch_draw(CGContextRef g, const TouchLayout *L, uint64_t held, CGFloat alpha, bool ls_active, CGPoint ls_origin,
                              CGPoint ls_knob, bool rs_active, CGPoint rs_origin) {
    CGContextSetAlpha(g, alpha);
    CGContextBeginTransparencyLayer(g, NULL);
    for (int i = 0; i < L->n; i++) {
        const TouchBtn *b = &L->btn[i];
        bool on = (held >> b->id) & 1;
        switch (b->shape) {
        case SHAPE_FACE: ts_face(g, b, on, L->s); break;
        case SHAPE_PLATE: ts_plate(g, b, on, L->s); break;
        case SHAPE_DPAD: ts_dpad(g, b, on, L->s); break;
        default: ts_small(g, b, on, L->s); break;
        }
    }
    CGPoint o = ls_active ? ls_origin : L->stick_home;
    ts_stick(g, o, L->stick_r, ls_active ? ls_knob : o, ls_active, L->s);
    if (rs_active) ts_drag_ring(g, rs_origin, L->s);
    CGContextEndTransparencyLayer(g);
}
