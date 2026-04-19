const std = @import("std");

pub const RESET = "\x1b[0m";
pub const BOLD = "\x1b[1m";
pub const DIM = "\x1b[2m";
pub const ITALIC = "\x1b[3m";
pub const CLEAR_LINE = "\r\x1b[2K";

pub const RED = "\x1b[31m";
pub const GREEN = "\x1b[32m";
pub const YELLOW = "\x1b[33m";
pub const BLUE = "\x1b[34m";
pub const MAGENTA = "\x1b[35m";
pub const CYAN = "\x1b[36m";
pub const BRIGHT_BLACK = "\x1b[90m";
pub const BRIGHT_BLUE = "\x1b[94m";
pub const BRIGHT_MAGENTA = "\x1b[95m";
pub const BRIGHT_CYAN = "\x1b[96m";


const C_RAIL = "\x1b[38;5;240m"; // subtle spine / rules
const C_MUTED = "\x1b[38;5;244m"; // secondary text
const C_SOFT = "\x1b[38;5;252m"; // primary text emphasis
const C_TRACK = "\x1b[38;5;237m"; // empty progress-bar track

const C_UPLOAD = "\x1b[38;5;117m"; // soft sky cyan — brand / upload accent
const C_DOWNLOAD = "\x1b[38;5;183m"; // soft lavender
const C_INFO = "\x1b[38;5;111m"; // periwinkle — network work
const C_SUCCESS = "\x1b[38;5;114m"; // mint — completion
const C_WARN = "\x1b[38;5;179m"; // amber — crypto / sealing
const C_ERROR = "\x1b[38;5;174m"; // soft coral

pub const Palette = struct {
    pub const upload = C_UPLOAD;
    pub const download = C_DOWNLOAD;
    pub const info = C_INFO;
    pub const success = C_SUCCESS;
    pub const warn = C_WARN;
    pub const error_ = C_ERROR;
};


const G_RAIL = "┃"; // thicker spine (not │)
const G_DOT = "·";


var session_start_ms: i64 = 0;
var step_num: u8 = 0;

const STEP_TS_COL: usize = 72;

// progress.zig keeps a small amount of global session state so individual
// print helpers can stay lightweight and do not need a shared context object
// threaded through every CLI path.

pub const Progress = struct {
    totalBytes: u64,
    transferredBytes: u64,
    startTime: i64,
    label: []const u8,
    accent: []const u8,
    glyph: []const u8,
    last_render_ms: i64,

    speed_samples: [12]u64,
    speed_head: usize,
    speed_len: usize,

    pub fn init(totalBytes: u64, label: []const u8) Progress {
        return initStyled(totalBytes, label, Palette.upload, "flow");
    }

    pub fn initStyled(totalBytes: u64, label: []const u8, accent: []const u8, glyph: []const u8) Progress {
        const now = std.time.milliTimestamp();
        return .{
            .totalBytes = totalBytes,
            .transferredBytes = 0,
            .startTime = now,
            .label = label,
            .accent = accent,
            .glyph = glyph,
            .last_render_ms = 0,
            .speed_samples = [_]u64{0} ** 12,
            .speed_head = 0,
            .speed_len = 0,
        };
    }

    pub fn update(self: *Progress, newBytes: u64) void {
        self.transferredBytes += newBytes;
        const now = std.time.milliTimestamp();

        if (self.transferredBytes >= self.totalBytes or now - self.last_render_ms >= 60) {
            // Rendering is throttled so high-throughput transfers do not spam the
            // terminal with a redraw for every tiny chunk.
            self.last_render_ms = now;
            self.pushSpeedSample(self.bytesPerSecond());
            self.render();
        }
    }

    pub fn render(self: *Progress) void {
        const cols = termColumns();
        const width = progressBarWidth();

        const percent: u64 = if (self.totalBytes > 0)
            @min(100, (self.transferredBytes * 100) / self.totalBytes)
        else
            0;

        const speed = self.bytesPerSecond();
        const eta_seconds: f64 = if (speed > 0 and self.totalBytes > self.transferredBytes)
            @as(f64, @floatFromInt(self.totalBytes - self.transferredBytes)) / @as(f64, @floatFromInt(speed))
        else
            0.0;

        var transferred_buf: [32]u8 = undefined;
        const transferred_str = formatSize(&transferred_buf, self.transferredBytes);

        var speed_buf: [32]u8 = undefined;
        const speed_str = formatSize(&speed_buf, speed);

        var eta_buf: [24]u8 = undefined;
        const eta_str = formatSeconds(&eta_buf, eta_seconds);

        var spark_buf: [64]u8 = undefined;
        const spark_str = self.sparkline(&spark_buf);

        std.debug.print("{s}  {s}{s}{s}         ", .{ CLEAR_LINE, C_RAIL, G_RAIL, RESET });
        printBar(width, self.transferredBytes, self.totalBytes, self.accent);

        // Wide terminals get the full render.
        if (cols >= 110) {
            std.debug.print(
                "   {s}{d: >3}%{s}   {s}{s:>9}{s}   {s}{s}{s} {s}{s}/s{s}   {s}eta {s}{s}",
                .{
                    self.accent, percent,         RESET,
                    C_SOFT,      transferred_str, RESET,
                    self.accent, spark_str,       RESET,
                    C_MUTED,     speed_str,       RESET,
                    C_MUTED,     eta_str,         RESET,
                },
            );
            return;
        }

        // Medium terminals drop the sparkline first.
        if (cols >= 90) {
            std.debug.print(
                "   {s}{d: >3}%{s}   {s}{s:>9}{s}   {s}{s}/s{s}   {s}eta {s}{s}",
                .{
                    self.accent, percent,         RESET,
                    C_SOFT,      transferred_str, RESET,
                    C_MUTED,     speed_str,       RESET,
                    C_MUTED,     eta_str,         RESET,
                },
            );
            return;
        }

        // Narrow terminals get a compact line that should stay on one row.
        std.debug.print(
            "   {s}{d: >3}%{s} {s}{s:>9}{s} {s}{s}/s{s}",
            .{
                self.accent, percent,         RESET,
                C_SOFT,      transferred_str, RESET,
                C_MUTED,     speed_str,       RESET,
            },
        );
    }

    pub fn finish(self: *Progress) void {
        self.transferredBytes = self.totalBytes;
        self.render();
        std.debug.print("\n", .{});
    }

    fn elapsedSeconds(self: *Progress) f64 {
        const now = std.time.milliTimestamp();
        const elapsed_ms = now - self.startTime;
        return @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
    }

    fn bytesPerSecond(self: *Progress) u64 {
        const elapsed = self.elapsedSeconds();
        if (elapsed < 0.001) return 0;
        return @intFromFloat(@as(f64, @floatFromInt(self.transferredBytes)) / elapsed);
    }

    fn pushSpeedSample(self: *Progress, sample: u64) void {
        self.speed_samples[self.speed_head] = sample;
        self.speed_head = (self.speed_head + 1) % self.speed_samples.len;
        if (self.speed_len < self.speed_samples.len) self.speed_len += 1;
    }

    fn sparkline(self: *Progress, buf: []u8) []const u8 {
        const bars = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
        if (self.speed_len == 0) return buf[0..0];

        // Find min / max across the populated samples.
        var lo: u64 = std.math.maxInt(u64);
        var hi: u64 = 0;
        var i: usize = 0;
        while (i < self.speed_len) : (i += 1) {
            const idx = (self.speed_head + self.speed_samples.len - self.speed_len + i) % self.speed_samples.len;
            const v = self.speed_samples[idx];
            if (v < lo) lo = v;
            if (v > hi) hi = v;
        }
        const span: u64 = if (hi > lo) hi - lo else 1;

        
        // Emit oldest-first so the tiny graph reads like a left-to-right
        // history instead of a shuffled ring-buffer view.
        var out: usize = 0;
        i = 0;
        while (i < self.speed_len) : (i += 1) {
            const idx = (self.speed_head + self.speed_samples.len - self.speed_len + i) % self.speed_samples.len;
            const v = self.speed_samples[idx];
            const level_u = ((v - lo) * 7) / span;
            const level: usize = @min(@as(usize, @intCast(level_u)), 7);
            const glyph = bars[level];
            if (out + glyph.len > buf.len) break;
            @memcpy(buf[out .. out + glyph.len], glyph);
            out += glyph.len;
        }
        return buf[0..out];
    }
};


pub const Spinner = struct {
    label: []const u8,
    accent: []const u8,
    frames: []const []const u8,
    index: usize,

    pub fn start(label: []const u8, accent: []const u8) Spinner {
        var s = Spinner{
            .label = label,
            .accent = accent,
            .frames = &.{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
            .index = 0,
        };
        s.animateIn();
        return s;
    }

    fn animateIn(self: *Spinner) void {
        // The startup spinner is intentionally short and theatrical.
        // It gives expensive setup steps a bit of presence instead of making
        // the CLI feel like it hung before the first useful message.
        var i: usize = 0;
        while (i < 20) : (i += 1) {
            const frame = self.frames[i % self.frames.len];
            std.debug.print(
                "{s}  {s}{s}{s}         {s}{s}{s}  {s}{s}{s}",
                .{
                    CLEAR_LINE,
                    C_RAIL,      G_RAIL, RESET,
                    self.accent, frame,  RESET,
                    C_MUTED,     self.label, RESET,
                },
            );
            std.Thread.sleep(70 * std.time.ns_per_ms);
        }

        std.debug.print(
            "{s}  {s}{s}{s}         {s}{s}{s}  {s}{s}{s}\n",
            .{
                CLEAR_LINE,
                C_RAIL,      G_RAIL, RESET,
                self.accent, self.frames[0], RESET,
                C_MUTED,     self.label, RESET,
            },
        );
    }

    pub fn tick(self: *Spinner) void {
        self.index += 1;
        const frame = self.frames[self.index % self.frames.len];
        std.debug.print(
            "  {s}{s}{s}         {s}{s}{s}  {s}{s}{s}\n",
            .{
                C_RAIL,      G_RAIL, RESET,
                self.accent, frame,  RESET,
                C_MUTED,     self.label, RESET,
            },
        );
    }

    pub fn done(self: *Spinner, message: []const u8) void {
        _ = self;
        std.debug.print(
            "  {s}{s}{s}         {s}✓{s}  {s}{s}{s}\n",
            .{
                C_RAIL,    G_RAIL,  RESET,
                C_SUCCESS, RESET,
                BOLD,      message, RESET,
            },
        );
    }
};

fn progressBarWidth() u8 {
    const cols = termColumns();

    // Reserve room for the text that appears after the bar.
    // These values are intentionally conservative to avoid wrapping.
    if (cols >= 140) return 36;
    if (cols >= 120) return 28;
    if (cols >= 100) return 20;
    if (cols >= 90) return 14;
    if (cols >= 80) return 10;
    return 8;
}

fn termColumns() usize {
    // Respect COLUMNS when it is present and valid.
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "COLUMNS")) |value| {
        defer std.heap.page_allocator.free(value);
        const parsed = std.fmt.parseInt(usize, value, 10) catch 0;
        if (parsed >= 40) return parsed;
    } else |_| {}

    // Be conservative on fallback.
    // Returning 100 here causes wrapping on many normal terminals.
    return 80;
}

fn printBar(width: u8, transferred: u64, total: u64, accent: []const u8) void {
    const partials = [_][]const u8{ "", "▏", "▎", "▍", "▌", "▋", "▊", "▉" };
    const total_units: u64 = if (total > 0)
        @min(@as(u64, width) * 8, (transferred * @as(u64, width) * 8) / total)
    else
        0;

    const full: u64 = total_units / 8;
    const rem: usize = @intCast(total_units % 8);
    const empty: u64 = @as(u64, width) - full - (if (rem > 0) @as(u64, 1) else 0);

    // The bar uses 1/8 block increments so small transfers still show movement
    // instead of looking stuck until a full character cell is earned.
    std.debug.print("{s}▐{s}", .{ C_MUTED, RESET });
    std.debug.print("{s}", .{accent});
    for (0..full) |_| std.debug.print("█", .{});
    if (rem > 0) std.debug.print("{s}", .{partials[rem]});
    std.debug.print("{s}{s}", .{ RESET, C_TRACK });
    for (0..empty) |_| std.debug.print("░", .{});
    std.debug.print("{s}{s}▌{s}", .{ RESET, C_MUTED, RESET });
}


fn formatSeconds(buf: []u8, seconds: f64) []const u8 {
    if (seconds >= 60.0) {
        const total: u64 = @intFromFloat(seconds);
        const mins: u64 = total / 60;
        const secs: u64 = total % 60;
        return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ mins, secs }) catch "--";
    }
    return std.fmt.bufPrint(buf, "{d:.1}s", .{seconds}) catch "--";
}

pub fn formatSize(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var size: f64 = @floatFromInt(bytes);
    var unit: usize = 0;

    while (size >= 1024.0 and unit < units.len - 1) {
        size /= 1024.0;
        unit += 1;
    }

    if (unit == 0) {
        return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, units[0] }) catch "???";
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ size, units[unit] }) catch "???";
}

fn sessionElapsedSeconds() f64 {
    const now = std.time.milliTimestamp();
    return @as(f64, @floatFromInt(now - session_start_ms)) / 1000.0;
}

fn printPipelineNode(name: []const u8, accent: []const u8) void {
    std.debug.print(
        "{s}{s}◇{s}  {s}{s}{s}",
        .{ DIM, C_RAIL, RESET, accent, name, RESET },
    );
}

fn printPipelineArrow() void {
    std.debug.print("  {s}──▸{s}  ", .{ C_RAIL, RESET });
}

pub fn printHeader() void {
    session_start_ms = std.time.milliTimestamp();
    step_num = 0;

    const logo =
        \\         ___           ___           ___           ___
        \\        /\  \         /\  \         /\__\         /\  \
        \\        \:\  \       /::\  \       /::|  |       /::\  \
        \\         \:\  \     /:/\:\  \     /:|:|  |      /:/\:\  \
        \\          \:\  \   /::\~\:\  \   /:/|:|  |__   /:/  \:\__\
        \\    _______\:\__\ /:/\:\ \:\__\ /:/ |:| /\__\ /:/__/ \:|__|
        \\    \::::::::/__/ \:\~\:\ \/__/ \/__|:|/:/  / \:\  \ /:/  /
        \\     \:\~~\~~      \:\ \:\__\       |:/:/  /   \:\  /:/  /
        \\      \:\  \        \:\ \/__/       |::/  /     \:\/:/  /
        \\       \:\__\        \:\__\         /:/  /       \::/__/
        \\        \/__/         \/__/         \/__/         ~~
    ;

    std.debug.print("\n{s}{s}{s}\n\n", .{ C_UPLOAD, logo, RESET });

    
    // The pipeline line is not a strict state machine.
    // It is a quick mental model of the product flow shown before any work starts.
    std.debug.print("  ", .{});
    printPipelineNode("stage", C_SOFT);
    printPipelineArrow();
    printPipelineNode("seal", C_WARN);
    printPipelineArrow();
    printPipelineNode("relay", C_INFO);
    printPipelineArrow();
    printPipelineNode("share", C_UPLOAD);
    printPipelineArrow();
    printPipelineNode("receive", C_SOFT);
    std.debug.print("\n", .{});

    std.debug.print(
        "  {s}v0.1.0  ·  end-to-end encrypted  ·  ciphertext-only relay  ·  single-use link{s}\n\n",
        .{ C_MUTED, RESET },
    );

    std.debug.print("  {s}┏━━━━{s}\n", .{ C_UPLOAD, RESET });
}

pub fn printStep(comptime icon: []const u8, comptime fmt: []const u8, args: anytype) void {
    const is_done = comptime std.mem.eql(u8, icon, "✓");
    if (is_done) {
        std.debug.print("  {s}{s}{s}\n", .{ C_RAIL, G_RAIL, RESET });
        std.debug.print(
            "  {s}{s}{s}         {s}✓{s}  {s}" ++ fmt ++ "{s}\n",
            .{ C_RAIL, G_RAIL, RESET, C_SUCCESS, RESET, BOLD } ++ args ++ .{RESET},
        );
        return;
    }

    step_num += 1;
    const elapsed_sec = sessionElapsedSeconds();

    var title_buf: [256]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, fmt, args) catch "…";

    std.debug.print("  {s}{s}{s}\n", .{ C_RAIL, G_RAIL, RESET });

    // STEP_TS_COL keeps the elapsed timestamp visually aligned even when
    // step titles have different lengths.
    std.debug.print("  {s}{s}{s}   ", .{ C_RAIL, G_RAIL, RESET });
    std.debug.print(
        "{s}{s}[{s}{s}{s}{d:0>2}{s}{s}{s}]{s}  {s}{s}{s}",
        .{
            DIM,  C_RAIL,   RESET,
            BOLD, C_UPLOAD, step_num, RESET,
            DIM,  C_RAIL,   RESET,
            BOLD, title,    RESET,
        },
    );

    std.debug.print(
        "\x1b[{d}G{s}+{d:.2}s{s}\n",
        .{ STEP_TS_COL, C_MUTED, elapsed_sec, RESET },
    );
}

pub fn printDetail(comptime fmt: []const u8, args: anytype) void {
    // Details are subordinate lines under the most recent step.
    std.debug.print(
        "  {s}{s}{s}         {s}" ++ fmt ++ "{s}\n",
        .{ C_RAIL, G_RAIL, RESET, C_MUTED } ++ args ++ .{RESET},
    );
}

pub fn printNote(comptime fmt: []const u8, args: anytype) void {
    // Notes are softer than steps and are used for policy / explanatory text.
    std.debug.print(
        "  {s}{s}{s}         {s}{s}{s}  {s}" ++ fmt ++ "{s}\n",
        .{ C_RAIL, G_RAIL, RESET, C_MUTED, G_DOT, RESET, C_MUTED } ++ args ++ .{RESET},
    );
}

pub fn printError(comptime fmt: []const u8, args: anytype) void {
    // Errors deliberately break the visual rhythm so failure stands out
    // immediately in terminal scrollback.
    std.debug.print("  {s}{s}{s}\n", .{ C_RAIL, G_RAIL, RESET });
    std.debug.print(
        "  {s}{s}{s}         {s}✗{s}  {s}{s}error{s}\n",
        .{ C_RAIL, G_RAIL, RESET, C_ERROR, RESET, BOLD, C_ERROR, RESET },
    );
    std.debug.print(
        "  {s}{s}{s}            " ++ fmt ++ "\n",
        .{ C_RAIL, G_RAIL, RESET } ++ args,
    );
    std.debug.print("  {s}{s}{s}\n", .{ C_RAIL, G_RAIL, RESET });
    std.debug.print(
        "  {s}┗━━━━{s}  {s}✗{s}  {s}{s}aborted{s}\n\n",
        .{ C_ERROR, RESET, C_ERROR, RESET, BOLD, C_ERROR, RESET },
    );
}

pub fn printLink(url: []const u8) void {
    step_num += 1;
    const elapsed_sec = sessionElapsedSeconds();

    std.debug.print("  {s}{s}{s}\n", .{ C_RAIL, G_RAIL, RESET });
    std.debug.print("  {s}{s}{s}   ", .{ C_RAIL, G_RAIL, RESET });
    std.debug.print(
        "{s}{s}[{s}{s}{s}{d:0>2}{s}{s}{s}]{s}  {s}share{s}",
        .{
            DIM,  C_RAIL,   RESET,
            BOLD, C_UPLOAD, step_num, RESET,
            DIM,  C_RAIL,   RESET,
            BOLD, RESET,
        },
    );
    std.debug.print(
        "\x1b[{d}G{s}+{d:.2}s{s}\n",
        .{ STEP_TS_COL, C_MUTED, elapsed_sec, RESET },
    );

    std.debug.print(
        "  {s}{s}{s}         {s}↗{s}  {s}",
        .{ C_RAIL, G_RAIL, RESET, C_UPLOAD, RESET, C_UPLOAD },
    );
    printHyperlink(url, url);
    std.debug.print("{s}\n", .{RESET});
}

pub fn printHyperlink(url: []const u8, text: []const u8) void {
    std.debug.print("\x1b]8;;{s}\x1b\\{s}\x1b]8;;\x1b\\", .{ url, text });
}

pub fn printSummary(filename: []const u8, fileSize: u64, elapsedMs: i64) void {
    var size_buf: [32]u8 = undefined;
    const size_str = formatSize(&size_buf, fileSize);

    const elapsed_sec: f64 = @as(f64, @floatFromInt(elapsedMs)) / 1000.0;
    const speed: u64 = if (elapsedMs > 0)
        @intFromFloat(@as(f64, @floatFromInt(fileSize)) / @max(elapsed_sec, 0.001))
    else
        0;

    var speed_buf: [32]u8 = undefined;
    const speed_str = formatSize(&speed_buf, speed);

    var time_buf: [24]u8 = undefined;
    const time_str = formatSeconds(&time_buf, elapsed_sec);

    // Summary compresses the result into the few numbers a user usually cares
    // about after a transfer: name, size, elapsed time, and average throughput.
    std.debug.print("  {s}{s}{s}\n", .{ C_RAIL, G_RAIL, RESET });
    std.debug.print(
        "  {s}┗━━━━{s}  {s}{s}◉  complete{s}" ++
            "   {s}·{s}  {s}{s}{s}" ++
            "   {s}·{s}  {s}{s}{s}" ++
            "   {s}·{s}  {s}{s}{s}" ++
            "   {s}·{s}  {s}{s}/s{s}\n\n",
        .{
            C_UPLOAD, RESET,
            BOLD,     C_SUCCESS, RESET,
            C_MUTED,  RESET, C_SOFT,  filename,  RESET,
            C_MUTED,  RESET, C_SOFT,  size_str,  RESET,
            C_MUTED,  RESET, C_MUTED, time_str,  RESET,
            C_MUTED,  RESET, C_MUTED, speed_str, RESET,
        },
    );
}
