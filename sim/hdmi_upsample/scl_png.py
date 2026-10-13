#!/usr/bin/env python3
"""PNGs of the scaler bench for the eye (scaler_run.sh lin* legs).

  scl_png.py OUTDIR B LEG:KERNEL:HZ [LEG:KERNEL:HZ ...]
      B: the bench's log dir (build/scaler).  Per leg: B/LEG_8.hex is the
      RTL picture (HD frame 8), B/LEG_model.png the model at the RTL's
      geometry (scl_model.py compare).  Writes to OUTDIR:
        rtl_LEG.png          the RTL picture, 1280 x 720, as adv_ddr gets it
        model_LEG.png        the model on the RTL's own line-buffer rows
        study_*.png          the study's model renders of the same source
                             (scaler/scale.py with render_all.py's settings:
                             2.5x / 3x vertically, 1.6x area horizontally,
                             linear light) -- study_pal_2p5_crt_lin2_L.png is
                             the picture Paul approved for CRT scanlines on
        sheet_LEG.png        crops, 4x nearest: study | RTL | model at the
                             RTL's geometry, per region of the test frame
The RTL's horizontal mapping is today's (time-proportional capture, not the
study's 1.6x area), so study and RTL crops differ sideways; vertically they
are the same geometry (row 0's centre at source line 24.2 / 22.1667).
"""
import os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'scaler'))
import scale, frames

OW, OH = 1280, 720
WIN = {50: (288, 24, 2.5), 60: (240, 22, 3.0)}
STUDY = {'sharp': 'sharp05_L', 'area': 'area_L', 'dim': 'crt_lin2_L', 'black': 'crt_lin2_black_L'}
CW, CH, Z = 160, 90, 4


def font(sz):
    for f in ('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',):
        try:
            return ImageFont.truetype(f, sz)
        except Exception:
            pass
    return ImageFont.load_default()


def load(fn):
    a = np.array([int(l, 16) for l in open(fn)], dtype=np.uint32).reshape(720, 1280)
    return np.stack([(a >> 16) & 255, (a >> 8) & 255, a & 255], -1).astype(np.uint8)


def study(img, hz, kern):
    n, _, r = WIN[hz]
    rh, offh = 1.6, (OW - 720 * 1.6) / 2
    offv = (OH - n * r) / 2
    if kern in ('dim', 'black'):
        Mh = scale.box_matrix(720, OW, rh, offh, 1 / rh)
        hz_img = scale.apply_sep(img, np.eye(n), Mh, 'linear')
        return scale.crt_vertical(hz_img, OH, r, offv, 'crt_lin2', 0.60 if kern == 'dim' else 0.80)
    w = (0.5 if kern == 'sharp' else 1.0)
    return scale.render(img, OW, OH, r, offv, rh, offh,
                        dict(kind='x', w_src_v=w / r, w_src_h=w / rh, space='linear'))


def rtl_map(rtl, hz):
    """source (hires px, frame row) -> RTL (x, y): rows by the exact ratio
    (row 0's centre at window row -0.3 PAL / -1/3 NTSC... i.e. the study's
    offv 0), columns from where the picture starts and ends in the RTL"""
    n, _, r = WIN[hz]
    lit = np.nonzero(rtl[OH // 2:OH // 2 + 40].any(-1).any(0))[0]
    x0, x1 = lit[0], lit[-1] + 1
    return lambda px, py: (x0 + px * (x1 - x0) / 720.0, py * r)


def crop(a, x, y):
    x = int(max(0, min(OW - CW, round(x)))); y = int(max(0, min(OH - CH, round(y))))
    return a[y:y + CH, x:x + CW]


def sheet(path, title, img_s, rtl, model, regions, hz):
    m = rtl_map(rtl, hz)
    n, _, r = WIN[hz]
    rows = []
    for name, reg in regions.items():
        ax, ay = reg[4], reg[5]
        sx, sy = ax * 1.6 + (OW - 720 * 1.6) / 2, ay * r
        rx, ry = m(ax, ay)
        rows.append((name, crop(img_s, sx, sy), crop(rtl, rx, ry), crop(model, rx, ry)))
    tw, th, gap, lab, head = CW * Z, CH * Z, 14, 26, 50
    W = 3 * tw + 4 * gap
    H = head + len(rows) * (th + lab + gap)
    sh = Image.new('RGB', (W, H), (128, 128, 128))
    d = ImageDraw.Draw(sh)
    d.text((gap, 8), title, fill=(0, 0, 0), font=font(20))
    d.text((gap, 30), 'study model (scale.py, 1.6x area horizontally)  |  RTL bench (tb_crt_frame)  |  model on the RTL\'s line-buffer rows (the +-1 gate)', fill=(20, 20, 20), font=font(14))
    for i, (name, a, b, c) in enumerate(rows):
        y = head + i * (th + lab + gap)
        d.text((gap, y), name, fill=(0, 0, 0), font=font(16))
        for k, t in enumerate((a, b, c)):
            sh.paste(Image.fromarray(t).resize((tw, th), Image.NEAREST), (gap + k * (tw + gap), y + lab))
    sh.save(path, optimize=True)


if __name__ == '__main__':
    out, B = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    src = {}
    for arg in sys.argv[3:]:
        leg, kern, hz = arg.split(':'); hz = int(hz)
        n, _, r = WIN[hz]
        if hz not in src:
            # as the study rendered it (the bench's source blanks the first
            # two PAL rows: Agnus' vertical blank)
            src[hz] = frames.native_frame(n)
        img, regions = src[hz]
        rtl = load(os.path.join(B, leg + '_8.hex'))
        model = np.array(Image.open(os.path.join(B, leg + '_model.png')).convert('RGB'))
        s = study(img, hz, kern)
        tag = ('pal_2p5' if hz == 50 else 'ntsc_3') + '_' + STUDY[kern]
        Image.fromarray(s).save(os.path.join(out, 'study_%s.png' % tag), optimize=True)
        Image.fromarray(rtl).save(os.path.join(out, 'rtl_%s.png' % leg), optimize=True)
        Image.fromarray(model).save(os.path.join(out, 'model_%s.png' % leg), optimize=True)
        sheet(os.path.join(out, 'sheet_%s.png' % leg),
              '%s: %s, %s (%.1fx), HD frame 8' % (leg, kern, 'PAL 288 -> 720' if hz == 50 else 'NTSC 240 -> 720', r),
              s, rtl, model, regions, hz)
        print(leg, 'done')
