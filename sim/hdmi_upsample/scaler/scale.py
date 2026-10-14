"""Separable resampling model for the scaler study (copied 2026-10-13 from the
study's scratch tools into the bench, sim/hdmi_upsample/scaler; crt_vertical
split into crt_row + crt_post so the bench can evaluate single rows -- the
same arithmetic, pal_2p5_crt_lin2_L.png comes out bit-identical).

Geometry (both axes): source pixel k covers [k, k+1); output pixel j covers
an interval of width h = 1/r whose centre is c_j = (j + 0.5 - off) / r.
Output pixels whose centre falls outside [0, n_in) are black (the bars).

Every non-CRT kernel is a box of width w (source units) laid over the
unit source cells, weights = overlap / w (survey section 3.1):
    w = 0        nearest
    w = h        area / Winscale (exact overlap; any number of taps, so
                 downscaling is the exact 3-tap box)
    w = 0.5 h    sharp-bilinear, ramp half an output pixel
    w = 1/s      libretro sharp-bilinear, s = floor(r)
    w = 1        bilinear (the tent)
'space' = 'gamma' blends 8-bit codes, 'linear' blends light (code/255)^2.4.

CRT (vertical only; horizontal = area in linear light, applied first like
crt_beamh sits before the line buffers):
    crt_today1  today's V-filter-off scanlines: line k = floor(c), cosine
                profile wl = 1 - D (1 - cos 2 pi d) / 2 on that line only
    crt_today2  today's two-line beam (V filter on): Gaussian weights of
                the fractional distance, stored as w_lin^(1/2.4) and
                applied to CODES (crt_mkroms.py), so exact only if cur==next
    crt_lin2    the same Gaussians applied to LIGHT (crt-lottes style)
Then crt_mkroms.py's page gain 1/(1 - D/2) in light and its soft clip.
D = 0.60 (OSD scanlines 'dim').  No mask, no bloom, no phase quantisation.
"""
import math
import numpy as np

G = 2.4
D_SCAN = 0.60

def dec(a):
    return (np.asarray(a, np.float64) / 255.0) ** G

def enc(L):
    return np.clip(np.round(255.0 * np.clip(L, 0, None) ** (1 / G)), 0, 255).astype(np.uint8)


def centres(n_out, r, off):
    return (np.arange(n_out) + 0.5 - off) / r


def box_matrix(n_in, n_out, r, off, w, taps2=False):
    M = np.zeros((n_out, n_in))
    for j, c in enumerate(centres(n_out, r, off)):
        if c < 0 or c >= n_in:
            continue
        if w <= 0:
            M[j, int(math.floor(c))] = 1.0
            continue
        lo, hi = c - w / 2, c + w / 2
        for k in range(int(math.floor(lo)), int(math.floor(hi)) + 1):
            ov = min(hi, k + 1) - max(lo, k)
            if ov > 1e-12:
                M[j, min(max(k, 0), n_in - 1)] += ov / w
        if taps2:
            row = M[j]
            nz = np.nonzero(row)[0]
            if len(nz) > 2:
                keep = nz[np.argsort(row[nz])[-2:]]
                drop = np.setdiff1d(nz, keep)
                row[drop] = 0
                row /= row.sum()
    return M


def apply_sep(img, Mv, Mh, space):
    x = dec(img) if space == 'linear' else img.astype(np.float64) / 255.0
    y = np.einsum('ij,jkc->ikc', Mv, x, optimize=True)
    y = np.einsum('kl,ilc->ikc', Mh, y, optimize=True)
    if space == 'linear':
        return enc(y)
    return np.clip(np.round(255 * y), 0, 255).astype(np.uint8)


def _sigma(D):
    return 0.5 / math.sqrt(2 * math.log(2 / (1 - D)))

def _softclip(x, k=0.80):
    return np.where(x <= k, x, k + (1 - k) * (1 - np.exp(-(x - k) / (1 - k))))


def crt_row(L, C, c, kind, D=D_SCAN):
    """one output row of crt_vertical at source centre c, in linear light
    before the page gain (L: decoded rows, C: code rows); None outside"""
    n_in = L.shape[0]
    if c < 0 or c >= n_in:
        return None
    sg = _sigma(D)
    g = lambda x: np.exp(-x * x / (2 * sg * sg))
    norm = 1 + math.exp(-1 / (2 * sg * sg))           # max of g(d)+g(1-d), at d = 0
    if kind == 'crt_today1':
        k = int(math.floor(c))
        d = c - (k + 0.5)
        wl = 1 - D * (1 - math.cos(2 * math.pi * d)) / 2
        return wl * L[k]
    k = int(math.floor(c - 0.5))
    d0 = c - (k + 0.5)
    k0, k1 = min(max(k, 0), n_in - 1), min(max(k + 1, 0), n_in - 1)
    g0, g1 = g(d0) / norm, g(1 - d0) / norm
    if kind == 'crt_lin2':
        return g0 * L[k0] + g1 * L[k1]
    if kind == 'crt_today2':
        s = (g0 + g1) ** (1 / G)
        w0 = round(256 * s * g0 / (g0 + g1)) / 256
        w1 = round(256 * s * g1 / (g0 + g1)) / 256
        v = np.round(w0 * C[k0] + w1 * C[k1])
        return dec(np.clip(v, 0, 255))
    raise ValueError(kind)


def crt_post(out, D=D_SCAN):
    """crt_mkroms.py's page gain 1/(1 - D/2) in light and its soft clip"""
    out = out * (1 / (1 - D / 2))
    return enc(_softclip(out))


def crt_vertical(img_codes, n_out, r, off, kind, D=D_SCAN):
    """img_codes: H x W x 3 uint8 (already horizontally scaled)."""
    L = dec(img_codes)
    C = img_codes.astype(np.float64)
    out = np.zeros((n_out,) + img_codes.shape[1:])
    for j, c in enumerate(centres(n_out, r, off)):
        row = crt_row(L, C, c, kind, D)
        if row is not None:
            out[j] = row
    return crt_post(out, D)


def render(img, out_w, out_h, rv, offv, rh, offh, method):
    """method: dict(kind=..., w=..., space=..., wh=..., taps2=...)
    returns out_h x out_w x 3 uint8"""
    nh, nw = img.shape[:2]
    kind = method['kind']
    if kind.startswith('crt'):
        Mh = box_matrix(nw, out_w, rh, offh, 1 / rh)
        hz = apply_sep(img, np.eye(nh), Mh, 'linear')
        return crt_vertical(hz, out_h, rv, offv, kind)
    wv = method['w_src_v']
    wh = method.get('w_src_h', wv)
    Mv = box_matrix(nh, out_h, rv, offv, wv, method.get('taps2', False))
    Mh = box_matrix(nw, out_w, rh, offh, wh, method.get('taps2', False))
    return apply_sep(img, Mv, Mh, method.get('space', 'gamma'))
