//! **THE REPORT'S TEXT** (docs/PHYSICS.md, "The report"): the one
//! canonical form of every line, written here (the page's JavaScript never
//! formats a number on the wire) and parsed here, strictly: every other
//! spelling is refused, and every field is bounded as it is parsed.
//!
//! - **Positions** are hex with a point, in 256ths: the whole pixels in
//!   lower case with no leading zeros (`0` for none), a point, then exactly
//!   two hex digits: `d80.40`.
//! - **Displacements** add a sign, `+1.00`, `-2.80`, and are `0` when zero.
//! - **The physics hash** is eight hex digits.
//! - **Everything else is decimal** with no leading zeros: ticks, `+ms`,
//!   `@ms`, `wall`, the epoch, critter numbers, tiles' `c,r`, `WxH`.
//!
//! Lines are separated by `\n`. A critter line is indented one space.
//! No allocator: a `Text` writes into a caller's buffer.

const std = @import("std");
const physics = @import("physics.zig");
const tiles = @import("tiles.zig");
const Point = physics.Point;
const Critter = physics.Critter;
const Disp = physics.Disp;
const Tick = physics.Tick;

/// The wire's version: a page or server on another is told to reload.
/// 2: `/load`'s `level L of U` line, and the levels.
pub const language = 2;
pub const most_tiles = tiles.most_subscribed;

/// **THE PHYSICS HASH**: a CRC-32 of the sources that decide a tick's lines
/// and their text (`physics_sources.zon` names them), built into both the
/// wasm and the server, so a forgotten version change can't cause endless
/// disagreement. The page's exports (physics_page.zig) are among them: the
/// wasm is served under this hash and cached for good, so any change to it
/// must change the name. Computed once at configure time, by build.zig,
/// never here at comptime: each artifact paid about 4 s for that.
pub const physics_hash: u32 = @import("physics_options").physics_hash;

/// A caller's buffer, written into.
pub const Text = struct {
    buf: []u8,
    len: usize = 0,

    pub const Error = error{NoSpace};

    pub fn bytes(self: *const Text) []const u8 {
        return self.buf[0..self.len];
    }
    pub fn str(self: *Text, s: []const u8) Error!void {
        if (self.len + s.len > self.buf.len) return error.NoSpace;
        @memcpy(self.buf[self.len..][0..s.len], s);
        self.len += s.len;
    }
    pub fn char(self: *Text, c: u8) Error!void {
        return self.str(&.{c});
    }
    pub fn dec(self: *Text, v: u64) Error!void {
        var tmp: [20]u8 = undefined;
        var i: usize = tmp.len;
        var n = v;
        while (true) {
            i -= 1;
            tmp[i] = '0' + @as(u8, @intCast(n % 10));
            n /= 10;
            if (n == 0) break;
        }
        return self.str(tmp[i..]);
    }
    fn hexDigits(self: *Text, v: u64, min_digits: usize) Error!void {
        var tmp: [16]u8 = undefined;
        var i: usize = tmp.len;
        var n = v;
        while (n != 0 or tmp.len - i < min_digits) {
            i -= 1;
            tmp[i] = "0123456789abcdef"[@intCast(n & 15)];
            n >>= 4;
        }
        return self.str(tmp[i..]);
    }
    /// A non-negative count of 256ths: `d80.40`.
    pub fn hexPoint(self: *Text, v: u32) Error!void {
        try self.hexDigits(v >> 8, 1);
        try self.char('.');
        try self.hexDigits(v & 255, 2);
    }
    pub fn pos(self: *Text, p: Point) Error!void {
        try self.hexPoint(@intCast(p.x));
        try self.char(',');
        try self.hexPoint(@intCast(p.y));
    }
    /// A displacement: `0`, or a sign and a hex point.
    pub fn disp(self: *Text, v: i32) Error!void {
        if (v == 0) return self.char('0');
        try self.char(if (v < 0) '-' else '+');
        try self.hexPoint(@intCast(physics.mag(v)));
    }
    pub fn hash(self: *Text, h: u32) Error!void {
        return self.hexDigits(h, 8);
    }
    pub fn critter(self: *Text, c: Critter) Error!void {
        try self.str(@tagName(c.kind));
        try self.str(" ");
        try self.dec(c.n);
    }
    pub fn tileList(self: *Text, list: []const tiles.Tile) Error!void {
        for (list) |t| {
            try self.char(' ');
            try self.dec(@intCast(t.col));
            try self.char(',');
            try self.dec(@intCast(t.row));
        }
    }
};

/// A page load's epoch: the server's start (Unix ms), a point, a count.
pub const Epoch = struct { ms: u64, count: u64 };

pub const Header = struct { language: u64, physics: u32, epoch: Epoch, req: u64 };

pub const From = struct { tick: Tick, wall: ?u64 };

/// A set of tiles, as a line lists them.
pub const TileSet = struct {
    list: [most_tiles]tiles.Tile = undefined,
    len: usize = 0,

    pub fn slice(self: *const TileSet) []const tiles.Tile {
        return self.list[0..self.len];
    }
    pub fn holds(self: *const TileSet, t: tiles.Tile) bool {
        for (self.slice()) |h| if (h.col == t.col and h.row == t.row) return true;
        return false;
    }
    /// Adds a tile not already in the set.
    pub fn add(self: *TileSet, t: tiles.Tile) error{TooMany}!void {
        if (self.holds(t)) return;
        if (self.len == most_tiles) return error.TooMany;
        self.list[self.len] = t;
        self.len += 1;
    }
    /// The set in the order the server writes it: by row, then column.
    pub fn sorted(self: *const TileSet) TileSet {
        var s = self.*;
        std.mem.sort(tiles.Tile, s.list[0..s.len], {}, struct {
            fn lt(_: void, a: tiles.Tile, b: tiles.Tile) bool {
                return if (a.row != b.row) a.row < b.row else a.col < b.col;
            }
        }.lt);
        return s;
    }
};

pub const View = struct { tick: Tick, w: u64, h: u64, tiles: TileSet };
pub const Held = struct { tick: Tick, tiles: TileSet };
pub const TLine = struct { tick: Tick, ms: u64, drag: physics.Capped };

/// One line of a report.
pub const Line = union(enum) {
    header: Header,
    from: From,
    leash: struct { tick: Tick, dog: u16 },
    grab: Tick,
    letgo: Tick,
    release: struct { tick: Tick, dog: u16 },
    held: Held,
    view: View,
    t: TLine,
    critter: physics.CritterLine,
    poop: physics.PoopLine,
    eaten: u16,
    bump: struct { tick: Tick, who: physics.Bumped },
    rest: Tick,
};

/// A human input line as the physics takes it, with its tick.
pub fn human(line: Line) ?struct { tick: Tick, h: physics.Human } {
    return switch (line) {
        .leash => |l| .{ .tick = l.tick, .h = .{ .leash = l.dog } },
        .release => |r| .{ .tick = r.tick, .h = .{ .release = r.dog } },
        .grab => |t| .{ .tick = t, .h = .grab },
        .letgo => |t| .{ .tick = t, .h = .letgo },
        else => null,
    };
}

/// **WRITES A LINE**, canonically, with its `\n`.
pub fn write(w: *Text, line: Line) Text.Error!void {
    switch (line) {
        .header => |h| {
            try w.str("dogpark ");
            try w.dec(h.language);
            try w.str(" physics ");
            try w.hash(h.physics);
            try w.str(" page ");
            try w.dec(h.epoch.ms);
            try w.char('.');
            try w.dec(h.epoch.count);
            try w.str(" req ");
            try w.dec(h.req);
        },
        .from => |f| {
            try w.str("from ");
            try w.dec(f.tick);
            if (f.wall) |wall| {
                try w.str(" wall ");
                try w.dec(wall);
            }
        },
        .leash => |l| try tickAndDog(w, "leash ", l.tick, l.dog),
        .release => |r| try tickAndDog(w, "release ", r.tick, r.dog),
        .grab => |t| try tickOnly(w, "grab ", t),
        .letgo => |t| try tickOnly(w, "letgo ", t),
        .rest => |t| try tickOnly(w, "rest ", t),
        .held => |h| {
            try tickOnly(w, "held ", h.tick);
            try w.tileList(h.tiles.slice());
        },
        .view => |v| {
            try tickOnly(w, "view ", v.tick);
            try w.char(' ');
            try w.dec(v.w);
            try w.char('x');
            try w.dec(v.h);
            try w.tileList(v.tiles.slice());
        },
        .t => |t| {
            try tickOnly(w, "t ", t.tick);
            try w.str(" +");
            try w.dec(t.ms);
            if (t.drag.len > 0) {
                try w.str(" drag");
                for (t.drag.slice()) |d| {
                    try w.char(' ');
                    try w.disp(d.dx);
                    try w.char(',');
                    try w.disp(d.dy);
                    try w.char('@');
                    try w.dec(d.ms);
                }
            }
        },
        .critter => |c| {
            try w.char(' ');
            try critterMove(w, c);
        },
        .poop => |p| {
            try w.char(' ');
            try poopAt(w, p.n, p.at);
        },
        .eaten => |n| {
            try w.str(" eaten ");
            try w.dec(n);
        },
        .bump => |b| {
            try tickOnly(w, "bump ", b.tick);
            try w.char(' ');
            switch (b.who) {
                .critter => |c| try w.critter(c),
                .poop => |n| {
                    try w.str("poop ");
                    try w.dec(n);
                },
            }
        },
    }
    try w.char('\n');
}

/// `dog N a > b`, unindented (as `differ` quotes it).
pub fn critterMove(w: *Text, c: physics.CritterLine) Text.Error!void {
    try w.critter(c.who);
    try w.char(' ');
    try w.pos(c.before);
    try w.str(" > ");
    try w.pos(c.after);
}

/// `poop N x,y`, unindented: a line's, and an entry's on a `tile`,
/// `board` or snapshot line.
pub fn poopAt(w: *Text, n: u16, at: Point) Text.Error!void {
    try w.str("poop ");
    try w.dec(n);
    try w.char(' ');
    try w.pos(at);
}

/// A critter as a `tile`, `board` or snapshot entry, unindented: `kind N
/// x,y`, and a dog's walk when it has walked (`walked H`, hex with a
/// point).
pub fn entry(w: *Text, b: *const physics.Board, c: Critter) Text.Error!void {
    try w.critter(c);
    try w.char(' ');
    try w.pos(b.at(c));
    if (c.kind == physics.leashed_kind and b.walked[c.n] != 0) {
        try w.str(" walked ");
        try w.hexPoint(b.walked[c.n]);
    }
}

fn tickOnly(w: *Text, word: []const u8, t: Tick) Text.Error!void {
    try w.str(word);
    try w.dec(t);
}

fn tickAndDog(w: *Text, word: []const u8, t: Tick, dog: u16) Text.Error!void {
    try tickOnly(w, word, t);
    try w.char(' ');
    try w.dec(dog);
}

/// A tick's checked line as a report line.
pub fn checkedLine(t: Tick, c: physics.Checked) Line {
    return switch (c) {
        .critter => |l| .{ .critter = l },
        .poop => |p| .{ .poop = p },
        .eaten => |n| .{ .eaten = n },
        .bump => |who| .{ .bump = .{ .tick = t, .who = who } },
        .release => |d| .{ .release = .{ .tick = t, .dog = d } },
        .rest => .{ .rest = t },
    };
}

/// Whether two lines say the same, by their parsed integers (a tile list
/// as a set; `+ms`, `@ms` and `wall` included, though only inputs carry
/// them).
pub fn same(a: Line, b: Line) bool {
    // A tick's checked lines, field for field the same, write the same
    // text: the judge's every line, compared without writing it (202).
    // Any other pair is written out and compared, as before.
    if (std.meta.activeTag(a) == std.meta.activeTag(b)) switch (a) {
        .critter => |l| if (std.meta.eql(l, b.critter)) return true,
        .poop => |l| if (std.meta.eql(l, b.poop)) return true,
        .eaten => |n| if (n == b.eaten) return true,
        .bump => |l| if (std.meta.eql(l, b.bump)) return true,
        .release => |l| if (std.meta.eql(l, b.release)) return true,
        .rest => |t| if (t == b.rest) return true,
        else => {},
    };
    var x: [1024]u8 = undefined;
    var y: [1024]u8 = undefined;
    var wa: Text = .{ .buf = &x };
    var wb: Text = .{ .buf = &y };
    switch (a) {
        .held, .view => {
            // Sets: compare sorted.
            return std.meta.activeTag(a) == std.meta.activeTag(b) and sameSet(a, b);
        },
        else => {},
    }
    write(&wa, a) catch return false;
    write(&wb, b) catch return false;
    return std.mem.eql(u8, wa.bytes(), wb.bytes());
}

fn sameSet(a: Line, b: Line) bool {
    var x: [1024]u8 = undefined;
    var y: [1024]u8 = undefined;
    var wa: Text = .{ .buf = &x };
    var wb: Text = .{ .buf = &y };
    write(&wa, sortedTiles(a)) catch return false;
    write(&wb, sortedTiles(b)) catch return false;
    return std.mem.eql(u8, wa.bytes(), wb.bytes());
}

fn sortedTiles(l: Line) Line {
    return switch (l) {
        .held => |h| .{ .held = .{ .tick = h.tick, .tiles = h.tiles.sorted() } },
        .view => |v| .{ .view = .{ .tick = v.tick, .w = v.w, .h = v.h, .tiles = v.tiles.sorted() } },
        else => l,
    };
}

// ---------------------------------------------------------------- parsing

pub const ParseError = error{Malformed};

/// The first `c` in `s`, byte by byte (202): a report's words and lines
/// are a few bytes to a few dozen, where `std.mem.indexOfScalar`'s vector
/// set-up costs more than the scan.
fn find(s: []const u8, c: u8) ?usize {
    for (s, 0..) |b, i| if (b == c) return i;
    return null;
}

/// The words of a line, split on single spaces: an empty word (two spaces,
/// a leading or trailing one) is malformed.
const Words = struct {
    rest: []const u8,
    done: bool = false,

    fn next(self: *Words) ParseError![]const u8 {
        if (self.done) return error.Malformed;
        const at = find(self.rest, ' ');
        const word = if (at) |i| self.rest[0..i] else self.rest;
        if (at) |i| self.rest = self.rest[i + 1 ..] else self.done = true;
        if (word.len == 0) return error.Malformed;
        return word;
    }
    fn more(self: *const Words) bool {
        return !self.done;
    }
    fn end(self: *const Words) ParseError!void {
        if (!self.done) return error.Malformed;
    }
    fn expect(self: *Words, word: []const u8) ParseError!void {
        if (!std.mem.eql(u8, try self.next(), word)) return error.Malformed;
    }
};

/// A canonical decimal: digits, no leading zero but `0` itself, at most
/// `most`.
pub fn parseDec(s: []const u8, most: u64) ParseError!u64 {
    if (s.len == 0 or s.len > 19) return error.Malformed;
    if (s[0] == '0' and s.len > 1) return error.Malformed;
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return error.Malformed;
        v = v * 10 + (c - '0');
    }
    if (v > most) return error.Malformed;
    return v;
}

fn hexDigit(c: u8) ParseError!u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => error.Malformed,
    };
}

/// A canonical hex point: `d80.40`, at most `most` 256ths.
pub fn parseHexPoint(s: []const u8, most: u32) ParseError!u32 {
    const dot = find(s, '.') orelse return error.Malformed;
    const whole = s[0..dot];
    const frac = s[dot + 1 ..];
    if (whole.len == 0 or whole.len > 6 or frac.len != 2) return error.Malformed;
    if (whole[0] == '0' and whole.len > 1) return error.Malformed;
    var v: u64 = 0;
    for (whole) |c| v = v * 16 + try hexDigit(c);
    for (frac) |c| v = v * 16 + try hexDigit(c);
    if (v > most) return error.Malformed;
    return @intCast(v);
}

/// A position in the board's level's world (`g`): `x,y`, each 0 to the
/// world's side, less 1/256.
pub fn parsePos(g: physics.Geometry, s: []const u8) ParseError!Point {
    const comma = find(s, ',') orelse return error.Malformed;
    const most: u32 = @intCast(g.world - 1);
    return .{ .x = @intCast(try parseHexPoint(s[0..comma], most)), .y = @intCast(try parseHexPoint(s[comma + 1 ..], most)) };
}

/// A displacement: `0`, or a sign and a nonzero hex point, at most 100 px.
pub fn parseDisp(s: []const u8) ParseError!i32 {
    if (std.mem.eql(u8, s, "0")) return 0;
    if (s.len < 2) return error.Malformed;
    const v: i32 = @intCast(try parseHexPoint(s[1..], physics.cap));
    if (v == 0) return error.Malformed;
    return switch (s[0]) {
        '+' => v,
        '-' => -v,
        else => error.Malformed,
    };
}

fn parseHash(s: []const u8) ParseError!u32 {
    if (s.len != 8) return error.Malformed;
    var v: u32 = 0;
    for (s) |c| v = v * 16 + try hexDigit(c);
    return v;
}

fn parseTick(s: []const u8) ParseError!Tick {
    return parseDec(s, std.math.maxInt(u32));
}

fn parseCritter(kind: []const u8, n: []const u8) ParseError!Critter {
    const k = std.meta.stringToEnum(physics.Kind, kind) orelse return error.Malformed;
    return .of(k, try parseNumber(n, physics.countOf(k)));
}

/// A critter's number among `count` of its kind: `0` to `count` - 1, and
/// none when there are none.
pub fn parseNumber(n: []const u8, count: u16) ParseError!u16 {
    if (count == 0) return error.Malformed;
    return @intCast(try parseDec(n, count - 1));
}

pub fn parsePoopNumber(n: []const u8) ParseError!u16 {
    return @intCast(try parseDec(n, physics.poop_count - 1));
}

fn parseTile(g: physics.Geometry, s: []const u8) ParseError!tiles.Tile {
    const comma = find(s, ',') orelse return error.Malformed;
    const top: u64 = @intCast(g.world_tiles - 1);
    return .{ .col = @intCast(try parseDec(s[0..comma], top)), .row = @intCast(try parseDec(s[comma + 1 ..], top)) };
}

/// The rest of a line's words as a tile set: in the world, at most 64, none
/// twice.
fn parseTiles(g: physics.Geometry, w: *Words) ParseError!TileSet {
    var set: TileSet = .{};
    while (w.more()) {
        const t = try parseTile(g, try w.next());
        if (set.holds(t)) return error.Malformed;
        set.add(t) catch return error.Malformed;
    }
    return set;
}

/// **PARSES A LINE**, without its `\n`: canonical, and every field bounded,
/// positions and tiles by the board's level's world (`g`).
pub fn parse(g: physics.Geometry, text: []const u8) ParseError!Line {
    if (text.len > 0 and text[0] == ' ') {
        var w: Words = .{ .rest = text[1..] };
        const kind = try w.next();
        if (std.mem.eql(u8, kind, "poop")) {
            const n = try parsePoopNumber(try w.next());
            const at = try parsePos(g, try w.next());
            try w.end();
            return .{ .poop = .{ .n = n, .at = at } };
        }
        if (std.mem.eql(u8, kind, "eaten")) {
            const n = try parsePoopNumber(try w.next());
            try w.end();
            return .{ .eaten = n };
        }
        const who = try parseCritter(kind, try w.next());
        const before = try parsePos(g, try w.next());
        try w.expect(">");
        const after = try parsePos(g, try w.next());
        try w.end();
        return .{ .critter = .{ .who = who, .before = before, .after = after } };
    }
    var w: Words = .{ .rest = text };
    const word = try w.next();
    if (std.mem.eql(u8, word, "dogpark")) {
        const lang = try parseDec(try w.next(), std.math.maxInt(u32));
        try w.expect("physics");
        const hash = try parseHash(try w.next());
        try w.expect("page");
        const page = try w.next();
        const dot = find(page, '.') orelse return error.Malformed;
        const epoch: Epoch = .{ .ms = try parseDec(page[0..dot], std.math.maxInt(u63)), .count = try parseDec(page[dot + 1 ..], std.math.maxInt(u32)) };
        try w.expect("req");
        const req = try parseDec(try w.next(), std.math.maxInt(u32));
        try w.end();
        return .{ .header = .{ .language = lang, .physics = hash, .epoch = epoch, .req = req } };
    }
    if (std.mem.eql(u8, word, "from")) {
        const t = try parseTick(try w.next());
        var wall: ?u64 = null;
        if (w.more()) {
            try w.expect("wall");
            wall = try parseDec(try w.next(), std.math.maxInt(u63));
        }
        try w.end();
        return .{ .from = .{ .tick = t, .wall = wall } };
    }
    if (std.mem.eql(u8, word, "leash") or std.mem.eql(u8, word, "release")) {
        const t = try parseTick(try w.next());
        const dog = try parseNumber(try w.next(), physics.countOf(physics.leashed_kind));
        try w.end();
        return if (word[0] == 'l') .{ .leash = .{ .tick = t, .dog = dog } } else .{ .release = .{ .tick = t, .dog = dog } };
    }
    if (std.mem.eql(u8, word, "grab") or std.mem.eql(u8, word, "letgo") or std.mem.eql(u8, word, "rest")) {
        const t = try parseTick(try w.next());
        try w.end();
        return switch (word[0]) {
            'g' => .{ .grab = t },
            'l' => .{ .letgo = t },
            else => .{ .rest = t },
        };
    }
    if (std.mem.eql(u8, word, "held")) {
        const t = try parseTick(try w.next());
        return .{ .held = .{ .tick = t, .tiles = try parseTiles(g, &w) } };
    }
    if (std.mem.eql(u8, word, "view")) {
        const t = try parseTick(try w.next());
        const size = try w.next();
        const x = find(size, 'x') orelse return error.Malformed;
        const wide = try parseDec(size[0..x], 1 << 16);
        const high = try parseDec(size[x + 1 ..], 1 << 16);
        return .{ .view = .{ .tick = t, .w = wide, .h = high, .tiles = try parseTiles(g, &w) } };
    }
    if (std.mem.eql(u8, word, "bump")) {
        const t = try parseTick(try w.next());
        const kind = try w.next();
        const n = try w.next();
        const who: physics.Bumped = if (std.mem.eql(u8, kind, "poop")) .{ .poop = try parsePoopNumber(n) } else .{ .critter = try parseCritter(kind, n) };
        try w.end();
        return .{ .bump = .{ .tick = t, .who = who } };
    }
    if (std.mem.eql(u8, word, "t")) {
        const t = try parseTick(try w.next());
        const ms = try w.next();
        if (ms.len < 2 or ms[0] != '+') return error.Malformed;
        var line: TLine = .{ .tick = t, .ms = try parseDec(ms[1..], std.math.maxInt(u32)), .drag = .{} };
        if (w.more()) {
            try w.expect("drag");
            while (w.more()) {
                if (line.drag.len == physics.most_displacements) return error.Malformed;
                line.drag.list[line.drag.len] = try parseDispWord(try w.next());
                line.drag.len += 1;
            }
            if (line.drag.len == 0) return error.Malformed;
        }
        return .{ .t = line };
    }
    return error.Malformed;
}

/// `dx,dy@ms`.
fn parseDispWord(s: []const u8) ParseError!Disp {
    const comma = find(s, ',') orelse return error.Malformed;
    const at = find(s, '@') orelse return error.Malformed;
    if (at < comma) return error.Malformed;
    return .{
        .dx = try parseDisp(s[0..comma]),
        .dy = try parseDisp(s[comma + 1 .. at]),
        .ms = @intCast(try parseDec(s[at + 1 ..], std.math.maxInt(u32))),
    };
}

/// An entry of a `tile`, `board` or snapshot line: a critter where it
/// stands (and a dog's walk), or a poop.
pub const Entry = union(enum) {
    critter: struct { who: Critter, at: Point, walked: u32 },
    poop: struct { n: u16, at: Point },
};

/// The entries on the rest of a line, as `entry` and `poopAt` write them,
/// separated by single spaces.
pub const Entries = struct {
    w: Words,
    /// The board's level's geometry, which bounds the positions.
    g: physics.Geometry,

    pub fn of(g: physics.Geometry, rest: []const u8) Entries {
        return .{ .w = .{ .rest = rest, .done = rest.len == 0 }, .g = g };
    }
    pub fn next(self: *Entries) ParseError!?Entry {
        if (!self.w.more()) return null;
        const kind = try self.w.next();
        const n = try self.w.next();
        if (std.mem.eql(u8, kind, "poop")) return .{ .poop = .{ .n = try parsePoopNumber(n), .at = try parsePos(self.g, try self.w.next()) } };
        const who = try parseCritter(kind, n);
        const at = try parsePos(self.g, try self.w.next());
        var walked: u32 = 0;
        if (who.kind == physics.leashed_kind and self.w.more() and std.mem.startsWith(u8, self.w.rest, "walked ")) {
            _ = try self.w.next();
            walked = try parseHexPoint(try self.w.next(), std.math.maxInt(u32));
            if (walked == 0) return error.Malformed;
        }
        return .{ .critter = .{ .who = who, .at = at, .walked = walked } };
    }
};

/// The lines of a text, split on `\n`; a last line without one is still a
/// line, an empty line is malformed (`next` returns it for the caller to
/// refuse).
pub const Lines = struct {
    rest: []const u8,

    pub fn next(self: *Lines) ?[]const u8 {
        if (self.rest.len == 0) return null;
        const at = find(self.rest, '\n');
        const line = if (at) |i| self.rest[0..i] else self.rest;
        self.rest = if (at) |i| self.rest[i + 1 ..] else self.rest[self.rest.len..];
        return line;
    }
};

test {
    _ = @import("physics_wire_test.zig");
}
