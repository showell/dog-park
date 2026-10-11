//! The application: Dog Park as webbox serves it (`webbox.site.Site(App)`).
//! Its route table, its one-time setup, and the device's identity. **GLUE,
//! KEPT THIN**: each handler reads the request, calls a pure function
//! (answering.answer), keeps what changed (world.World.keep), and writes the
//! answer.
//!
//!   GET  /          the page, naming its script by its bytes
//!   GET  /park.js   the browser's half (park.js), embedded
//!   POST /scene     a wire.WireSceneRequest in, a wire.WireAnswer out, JSON

const std = @import("std");
const Io = std.Io;
const webbox = @import("webbox");
const http = webbox.http;
const signed_cookie = webbox.signed_cookie;
const park = @import("park.zig");
const dogs = @import("dogs.zig");
const wire = @import("wire.zig");
const world = @import("world.zig");
const answering = @import("answering.zig");
const claiming = @import("claiming.zig");
const humans = @import("humans.zig");
const HumanId = humans.HumanId;

pub const park_js = @embedFile("park.js");

/// The longest `POST /scene` body: a request is under 200 bytes.
pub const longest_body = 1024;

/// Every route's cap on a body (webbox's body.zig reads it from the head,
/// metal-vmm QUEUE 167.2): the scene request is the only one with a body,
/// so every path takes at most its cap, and every body is read before the
/// turn.
pub fn bodyLimit(_: []const u8) u64 {
    return longest_body;
}

/// The most other dogs one scene sends: enough for a screen of them.
pub const most_others = 2000;

/// **THE DEVICE'S IDENTITY**: a signed cookie naming the human's id, 32
/// lowercase hex digits (128 random bits, humans.zig), for a year.
pub const device_cookie: signed_cookie.Cookie = .{ .name = webbox.http.host_prefix ++ "dogpark_human", .legacy_name = "dogpark_human", .kind = .{
    .label = "dogpark_human\n",
    .lifetime_secs = 365 * 24 * 60 * 60,
    .skew_secs = 5 * 60,
    .validId = isHumanName,
} };

fn isHumanName(id: []const u8) bool {
    return HumanId.parse(id) != null;
}

/// The world this process serves, opened by `setup`: one handler runs at a
/// time (webbox's hosts), so it is shared plainly.
var the_world: world.World = undefined;
/// Where the signing secret lives.
var auth_dir: []const u8 = undefined;

pub const StartReport = struct {
    data_dir: []const u8,
    dogs: u32,
    /// Whether this start made the park's dogs (a fresh park).
    made: @FieldType(world.World, "made"),
    /// Temporaries a stopped write left in `dogs/`, passed over.
    left_over: u32,
    secret: enum { found, created },
};

/// The development folders, for a run with no config (a checkout).
const default_roots: webbox.site.Roots = .{ .data_dir = "data", .auth_dir = "auth" };

pub fn setup(io: Io, base: std.mem.Allocator, roots: ?webbox.site.Roots) !StartReport {
    const r = roots orelse default_roots;
    auth_dir = r.auth_dir;
    var scratch: std.heap.ArenaAllocator = .init(base);
    defer scratch.deinit();
    // **THE FIRST SECRET IS MADE HERE** (Dog Park's droplet is its own, so
    // the frictionless choice is right): with none, no cookie is issued.
    const secret: @FieldType(StartReport, "secret") = if (try webbox.site_secret.load(io, scratch.allocator(), r.auth_dir)) |_| .found else blk: {
        try webbox.site_secret.create(io, scratch.allocator(), r.auth_dir);
        break :blk .created;
    };
    switch (try world.World.open(io, base, scratch.allocator(), r.data_dir, world.the_park, claiming.dog_count, claiming.dogs_seed)) {
        .world => |w| the_world = w,
        .refused => |refused| {
            // **WHAT DOES NOT READ STOPS THE START, NAMED** (fail, never warn).
            switch (refused) {
                .dog_record => |d| std.debug.print("dog-park: {s}/dogs/{s} stops the start ({t}); not starting\n", .{ r.data_dir, d.name, d.why }),
                .dogs_folder => |d| std.debug.print("dog-park: {s}/dogs holds {d} of the park's {d} dogs: not a fresh park, nor a whole one; not starting\n", .{ r.data_dir, d.found, d.count }),
                .dog_count => |d| std.debug.print("dog-park: {d} dogs do not fit the park's {d} lattice spots (or are none); not starting\n", .{ d.count, d.spots }),
            }
            return error.ParkDoesNotOpen;
        },
    }
    return .{ .data_dir = r.data_dir, .dogs = @intCast(the_world.all.len), .made = the_world.made, .left_over = the_world.left_over, .secret = secret };
}

pub fn routes(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, _: *webbox.bus.Bus) !void {
    const path = http.pathOf(try http.target(req, alloc));
    if (std.mem.eql(u8, path, "/")) {
        if (req.head.method != .GET) return http.methodNotAllowed(req);
        return req.respond(try page(alloc), .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }} });
    }
    if (std.mem.eql(u8, path, "/park.js")) {
        if (req.head.method != .GET) return http.methodNotAllowed(req);
        return http.serveEmbedded(req, park_js, .{ .name = "content-type", .value = "text/javascript; charset=utf-8" });
    }
    if (std.mem.eql(u8, path, "/scene")) {
        if (req.head.method != .POST) return http.methodNotAllowed(req);
        return scene(req, io, alloc);
    }
    return http.notFound(req);
}

fn page(alloc: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\<!doctype html>
        \\<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>Dog Park</title>
        \\<style>html, body {{ margin: 0; height: 100%; overflow: hidden; }} canvas {{ display: block; width: 100vw; height: 100vh; touch-action: none; }}</style>
        \\</head><body><canvas id="park"></canvas>
        \\{s}
        \\</body></html>
        \\
    , .{try http.scriptTag(alloc, "/park.js", park_js)});
}

/// `POST /scene`: who is asking, what they ask, the answer, and what it
/// changed kept.
fn scene(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator) !void {
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    // The cookie is read with the head, which reading the body invalidates.
    const visitor = try visitorOf(req, io, alloc, now);
    const body = (try http.readLimitedBody(req, alloc, longest_body)) orelse return;
    const asked = std.json.parseFromSliceLeaky(wire.WireSceneRequest, alloc, body, .{}) catch
        return req.respond("The scene request did not read.\n", .{ .status = .bad_request, .keep_alive = false });
    const request = switch (asked.read(the_world.park)) {
        .request => |r| r,
        .refused => |why| return req.respond(try std.fmt.allocPrint(alloc, "The scene request was refused: {t}.\n", .{why}), .{ .status = .bad_request, .keep_alive = false }),
    };
    // A new device becomes a human only once its request reads.
    const who: Who = switch (visitor.visitor) {
        .known => |h| .{ .human = h, .set_cookie = visitor.renewal },
        .new_device => try newDevice(io, alloc, now),
    };
    const room: answering.Room = .{ .others = try alloc.alloc(dogs.Drawn, most_others), .found = try alloc.alloc(dogs.Dog, most_others) };
    // Claims run on the monotonic clock (dogs.Instant); the cookie, on the
    // wall clock it is signed with.
    const claims_now: dogs.Instant = .of(@intCast(@divFloor(Io.Clock.now(.awake, io).nanoseconds, std.time.ns_per_s)));
    const answered = answering.answer(the_world.park, the_world.population(), the_world.all, who.human, the_world.holding(who.human), claims_now, request, room);
    try the_world.keep(io, alloc, answered.change);
    const out = try std.json.Stringify.valueAlloc(alloc, wire.WireAnswer.of(answered.scene, try alloc.alloc(wire.WireDog, most_others)), .{});
    const json: std.http.Header = .{ .name = "content-type", .value = "application/json" };
    switch (who.set_cookie) {
        .header => |h| try req.respond(out, .{ .extra_headers = &.{ json, .{ .name = "set-cookie", .value = h } } }),
        .none => try req.respond(out, .{ .extra_headers = &.{json} }),
    }
}

/// A device new to the park: a human made for it, and the cookie that says so.
fn newDevice(io: Io, alloc: std.mem.Allocator, now: i64) !Who {
    const h = try the_world.newHuman(io);
    var name: [32]u8 = undefined;
    const issued = (try signed_cookie.issue(device_cookie, io, alloc, auth_dir, h.name(&name), now)) orelse return error.NoSecret;
    return .{ .human = h, .set_cookie = .{ .header = issued } };
}

const SetCookie = union(enum) {
    none,
    header: []const u8,
};

const Who = struct {
    human: HumanId,
    set_cookie: SetCookie,
};

const VisitorRead = struct {
    visitor: humans.Visitor,
    renewal: SetCookie,
};

/// Who the request is from, by its cookie. **NO COOKIE, OR ONE THAT DOES NOT
/// VERIFY (a forgery, or past its year), IS A NEW DEVICE**: the browser
/// drops a cookie at its year anyway, and a forged one names no one.
fn visitorOf(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, now: i64) !VisitorRead {
    return switch (try signed_cookie.read(device_cookie, io, alloc, req, auth_dir, now)) {
        .none, .invalid => .{ .visitor = .new_device, .renewal = .none },
        .no_secret => error.NoSecret,
        .verified => |v| .{
            .visitor = .{
                // The cookie's kind takes a human's name only.
                .known = HumanId.parse(v.id) orelse unreachable,
            },
            .renewal = if (signed_cookie.needsRenewal(device_cookie, v, now)) .{
                .header = (try signed_cookie.issue(device_cookie, io, alloc, auth_dir, v.id, now)) orelse return error.NoSecret,
            } else .none,
        },
    };
}

// ── tests: canned requests through the site, as webbox's own are ────────────

const testing = std.testing;
const Served = webbox.site.Site(@This());

const Rig = struct {
    arena: std.heap.ArenaAllocator,
    threaded: std.Io.Threaded,
    tmp: testing.TmpDir,
    hub: webbox.bus.Hub,
    report: StartReport,

    fn init(self: *Rig) !void {
        self.arena = .init(testing.allocator);
        self.threaded = .init(self.arena.allocator(), .{});
        self.tmp = testing.tmpDir(.{});
        const a = self.arena.allocator();
        const root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &self.tmp.sub_path });
        self.report = try setup(self.threaded.io(), testing.allocator, .{
            .data_dir = try std.fs.path.join(a, &.{ root, "data" }),
            .auth_dir = try std.fs.path.join(a, &.{ root, "auth" }),
        });
        self.hub = webbox.bus.Hub.init(self.threaded.io(), testing.allocator);
    }

    fn deinit(self: *Rig) void {
        self.hub.entries.deinit(testing.allocator);
        the_world.close(testing.allocator);
        self.tmp.cleanup();
        self.threaded.deinit();
        self.arena.deinit();
    }

    const Response = struct { head: []const u8, body: []const u8 };

    fn send(self: *Rig, raw: []const u8) !Response {
        const a = self.arena.allocator();
        var out: std.Io.Writer.Allocating = .init(a);
        var reader: std.Io.Reader = .fixed(raw);
        var server = std.http.Server.init(&reader, &out.writer);
        var req = try server.receiveHead();
        var b = webbox.bus.Bus.of(&self.hub);
        try testing.expect((try Served.route(&req, self.threaded.io(), a, &b)) == null);
        try out.writer.flush();
        const all = out.written();
        const split = std.mem.indexOf(u8, all, "\r\n\r\n").?;
        return .{ .head = all[0..split], .body = all[split + 4 ..] };
    }

    /// The claim on disk of dog `id`.
    fn storedClaim(self: *Rig, id: dogs.DogId) !dogs.Claim {
        const a = self.arena.allocator();
        var name: [10]u8 = undefined;
        const path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &self.tmp.sub_path, "data", "dogs", std.fmt.bufPrint(&name, "{d}", .{id.number()}) catch unreachable });
        const bytes = try webbox.store.read(self.threaded.io(), a, path, .limited(64));
        return (@import("stored.zig").readRecord(bytes, world.the_park) orelse return error.NotARecord).dog.claim;
    }

    fn post(self: *Rig, cookie: []const u8, body: []const u8) !Response {
        const a = self.arena.allocator();
        const cookie_line = if (cookie.len == 0) "" else try std.fmt.allocPrint(a, "Cookie: {s}\r\n", .{cookie});
        return self.send(try std.fmt.allocPrint(a, "POST /scene HTTP/1.1\r\nHost: x\r\n{s}Content-Length: {d}\r\n\r\n{s}", .{ cookie_line, body.len, body }));
    }
};

/// The human a cookie names (`name=<id>.<issued>.<mac>`).
fn humanOf(cookie: []const u8) HumanId {
    const eq = std.mem.indexOfScalar(u8, cookie, '=').?;
    const dot = std.mem.indexOfScalarPos(u8, cookie, eq, '.').?;
    return HumanId.parse(cookie[eq + 1 .. dot]).?;
}

/// The cookie a response sets, as a request sends it back: `name=value`.
fn cookieSet(head: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, head, "set-cookie: ") orelse return "";
    const rest = head[at + "set-cookie: ".len ..];
    return rest[0..std.mem.indexOfScalar(u8, rest, ';').?];
}

const stay_body =
    \\{"viewport_plane_x":2300,"viewport_plane_y":2300,"viewport_width":400,"viewport_height":300,"move":{"stay":{}}}
;

test "a first visit is given a dog provisionally, written nowhere; with its cookie it is the same dog; a drag makes it held, and written" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try testing.expectEqual(.created, rig.report.secret);
    try testing.expectEqual(.made_now, rig.report.made);
    const a = rig.arena.allocator();
    const first = try rig.post("", stay_body);
    try testing.expect(std.mem.startsWith(u8, first.head, "HTTP/1.1 200"));
    const cookie = cookieSet(first.head);
    try testing.expect(std.mem.startsWith(u8, cookie, "__Host-dogpark_human="));
    const me = humanOf(cookie);
    const given = the_world.holding(me).holds;
    try testing.expect(the_world.all[given.number()].claim == .provisional);
    const shown = (try std.json.parseFromSliceLeaky(std.json.Value, a, first.body, .{})).object.get("scene").?.object.get("own").?.object.get("has_dog").?.object;
    try testing.expectEqualStrings("new_dog", shown.get("is").?.string);

    const second = try rig.post(cookie, stay_body);
    try testing.expect(std.mem.indexOf(u8, second.head, "set-cookie") == null);
    try testing.expectEqual(given, the_world.holding(me).holds);
    const at = the_world.all[given.number()].at.point;
    try testing.expectEqual(@as(i64, at.x.number()), shown.get("plane_x").?.integer);
    try testing.expectEqual(dogs.Claim.unclaimed, try rig.storedClaim(given));

    const drag =
        \\{"viewport_plane_x":2300,"viewport_plane_y":2300,"viewport_width":400,"viewport_height":300,"move":{"drag":{"own_dog_dx":30,"own_dog_dy":-20}}}
    ;
    const third = try rig.post(cookie, drag);
    const own = (try std.json.parseFromSliceLeaky(std.json.Value, a, third.body, .{})).object.get("scene").?.object.get("own").?.object.get("has_dog").?.object;
    try testing.expectEqualStrings("moved", own.get("move").?.string);
    try testing.expectEqual(@as(i64, at.x.number() + 30), own.get("plane_x").?.integer);
    try testing.expectEqual(@as(i64, at.y.number() - 20), own.get("plane_y").?.integer);
    try testing.expectEqual(at.plus(.{ .dx = 30, .dy = -20 }), @import("frames.zig").homeCopy(the_world.all[given.number()].at.point));
    try testing.expectEqual(dogs.Claim{ .held = .{ .by = me } }, try rig.storedClaim(given));
}

test "cookie-less requests write nothing: each is a new human with a provisional claim in memory only" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    for (0..20) |_| _ = try rig.post("", stay_body);
    var provisional: usize = 0;
    for (the_world.all) |d| {
        if (d.claim == .provisional) provisional += 1;
        try testing.expectEqual(dogs.Claim.unclaimed, try rig.storedClaim(d.id));
    }
    try testing.expectEqual(@as(usize, 20), provisional);
}

test "a forged cookie is a new device, never the human it names" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const first = try rig.post("", stay_body);
    const cookie = cookieSet(first.head);
    const forged = try std.fmt.allocPrint(rig.arena.allocator(), "{s}x", .{cookie});
    const again = try rig.post(forged, stay_body);
    const other = cookieSet(again.head);
    try testing.expect(humanOf(other) != humanOf(cookie));
}

test "a request that does not read, is refused, or is too long is a 4xx, and makes no human" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try testing.expect(std.mem.startsWith(u8, (try rig.post("", "{\"nope\":1}")).head, "HTTP/1.1 400"));
    const far =
        \\{"viewport_plane_x":99999999,"viewport_plane_y":0,"viewport_width":400,"viewport_height":300,"move":{"stay":{}}}
    ;
    const refused = try rig.post("", far);
    try testing.expect(std.mem.startsWith(u8, refused.head, "HTTP/1.1 400"));
    try testing.expect(std.mem.indexOf(u8, refused.body, "viewport_far_from_park") != null);
    const long = try rig.arena.allocator().alloc(u8, longest_body + 1);
    @memset(long, ' ');
    try testing.expect(std.mem.startsWith(u8, (try rig.post("", long)).head, "HTTP/1.1 413"));
    // None of those set a cookie: a human is made only once a request reads.
    try testing.expectEqual(@as(usize, 0), the_world.holders.count());
}

test "the page names its script by its bytes, and the script is served" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const home = try rig.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, home.head, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, home.body, "<script src=\"/park.js?h=") != null);
    const js = try rig.send("GET /park.js HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, js.head, "HTTP/1.1 200"));
    try testing.expectEqualStrings(park_js, js.body);
    try testing.expect(std.mem.startsWith(u8, (try rig.send("GET /nowhere HTTP/1.1\r\nHost: x\r\n\r\n")).head, "HTTP/1.1 404"));
    try testing.expect(std.mem.startsWith(u8, (try rig.send("GET /scene HTTP/1.1\r\nHost: x\r\n\r\n")).head, "HTTP/1.1 405"));
}

test "a second start finds the secret and the dogs" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const drag =
        \\{"viewport_plane_x":2300,"viewport_plane_y":2300,"viewport_width":400,"viewport_height":300,"move":{"drag":{"own_dog_dx":5,"own_dog_dy":0}}}
    ;
    const cookie = cookieSet((try rig.post("", stay_body)).head);
    _ = try rig.post(cookie, drag);
    // Another, given a dog and never dragging it: provisional, forgotten.
    const looker = cookieSet((try rig.post("", stay_body)).head);
    the_world.close(testing.allocator);
    const a = rig.arena.allocator();
    const root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &rig.tmp.sub_path });
    const again = try setup(rig.threaded.io(), testing.allocator, .{
        .data_dir = try std.fs.path.join(a, &.{ root, "data" }),
        .auth_dir = try std.fs.path.join(a, &.{ root, "auth" }),
    });
    try testing.expectEqual(.found, again.secret);
    try testing.expectEqual(claiming.dog_count, again.dogs);
    try testing.expectEqual(.found, again.made);
    try testing.expect(the_world.holding(humanOf(cookie)) == .holds);
    try testing.expect(the_world.holding(humanOf(looker)) == .holds_none);
}

test "a cookie names its human by 32 hex digits, and one of the old counter's numbers names no one (docs/CLAIMS-V1.md)" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const a = rig.arena.allocator();
    const first = cookieSet((try rig.post("", stay_body)).head);
    const value = first[std.mem.indexOfScalar(u8, first, '=').? + 1 ..];
    try testing.expectEqual(@as(usize, 32), std.mem.indexOfScalar(u8, value, '.').?);
    // A cookie the old counter's way, signed now with the site's own secret:
    // a number names no human, so its device is new, with a cookie of its own.
    const secret_dir = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &rig.tmp.sub_path, "auth" });
    var digits = device_cookie;
    digits.kind.validId = struct {
        fn any(_: []const u8) bool {
            return true;
        }
    }.any;
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, rig.threaded.io()).nanoseconds, std.time.ns_per_s));
    const numbered = (try signed_cookie.issue(digits, rig.threaded.io(), a, secret_dir, "1", now)).?;
    const answered = try rig.post(numbered[0..std.mem.indexOfScalar(u8, numbered, ';').?], stay_body);
    try testing.expect(std.mem.startsWith(u8, answered.head, "HTTP/1.1 200"));
    const fresh = cookieSet(answered.head);
    try testing.expect(std.mem.startsWith(u8, fresh, "__Host-dogpark_human="));
    try testing.expect(humanOf(fresh) != humanOf(first));
}
