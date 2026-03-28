#!/usr/bin/env python3
"""Mac AltTab - icon v2"""

import os, math
from PIL import Image, ImageDraw, ImageFilter, ImageFont

def rr(draw, xy, r, fill):
    x0, y0, x1, y1 = [float(v) for v in xy]
    r = min(r, (x1-x0)/2, (y1-y0)/2)
    if r < 1:
        draw.rectangle([x0,y0,x1,y1], fill=fill); return
    draw.rectangle([x0+r, y0, x1-r, y1], fill=fill)
    draw.rectangle([x0, y0+r, x1, y1-r], fill=fill)
    for cx, cy in [(x0+r, y0+r),(x1-r, y0+r),(x0+r, y1-r),(x1-r, y1-r)]:
        draw.ellipse([cx-r, cy-r, cx+r, cy+r], fill=fill)

def gradient_rect(img, xy, r, color_top, color_bot):
    x0, y0, x1, y1 = [int(v) for v in xy]
    h = max(1, y1 - y0)
    layer = Image.new('RGBA', img.size, (0,0,0,0))
    for y in range(y0, y1):
        t = (y - y0) / h
        c = tuple(int(color_top[i] + (color_bot[i]-color_top[i])*t) for i in range(4))
        ImageDraw.Draw(layer).line([(x0, y),(x1, y)], fill=c)
    mask = Image.new('L', img.size, 0)
    rr(ImageDraw.Draw(mask), xy, r, 255)
    layer.putalpha(mask)
    return Image.alpha_composite(img, layer)

def make_icon(S):
    img = Image.new('RGBA', (S, S), (0,0,0,0))

    # ── background: deep navy-black rounded square ──────────────────────────
    P = S * 0.055
    BR = S * 0.225
    img = gradient_rect(img, [P, P, S-P, S-P], BR,
                        (18, 20, 30, 255), (28, 30, 45, 255))

    # subtle inner glow at top
    glow = Image.new('RGBA', (S, S), (0,0,0,0))
    gd = ImageDraw.Draw(glow)
    for i in range(int(S*0.25), 0, -1):
        a = int(14 * (1 - i/(S*0.25)))
        rr(gd, [P+i*0.15, P+i*0.15, S-P-i*0.15, P+i*0.7], BR, (120,130,200,a))
    img = Image.alpha_composite(img, glow)

    draw = ImageDraw.Draw(img)

    # ── shared card metrics ──────────────────────────────────────────────────
    inner   = S - P*2
    CW      = inner * 0.60
    CH      = inner * 0.44
    TH      = CH * 0.21       # title bar height
    CR      = S * 0.035       # card corner radius
    DOT_R   = max(2, S*0.018)
    LINE_H  = max(1, int(S*0.016))

    def draw_card(ox, oy, bg, title_bg, dot_alpha=200, content_alpha=150, lines=3):
        # shadow
        for si in range(1, 5):
            sa = max(0, 40 - si*9)
            rr(draw, [ox+si, oy+si, ox+CW+si, oy+CH+si], CR, (0,0,0,sa))
        # body
        rr(draw, [ox, oy, ox+CW, oy+CH], CR, bg)
        # title bar
        rr(draw, [ox, oy, ox+CW, oy+TH], CR, title_bg)
        # fix bottom of title bar corners (square)
        draw.rectangle([ox, oy+TH-CR, ox+CW, oy+TH], fill=title_bg)
        # traffic lights
        colors = [(220,75,65,dot_alpha),(220,160,45,dot_alpha),(70,185,75,dot_alpha)]
        for di, dc in enumerate(colors):
            dx = ox + CR*1.6 + di*(DOT_R*2 + max(2,S*0.014))
            dy = oy + TH/2
            draw.ellipse([dx-DOT_R, dy-DOT_R, dx+DOT_R, dy+DOT_R], fill=dc)
        # content lines
        lx0 = ox + CR*2
        for li in range(lines):
            widths = [0.72, 0.48, 0.58]
            lw = widths[li % len(widths)]
            lx1 = lx0 + (CW - CR*4) * lw
            ly  = oy + TH + (li+1)*(CH-TH)/(lines+1)
            rr(draw, [lx0, ly-LINE_H//2, lx1, ly+LINE_H//2],
               LINE_H//2, (140,145,175,content_alpha))

    # ── back window (muted, offset top-right) ───────────────────────────────
    bx = P + inner*0.24
    by = P + inner*0.06
    draw_card(bx, by,
              bg=(52, 55, 72, 220),
              title_bg=(62, 65, 85, 220),
              dot_alpha=130, content_alpha=80, lines=2)

    # ── front window (vivid, active) ─────────────────────────────────────────
    fx = P + inner*0.05
    fy = P + inner*0.33
    draw_card(fx, fy,
              bg=(38, 42, 62, 255),
              title_bg=(50, 54, 80, 255),
              dot_alpha=230, content_alpha=160, lines=3)

    # accent left border on front window
    accent_w = max(2, int(S*0.022))
    for ai in range(accent_w):
        alpha = int(255 * (1 - ai/accent_w) * 0.9)
        draw.line([(fx+ai, fy+CR), (fx+ai, fy+CH-CR)],
                  fill=(120, 100, 255, alpha), width=1)

    # ── Tab key badge ────────────────────────────────────────────────────────
    BD  = S * 0.265
    BX  = S - P - BD + S*0.008
    BY  = S - P - BD + S*0.008
    BGR = BD * 0.28

    # badge shadow
    for si in range(1, 5):
        sa = max(0, 50 - si*11)
        rr(draw, [BX+si, BY+si, BX+BD+si, BY+BD+si], BGR, (0,0,0,sa))

    # badge gradient bg
    img = gradient_rect(img, [BX, BY, BX+BD, BY+BD], BGR,
                        (105, 95, 255, 248), (75, 65, 220, 248))
    draw = ImageDraw.Draw(img)

    # subtle shine on badge top
    shine = Image.new('RGBA', (S,S),(0,0,0,0))
    sd = ImageDraw.Draw(shine)
    rr(sd, [BX+BD*0.1, BY+BD*0.05, BX+BD*0.9, BY+BD*0.45], BGR*0.6, (255,255,255,18))
    img = Image.alpha_composite(img, shine)
    draw = ImageDraw.Draw(img)

    # Switch icon — clean hook arrows, 8x supersampling
    SCALE = 8
    BS    = int(BD * SCALE)
    bl    = Image.new('RGBA', (BS, BS), (0, 0, 0, 0))
    bd2   = ImageDraw.Draw(bl)
    W     = (255, 255, 255, 255)
    N     = 200

    def annular_arc(cx, cy, r, stroke, a_start, a_end):
        """Filled thick arc as annular polygon, a in degrees (PIL: 0=right, CW)."""
        ro, ri = r + stroke/2, r - stroke/2
        angs = [math.radians(a_start + (a_end - a_start)*i/N) for i in range(N+1)]
        outer = [(cx + ro*math.cos(a), cy + ro*math.sin(a)) for a in angs]
        inner = [(cx + ri*math.cos(a), cy + ri*math.sin(a)) for a in reversed(angs)]
        bd2.polygon(outer + inner, fill=W)
        # round tail cap
        ta = math.radians(a_start)
        tc = (cx + r*math.cos(ta), cy + r*math.sin(ta))
        bd2.ellipse([tc[0]-stroke/2, tc[1]-stroke/2, tc[0]+stroke/2, tc[1]+stroke/2], fill=W)

    def arrow_tip(cx, cy, r, a_end_deg, stroke, head_len, head_half_w):
        """Clean triangle arrowhead at arc end, tangent-aligned."""
        # tangent direction at a_end (clockwise motion = d/dθ of (cosθ,sinθ))
        a  = math.radians(a_end_deg)
        tx, ty = -math.sin(a), math.cos(a)   # unit tangent (clockwise)
        px, py = -ty, tx                      # unit perpendicular (left of motion)
        tip = (cx + r*math.cos(a), cy + r*math.sin(a))
        base_c = (tip[0] - tx*head_len, tip[1] - ty*head_len)
        bd2.polygon([
            tip,
            (base_c[0] + px*head_half_w, base_c[1] + py*head_half_w),
            (base_c[0] - px*head_half_w, base_c[1] - py*head_half_w),
        ], fill=W)

    R   = BS * 0.285
    STK = BS * 0.13
    HL  = BS * 0.19   # arrowhead length
    HW  = BS * 0.16   # arrowhead half-width
    off = BS * 0.085  # vertical separation

    # Arc body ends a few degrees before tip so head doesn't overlap
    trim = math.degrees(HL / R) * 0.55

    # TOP arrow: 200° → 345°, tip near 345° (upper arc, right side)
    a0t, a1t = 200, 345
    annular_arc(BS/2, BS/2 - off, R, STK, a0t, a1t - trim)
    arrow_tip  (BS/2, BS/2 - off, R, a1t, STK, HL, HW)

    # BOTTOM arrow: 20° → 165°, tip near 165° (lower arc, left side)
    a0b, a1b = 20, 165
    annular_arc(BS/2, BS/2 + off, R, STK, a0b, a1b - trim)
    arrow_tip  (BS/2, BS/2 + off, R, a1b, STK, HL, HW)

    # downscale with AA
    bsize = int(BD)
    small = bl.resize((bsize, bsize), Image.LANCZOS)
    img.paste(small, (int(BX), int(BY)), small)

    return img

# ── export iconset ───────────────────────────────────────────────────────────
iconset = "/Users/louis/Desktop/work2/Mac AlTab/AppIcon.iconset"
os.makedirs(iconset, exist_ok=True)

for sz in [16,32,64,128,256,512,1024]:
    make_icon(sz).save(f"{iconset}/icon_{sz}x{sz}.png")
    if sz <= 512:
        make_icon(sz*2).save(f"{iconset}/icon_{sz}x{sz}@2x.png")

print("done")
