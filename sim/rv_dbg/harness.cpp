// Verilator harness of the debug bench (tb_rv_dbg.v): the system clock, the
// JTAG pins and the TCP servers a debugger talks to.
//
// Time: the harness owns it.  System clock clk_114 (8.816 ns period, half
// HALF_PS); a pin write is applied PIN_OFS_PS after a falling clk edge,
// then TCK_HALF whole system clocks run before the next byte is taken
// (TCK <= clk / (2 * TCK_HALF)).  While no debugger talks, the clock keeps
// running: the program runs.
//
// Servers (127.0.0.1 only, one connection at a time):
//   remote_bitbang (default): OpenOCD 0.12 protocol on the TAP pins.
//     '0'..'7'  TCK = bit 2, TMS = bit 1, TDI = bit 0
//     'R'       reply '0'/'1' = TDO now
//     'r'..'u'  TRST/SRST: ignored, counted
//     'B' 'b'   LED: ignored, counted
//     'Q'       close the connection
//     anything else ends the run: "=== FAIL rbb unknown byte ..."
//   XVC 1.0 (+xvc=<port>, instead of remote_bitbang), for Vivado hw_server:
//     "getinfo:"                       -> "xvcServer_v1.0:<XVC_MAX>\n"
//     "settck:" <u32 period ns>        -> the same 4 bytes
//     "shift:" <u32 bits> <tms> <tdi>  -> <tdo>, ceil(bits/8) bytes each,
//                                         bit i = byte i/8, bit i%8 (LSB first)
//     Each bit is the remote_bitbang sequence: TCK 0 with TMS/TDI, sample TDO,
//     TCK 1 (the pin driver is shared).
//
// Arguments (plusargs; the bench's own +HEX= +WS= +ROMWS= pass through):
//   +rbb_port=<p>        default $RBB_PORT, else 44853; 0 = any free port.
//                        A port in use falls back to a free one (printed).
//   +xvc=<p>             XVC server on port p instead (0 = any free port)
//   +tck_half=<n>        system clocks per TCK half period; default
//                        $TCK_HALF, else 4
//   +timeout=<cycles>    end the run after that many system clocks
//                        ("=== TIMEOUT"); 0 or absent = no limit
//   +exit_on_disconnect  end the run when the (first) connection closes
//   +rbblog=<file>       remote_bitbang: the replies ('0'/'1', the TDO bit
//                        stream) to <file>, the bytes received to <file>.in
//                        (a replay fixture: the input stream and its answers)
// Output lines: "=== RBB listening 127.0.0.1:<p>" / "=== XVC listening ...",
// one "=== RBB connection <n> ..." line per connection opened and closed, the
// bench's verdict lines, "=== EXIT disconnect", "=== TIMEOUT after <n>
// cycles", "=== CYCLES <n>".
// Exit status: 0 = PASS or exit on disconnect, 1 = FAIL, 2 = TIMEOUT,
// 3 = harness error (socket, protocol, arguments).
#include "Vtb_rv_dbg.h"
#include "verilated.h"

#include <arpa/inet.h>
#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <string>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

namespace {

constexpr uint64_t HALF_PS    = 4408;  // clk_114 half period (8.8154 ns)
constexpr uint64_t PIN_OFS_PS = 2204;  // pin writes: mid low phase of clk
constexpr int      XVC_MAX    = 2048;  // XVC max vector length, bytes

[[noreturn]] void die(const char *what)
{
    std::printf("=== FAIL harness: %s (%s)\n", what, std::strerror(errno));
    std::fflush(stdout);
    std::exit(3);
}

// ------------------------------------------------------------- simulation
class Sim {
public:
    Sim(VerilatedContext *ctx, Vtb_rv_dbg *top, unsigned tck_half, uint64_t timeout)
        : ctx_(ctx), top_(top), tck_half_(tck_half), timeout_(timeout)
    {
        top_->clk = 0;
        top_->tck = 0;
        top_->tms = 1;
        top_->tdi = 0;
        top_->eval();
    }

    // One system clock: rising edge, then falling edge.
    void cycle()
    {
        half();
        half();
        ++cycles_;
        if (timeout_ && cycles_ >= timeout_ && !timed_out_) timed_out_ = true;
    }

    void cycles(unsigned n)
    {
        for (unsigned i = 0; i < n && !done(); ++i) cycle();
    }

    // Pin write mid low phase, then TCK_HALF system clocks.
    void pins(int tck, int tms, int tdi)
    {
        advance_to(t_ + PIN_OFS_PS);
        top_->tck = tck;
        top_->tms = tms;
        top_->tdi = tdi;
        top_->eval();
        cycles(tck_half_);
    }

    int tdo() const { return top_->tdo & 1; }
    bool done() const { return ctx_->gotFinish() || timed_out_; }
    bool finished() const { return ctx_->gotFinish(); }
    bool timed_out() const { return timed_out_; }
    uint64_t cycle_count() const { return cycles_; }
    uint64_t bench_cycles() const { return top_->cycles; }

private:
    void advance_to(uint64_t t)
    {
        while (!ctx_->gotFinish() && top_->eventsPending() && top_->nextTimeSlot() <= t) {
            ctx_->time(top_->nextTimeSlot());
            top_->eval();
        }
        ctx_->time(t);
    }

    void half()
    {
        t_ += HALF_PS;
        advance_to(t_);
        top_->clk = !top_->clk;
        top_->eval();
    }

    VerilatedContext *ctx_;
    Vtb_rv_dbg *top_;
    unsigned tck_half_;
    uint64_t timeout_;
    uint64_t t_ = 0;        // time of the last clk edge, ps
    uint64_t cycles_ = 0;   // system clocks run by the harness
    bool timed_out_ = false;
};

// ------------------------------------------------------------------ TCP
int listen_on(int port, int *bound)
{
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    if (fd < 0) die("socket");
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons(static_cast<uint16_t>(port));
    if (bind(fd, reinterpret_cast<sockaddr *>(&a), sizeof a) < 0) {
        if (errno != EADDRINUSE || port == 0) die("bind");
        std::printf("=== port %d in use, taking a free one\n", port);
        a.sin_port = 0;
        if (bind(fd, reinterpret_cast<sockaddr *>(&a), sizeof a) < 0) die("bind");
    }
    if (listen(fd, 1) < 0) die("listen");
    socklen_t len = sizeof a;
    if (getsockname(fd, reinterpret_cast<sockaddr *>(&a), &len) < 0) die("getsockname");
    *bound = ntohs(a.sin_port);
    return fd;
}

int try_accept(int lfd, std::string *peer)
{
    sockaddr_in a{};
    socklen_t len = sizeof a;
    int fd = accept4(lfd, reinterpret_cast<sockaddr *>(&a), &len, SOCK_NONBLOCK);
    if (fd < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return -1;
        die("accept");
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    char ip[INET_ADDRSTRLEN] = "?";
    inet_ntop(AF_INET, &a.sin_addr, ip, sizeof ip);
    *peer = std::string(ip) + ":" + std::to_string(ntohs(a.sin_port));
    return fd;
}

void send_all(int fd, const char *p, size_t n)
{
    while (n) {
        ssize_t w = send(fd, p, n, MSG_NOSIGNAL);
        if (w < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) continue;
            return;  // peer gone: the next recv sees it
        }
        p += w;
        n -= static_cast<size_t>(w);
    }
}

// ------------------------------------------------------- protocol state
struct Conn {
    int fd = -1;
    int id = 0;
    std::string peer;
    uint64_t bytes = 0, writes = 0, reads = 0, resets = 0, reset_asserts = 0, blinks = 0;
    uint64_t start_cycle = 0;
    std::string out;       // pending replies
    std::vector<uint8_t> in;  // XVC: unparsed bytes
};

struct Opts {
    int port = 44853;
    bool xvc = false;
    unsigned tck_half = 4;
    uint64_t timeout = 0;
    bool exit_on_disconnect = false;
    std::string rbblog;
};

const char *plus(int argc, char **argv, const char *name)
{
    size_t n = std::strlen(name);
    for (int i = 1; i < argc; ++i)
        if (argv[i][0] == '+' && std::strncmp(argv[i] + 1, name, n) == 0) return argv[i] + 1 + n;
    return nullptr;
}

uint64_t number(const char *s, const char *what)
{
    char *end = nullptr;
    errno = 0;
    unsigned long long v = std::strtoull(s, &end, 0);
    if (errno || !end || *end || end == s) {
        std::printf("=== FAIL harness: bad %s '%s'\n", what, s);
        std::exit(3);
    }
    return v;
}

Opts parse(int argc, char **argv)
{
    Opts o;
    if (const char *e = std::getenv("RBB_PORT")) o.port = static_cast<int>(number(e, "RBB_PORT"));
    if (const char *e = std::getenv("TCK_HALF")) o.tck_half = static_cast<unsigned>(number(e, "TCK_HALF"));
    if (const char *v = plus(argc, argv, "rbb_port=")) o.port = static_cast<int>(number(v, "+rbb_port"));
    if (const char *v = plus(argc, argv, "xvc=")) {
        o.xvc = true;
        o.port = static_cast<int>(number(v, "+xvc"));
    }
    if (const char *v = plus(argc, argv, "tck_half=")) o.tck_half = static_cast<unsigned>(number(v, "+tck_half"));
    if (const char *v = plus(argc, argv, "timeout=")) o.timeout = number(v, "+timeout");
    if (plus(argc, argv, "exit_on_disconnect")) o.exit_on_disconnect = true;
    if (const char *v = plus(argc, argv, "rbblog=")) o.rbblog = v;
    if (o.tck_half < 1 || o.port < 0 || o.port > 65535) {
        std::printf("=== FAIL harness: +tck_half must be >= 1, ports 0..65535\n");
        std::exit(3);
    }
    return o;
}

// remote_bitbang: one byte.  Returns false to close the connection.
bool rbb_byte(Sim &sim, Conn &c, uint8_t b, FILE *log_out)
{
    if (b >= '0' && b <= '7') {
        int v = b - '0';
        sim.pins((v >> 2) & 1, (v >> 1) & 1, v & 1);
        ++c.writes;
    } else if (b == 'R') {
        char r = sim.tdo() ? '1' : '0';
        c.out.push_back(r);
        if (log_out) std::fputc(r, log_out);
        ++c.reads;
    } else if (b >= 'r' && b <= 'u') {
        ++c.resets;
        if (b != 'r') ++c.reset_asserts;
    } else if (b == 'B' || b == 'b') {
        ++c.blinks;
    } else if (b == 'Q') {
        return false;
    } else {
        std::printf("=== FAIL rbb unknown byte 0x%02x at offset %" PRIu64 " of connection %d\n",
                    b, c.bytes - 1, c.id);
        std::fflush(stdout);
        std::exit(3);
    }
    return true;
}

uint32_t le32(const uint8_t *p)
{
    return static_cast<uint32_t>(p[0]) | static_cast<uint32_t>(p[1]) << 8 |
           static_cast<uint32_t>(p[2]) << 16 | static_cast<uint32_t>(p[3]) << 24;
}

bool starts(const std::vector<uint8_t> &v, const char *s)
{
    size_t n = std::strlen(s);
    return v.size() >= n && std::memcmp(v.data(), s, n) == 0;
}

// XVC: parse as many complete commands as the buffer holds.
void xvc_parse(Sim &sim, Conn &c)
{
    for (;;) {
        std::vector<uint8_t> &in = c.in;
        if (in.empty()) return;
        if (starts(in, "getinfo:")) {
            c.out += "xvcServer_v1.0:" + std::to_string(XVC_MAX) + "\n";
            in.erase(in.begin(), in.begin() + 8);
        } else if (starts(in, "settck:")) {
            if (in.size() < 11) return;
            c.out.append(reinterpret_cast<const char *>(in.data() + 7), 4);
            std::printf("=== XVC settck %u ns\n", le32(in.data() + 7));
            in.erase(in.begin(), in.begin() + 11);
        } else if (starts(in, "shift:")) {
            if (in.size() < 10) return;
            uint32_t bits = le32(in.data() + 6);
            size_t nb = (bits + 7) / 8;
            if (nb > static_cast<size_t>(XVC_MAX)) {
                std::printf("=== FAIL xvc shift of %u bits > %d bytes\n", bits, XVC_MAX);
                std::exit(3);
            }
            if (in.size() < 10 + 2 * nb) return;
            const uint8_t *tms = in.data() + 10, *tdi = tms + nb;
            std::string tdo(nb, '\0');
            for (uint32_t i = 0; i < bits; ++i) {
                int m = (tms[i / 8] >> (i % 8)) & 1, d = (tdi[i / 8] >> (i % 8)) & 1;
                sim.pins(0, m, d);
                if (sim.tdo()) tdo[i / 8] = static_cast<char>(tdo[i / 8] | (1 << (i % 8)));
                sim.pins(1, m, d);
            }
            c.writes += 2ull * bits;
            c.reads += bits;
            c.out += tdo;
            in.erase(in.begin(), in.begin() + static_cast<long>(10 + 2 * nb));
        } else {
            // a prefix of a command may still be arriving
            static const char *cmds[] = {"getinfo:", "settck:", "shift:"};
            for (const char *s : cmds) {
                size_t n = std::min(std::strlen(s), in.size());
                if (std::memcmp(in.data(), s, n) == 0) return;
            }
            std::printf("=== FAIL xvc unknown command starting 0x%02x at connection %d\n", in[0], c.id);
            std::fflush(stdout);
            std::exit(3);
        }
    }
}

}  // namespace

int main(int argc, char **argv)
{
    Opts o = parse(argc, argv);
    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(argc, argv);
    auto top = std::make_unique<Vtb_rv_dbg>(ctx.get());
    // the model sets the precision (the finest `timescale): HALF_PS needs ps
    if (ctx->timeprecision() != -12) {
        std::printf("=== FAIL harness: time precision 10^%d s, expected 1 ps\n", ctx->timeprecision());
        return 3;
    }
    Sim sim(ctx.get(), top.get(), o.tck_half, o.timeout);

    FILE *log_out = nullptr, *log_in = nullptr;
    if (!o.rbblog.empty() && !o.xvc) {
        log_out = std::fopen(o.rbblog.c_str(), "wb");
        log_in = std::fopen((o.rbblog + ".in").c_str(), "wb");
        if (!log_out || !log_in) die("+rbblog file");
    }

    int bound = 0;
    int lfd = listen_on(o.port, &bound);
    std::printf("=== %s listening 127.0.0.1:%d (TCK_HALF %u, timeout %" PRIu64 " cycles%s)\n",
                o.xvc ? "XVC" : "RBB", bound, o.tck_half, o.timeout,
                o.exit_on_disconnect ? ", exit on disconnect" : "");
    std::fflush(stdout);

    constexpr unsigned IDLE_CYCLES = 64;  // run between polls of an idle socket
    Conn c;
    int nconn = 0;
    bool disconnected = false;
    std::vector<uint8_t> buf(65536);

    while (!sim.done() && !disconnected) {
        if (c.fd < 0) {
            std::string peer;
            int fd = try_accept(lfd, &peer);
            if (fd < 0) {
                sim.cycles(IDLE_CYCLES);
                continue;
            }
            c = Conn{};
            c.fd = fd;
            c.peer = peer;
            c.id = ++nconn;
            c.start_cycle = sim.cycle_count();
            std::printf("=== %s connection %d open from %s at cycle %" PRIu64 "\n",
                        o.xvc ? "XVC" : "RBB", c.id, c.peer.c_str(), c.start_cycle);
            std::fflush(stdout);
        }
        ssize_t n = recv(c.fd, buf.data(), buf.size(), 0);
        bool close_it = false;
        const char *why = "";
        if (n > 0) {
            c.bytes += static_cast<uint64_t>(n);
            if (o.xvc) {
                c.in.insert(c.in.end(), buf.begin(), buf.begin() + n);
                xvc_parse(sim, c);
            } else {
                if (log_in) std::fwrite(buf.data(), 1, static_cast<size_t>(n), log_in);
                for (ssize_t i = 0; i < n && !sim.done(); ++i) {
                    if (!rbb_byte(sim, c, buf[static_cast<size_t>(i)], log_out)) {
                        close_it = true;
                        why = "Q";
                        break;
                    }
                }
            }
            if (!c.out.empty()) {
                send_all(c.fd, c.out.data(), c.out.size());
                c.out.clear();
            }
        } else if (n == 0) {
            close_it = true;
            why = "peer closed";
        } else if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
            sim.cycles(IDLE_CYCLES);
        } else {
            close_it = true;
            why = std::strerror(errno);
        }
        if (close_it || sim.done()) {
            if (close_it) {
                std::printf("=== %s connection %d closed (%s) at cycle %" PRIu64 ": bytes %" PRIu64
                            ", pin writes %" PRIu64 ", R %" PRIu64 ", reset bytes %" PRIu64
                            " (asserting %" PRIu64 "), blink %" PRIu64 "\n",
                            o.xvc ? "XVC" : "RBB", c.id, why, sim.cycle_count(), c.bytes, c.writes,
                            c.reads, c.resets, c.reset_asserts, c.blinks);
                std::fflush(stdout);
                close(c.fd);
                c.fd = -1;
                if (o.exit_on_disconnect) disconnected = true;
            }
        }
    }

    if (log_out) std::fclose(log_out);
    if (log_in) std::fclose(log_in);
    if (c.fd >= 0) close(c.fd);
    close(lfd);

    int rc = 0;
    if (sim.finished()) {
        // the bench printed its verdict ("=== PASS" or "=== FAIL ...")
        rc = top->failed ? 1 : 0;
    } else if (sim.timed_out()) {
        std::printf("=== TIMEOUT after %" PRIu64 " cycles\n", sim.cycle_count());
        rc = 2;
    } else {
        std::printf("=== EXIT disconnect\n");
    }
    std::printf("=== CYCLES %" PRIu64 "\n", sim.bench_cycles());
    std::fflush(stdout);
    top->final();
    return rc;
}
