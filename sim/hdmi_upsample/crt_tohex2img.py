#!/usr/bin/env python3
"""tohex2img.py X.hex [...] -> X.ppm (1280x720 P6) and X.png; returns arrays."""
import sys, numpy as np
def load(fn):
    a = np.array([int(l, 16) for l in open(fn)], dtype=np.uint32)
    a = a.reshape(720, 1280)
    return np.stack([(a >> 16) & 255, (a >> 8) & 255, a & 255], -1).astype(np.uint8)
def save(img, base):
    with open(base + '.ppm', 'wb') as f:
        f.write(b'P6\n1280 720\n255\n'); f.write(img.tobytes())
    from PIL import Image
    Image.fromarray(img).save(base + '.png')
if __name__ == '__main__':
    for fn in sys.argv[1:]:
        save(load(fn), fn[:-4])
        print(fn[:-4] + '.ppm')
