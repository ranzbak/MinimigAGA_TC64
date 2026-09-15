import os, tempfile, unittest
import rtg_decode

HEADER = ("Sample in Buffer,Sample in Window,TRIGGER,"
          "openaars_virtual_top/dbg_rtg[31:0],"
          "openaars_virtual_top/g_cpu040_ila.probe10[28:0]\n")
RADIX = "Radix - UNSIGNED,UNSIGNED,UNSIGNED,HEX,HEX\n"

def rtg_word(req, wr, bstate, addr12, data):
    return (req << 31) | (wr << 30) | (bstate << 28) | (addr12 << 16) | data

def rtg_state(ena, baseaddr_25_4):
    return (ena << 28) | (baseaddr_25_4 & 0x3FFFFF)

class DecodeTest(unittest.TestCase):
    def write_csv(self, rows):
        fd, path = tempfile.mkstemp(suffix=".csv")
        with os.fdopen(fd, "w") as f:
            f.write(HEADER); f.write(RADIX)
            for i, (w, s) in enumerate(rows):
                f.write(f"{i},{i},0,{w:08x},{s:08x}\n")
        self.addCleanup(os.remove, path)
        return path

    def test_framebuffer_address_from_two_halves(self):
        # SetPanning: move.l #$00800000,$b80100 -> hi word $0080 at $100, lo $0000 at $102
        path = self.write_csv([
            (rtg_word(1, 1, 3, 0x100, 0x0080), rtg_state(0, 0)),
            (rtg_word(1, 1, 3, 0x102, 0x0000), rtg_state(0, 0x08000)),
        ])
        rows = rtg_decode.decode_rows(path)
        self.assertEqual([r["name"] for r in rows], ["fb_addr_hi", "fb_addr_lo"])
        self.assertEqual(rows[0]["kind"], "W")
        self.assertEqual(rtg_decode.framebuffer(rows), 0x00800000)
        self.assertEqual(rows[1]["rtg_addr"], 0x08000 << 4)

    def test_read_is_not_a_write(self):
        path = self.write_csv([(rtg_word(1, 0, 2, 0x10E, 0x8320), rtg_state(1, 0))])
        rows = rtg_decode.decode_rows(path)
        self.assertEqual(rows[0]["kind"], "R")
        self.assertEqual(rows[0]["name"], "id")
        self.assertEqual(rows[0]["rtg_ena"], 1)

    def test_clut_range(self):
        path = self.write_csv([(rtg_word(1, 1, 3, 0x404, 0x00FF), rtg_state(0, 0))])
        self.assertEqual(rtg_decode.decode_rows(path)[0]["name"], "clut[1]")

if __name__ == "__main__":
    unittest.main()
