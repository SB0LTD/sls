//! Layer 2 — LSP request dispatch and server lifecycle.
//!
//! Owns the server state (document store + lifecycle flags) and turns a parsed
//! JSON-RPC message into a framed response body. The transport (reading stdin,
//! writing stdout) lives in main.sig; this module is pure: given a message it
//! produces bytes into a caller-provided buffer. That keeps every LSP behaviour
//! unit-testable without any I/O and without an allocator.

const std = @import("std");
const json = @import("json");
const message = @import("message");
const jwrite = @import("jwrite");
const document = @import("document");
const position = @import("position");
const symbols = @import("symbols");

pub const SERVER_NAME = "sls";
pub const SERVER_VERSION = "0.0.2";

/// The outcome of handling one message.
pub const Outcome = enum {
    /// A response body was written to the output buffer; frame and send it.
    respond,
    /// Handled, but no response is due (notification).
    none,
    /// The client requested exit; the transport loop should terminate.
    exit,
};

pub const Result = struct {
    outcome: Outcome,
    /// Response JSON body (valid when outcome == .respond).
    body: []const u8 = "",
};

pub const Server = struct {
    store: document.Store = .{},
    /// Scratch for decoding JSON string escapes out of inbound document text
    /// before it is copied into the store. Sized to match a document slot.
    decode_buf: [document.MAX_TEXT]u8 = undefined,
    initialized: bool = false,
    shutdown_requested: bool = false,

    /// Handle one parsed message, writing any response JSON into `out`.
    pub fn handle(self: *Server, msg: message.Message, out: []u8) Result {
        const m = msg.method;

        if (eql(m, "initialize")) return self.respondInitialize(msg, out);
        if (eql(m, "initialized")) return .{ .outcome = .none };
        if (eql(m, "shutdown")) return self.respondShutdown(msg, out);
        if (eql(m, "exit")) return .{ .outcome = .exit };

        if (eql(m, "textDocument/didOpen")) return self.onDidOpen(msg);
        if (eql(m, "textDocument/didChange")) return self.onDidChange(msg);
        if (eql(m, "textDocument/didClose")) return self.onDidClose(msg);
        if (eql(m, "textDocument/documentSymbol")) return self.respondDocumentSymbol(msg, out);

        // Unknown request → MethodNotFound error; unknown notification → ignore.
        if (msg.id_present) return self.respondError(msg.id, -32601, "method not found", out);
        return .{ .outcome = .none };
    }

    // ── Lifecycle ──────────────────────────────────────────────────────────

    fn respondInitialize(self: *Server, msg: message.Message, out: []u8) Result {
        self.initialized = true;
        var w = jwrite.Writer.init(out);
        writeInitialize(&w, msg.id) catch return errorResult(msg.id, out);
        return .{ .outcome = .respond, .body = w.bytes() };
    }

    fn respondShutdown(self: *Server, msg: message.Message, out: []u8) Result {
        self.shutdown_requested = true;
        var w = jwrite.Writer.init(out);
        writeResultNull(&w, msg.id) catch return errorResult(msg.id, out);
        return .{ .outcome = .respond, .body = w.bytes() };
    }

    // ── Document synchronization ─────────────────────────────────────────────

    fn onDidOpen(self: *Server, msg: message.Message) Result {
        // params.textDocument.{uri,text,version}
        const uri = json.getString(msg.body, "uri\"") orelse return .{ .outcome = .none };
        const raw = extractText(msg.body) orelse "";
        const text = unescapeJson(raw, &self.decode_buf);
        const version = json.getInt(msg.body, "version\"") orelse 0;
        _ = self.store.open(uri, text, version) catch {};
        return .{ .outcome = .none };
    }

    fn onDidChange(self: *Server, msg: message.Message) Result {
        const uri = json.getString(msg.body, "uri\"") orelse return .{ .outcome = .none };
        const version = json.getInt(msg.body, "version\"") orelse 0;
        // Full-sync: the last "text" field in contentChanges is the new content.
        const raw = extractText(msg.body) orelse return .{ .outcome = .none };
        const text = unescapeJson(raw, &self.decode_buf);
        _ = self.store.replace(uri, text, version) catch {};
        return .{ .outcome = .none };
    }

    fn onDidClose(self: *Server, msg: message.Message) Result {
        const uri = json.getString(msg.body, "uri\"") orelse return .{ .outcome = .none };
        _ = self.store.close(uri);
        return .{ .outcome = .none };
    }

    // ── documentSymbol ──────────────────────────────────────────────────────

    fn respondDocumentSymbol(self: *Server, msg: message.Message, out: []u8) Result {
        const uri = json.getString(msg.body, "uri\"") orelse
            return self.respondEmptyArray(msg.id, out);
        const doc = self.store.get(uri) orelse
            return self.respondEmptyArray(msg.id, out);

        var scan_result: symbols.Scan = .{};
        symbols.scan(doc.text(), &scan_result);

        var w = jwrite.Writer.init(out);
        writeDocumentSymbols(&w, msg.id, doc.text(), scan_result.slice()) catch
            return errorResult(msg.id, out);
        return .{ .outcome = .respond, .body = w.bytes() };
    }

    fn respondEmptyArray(self: *Server, id: i64, out: []u8) Result {
        _ = self;
        var w = jwrite.Writer.init(out);
        writeEmptyArrayResult(&w, id) catch return errorResult(id, out);
        return .{ .outcome = .respond, .body = w.bytes() };
    }

    fn respondError(self: *Server, id: i64, code: i64, msg_text: []const u8, out: []u8) Result {
        _ = self;
        var w = jwrite.Writer.init(out);
        writeError(&w, id, code, msg_text) catch return errorResult(id, out);
        return .{ .outcome = .respond, .body = w.bytes() };
    }
};

// ── Response body writers (free functions, fully testable) ──────────────────

fn writeResponseHead(w: *jwrite.Writer, id: i64) !void {
    try w.beginObject();
    try w.key("jsonrpc");
    try w.string("2.0");
    try w.comma();
    try w.key("id");
    try w.int(id);
    try w.comma();
}

pub fn writeInitialize(w: *jwrite.Writer, id: i64) !void {
    try writeResponseHead(w, id);
    try w.key("result");
    try w.beginObject();
    // capabilities
    try w.key("capabilities");
    try w.beginObject();
    // textDocumentSync: 1 = full
    try w.key("textDocumentSync");
    try w.int(1);
    try w.comma();
    try w.key("documentSymbolProvider");
    try w.boolean(true);
    try w.endObject();
    try w.comma();
    // serverInfo
    try w.key("serverInfo");
    try w.beginObject();
    try w.key("name");
    try w.string(SERVER_NAME);
    try w.comma();
    try w.key("version");
    try w.string(SERVER_VERSION);
    try w.endObject();
    try w.endObject(); // result
    try w.endObject(); // envelope
}

pub fn writeResultNull(w: *jwrite.Writer, id: i64) !void {
    try writeResponseHead(w, id);
    try w.key("result");
    try w.nullValue();
    try w.endObject();
}

pub fn writeEmptyArrayResult(w: *jwrite.Writer, id: i64) !void {
    try writeResponseHead(w, id);
    try w.key("result");
    try w.beginArray();
    try w.endArray();
    try w.endObject();
}

pub fn writeError(w: *jwrite.Writer, id: i64, code: i64, msg_text: []const u8) !void {
    try writeResponseHead(w, id);
    try w.key("error");
    try w.beginObject();
    try w.key("code");
    try w.int(code);
    try w.comma();
    try w.key("message");
    try w.string(msg_text);
    try w.endObject();
    try w.endObject();
}

fn writeRange(w: *jwrite.Writer, text: []const u8, start_off: usize, end_off: usize) !void {
    const start = position.positionAt(text, start_off);
    const end = position.positionAt(text, end_off);
    try w.key("range");
    try writePositionRange(w, start, end);
    try w.comma();
    try w.key("selectionRange");
    try writePositionRange(w, start, end);
}

fn writePositionRange(w: *jwrite.Writer, start: position.Position, end: position.Position) !void {
    try w.beginObject();
    try w.key("start");
    try writePosition(w, start);
    try w.comma();
    try w.key("end");
    try writePosition(w, end);
    try w.endObject();
}

fn writePosition(w: *jwrite.Writer, p: position.Position) !void {
    try w.beginObject();
    try w.key("line");
    try w.int(@intCast(p.line));
    try w.comma();
    try w.key("character");
    try w.int(@intCast(p.character));
    try w.endObject();
}

/// Emit a flat DocumentSymbol[] result. (Flat is a valid LSP response; nesting
/// is a later refinement.)
pub fn writeDocumentSymbols(w: *jwrite.Writer, id: i64, text: []const u8, syms: []const symbols.Symbol) !void {
    try writeResponseHead(w, id);
    try w.key("result");
    try w.beginArray();
    for (syms, 0..) |sym, idx| {
        if (idx != 0) try w.comma();
        try w.beginObject();
        try w.key("name");
        try w.string(sym.name);
        try w.comma();
        try w.key("kind");
        try w.int(@intCast(@intFromEnum(sym.kind)));
        try w.comma();
        try writeRange(w, text, sym.name_offset, sym.name_offset + sym.name.len);
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();
}

// ── helpers ─────────────────────────────────────────────────────────────────

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Emergency fallback used only if response writing overflows the buffer.
/// Emits a compact parse-error to a fresh writer; if even that overflows we
/// return an empty body (the transport will simply not send).
fn errorResult(id: i64, out: []u8) Result {
    var w = jwrite.Writer.init(out);
    writeError(&w, id, -32603, "internal error") catch return .{ .outcome = .none };
    return .{ .outcome = .respond, .body = w.bytes() };
}

/// Extract the value of the (last) "text" field. For didChange the meaningful
/// text is inside contentChanges; scanning for the last occurrence handles both
/// didOpen (one text) and full-sync didChange (one text in the change entry).
fn extractText(body: []const u8) ?[]const u8 {
    // Find the last `"text"` key and read the quoted string that follows it.
    // `findKey("\"text\"")` returns the index just past the closing quote of the
    // key, i.e. sitting on the `:`; `readStringAfter` then skips to the value.
    var result: ?[]const u8 = null;
    var search_from: usize = 0;
    while (search_from < body.len) {
        const rel = json.findKey(body[search_from..], "\"text\"") orelse break;
        const after_key = search_from + rel; // points at ':'
        if (readStringAfter(body, after_key)) |v| {
            result = v;
        }
        search_from = after_key + 1;
    }
    return result;
}

/// Decode JSON string escape sequences in `raw` into `out`, returning the
/// decoded slice. Handles the standard two-char escapes and `\uXXXX` (BMP
/// code points, encoded to UTF-8). Output is bounded by `out.len`; any excess
/// is dropped rather than overflowing.
fn unescapeJson(raw: []const u8, out: []u8) []const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < raw.len and w < out.len) {
        const c = raw[i];
        if (c != '\\' or i + 1 >= raw.len) {
            out[w] = c;
            w += 1;
            i += 1;
            continue;
        }
        const e = raw[i + 1];
        switch (e) {
            '"' => {
                out[w] = '"';
                w += 1;
                i += 2;
            },
            '\\' => {
                out[w] = '\\';
                w += 1;
                i += 2;
            },
            '/' => {
                out[w] = '/';
                w += 1;
                i += 2;
            },
            'n' => {
                out[w] = '\n';
                w += 1;
                i += 2;
            },
            'r' => {
                out[w] = '\r';
                w += 1;
                i += 2;
            },
            't' => {
                out[w] = '\t';
                w += 1;
                i += 2;
            },
            'b' => {
                out[w] = 8;
                w += 1;
                i += 2;
            },
            'f' => {
                out[w] = 12;
                w += 1;
                i += 2;
            },
            'u' => {
                if (i + 6 <= raw.len) {
                    const cp = parseHex4(raw[i + 2 .. i + 6]);
                    w += encodeUtf8(cp, out[w..]);
                    i += 6;
                } else {
                    out[w] = e;
                    w += 1;
                    i += 2;
                }
            },
            else => {
                out[w] = e;
                w += 1;
                i += 2;
            },
        }
    }
    return out[0..w];
}

fn parseHex4(s: []const u8) u21 {
    var v: u21 = 0;
    for (s) |c| {
        const d: u21 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => 0,
        };
        v = v * 16 + d;
    }
    return v;
}

/// Encode a BMP/astral code point to UTF-8 in `out`, returning bytes written.
/// Returns 0 (writing nothing) if `out` cannot hold the sequence.
fn encodeUtf8(cp: u21, out: []u8) usize {
    if (cp < 0x80) {
        if (out.len < 1) return 0;
        out[0] = @intCast(cp);
        return 1;
    } else if (cp < 0x800) {
        if (out.len < 2) return 0;
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp < 0x10000) {
        if (out.len < 3) return 0;
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    } else {
        if (out.len < 4) return 0;
        out[0] = @intCast(0xF0 | (cp >> 18));
        out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[3] = @intCast(0x80 | (cp & 0x3F));
        return 4;
    }
}

/// Given an index sitting at (or just before) the `:` following a JSON key,
/// skip whitespace/colon and return the following quoted string's contents.
fn readStringAfter(body: []const u8, from: usize) ?[]const u8 {
    var i = from;
    while (i < body.len and (body[i] == ':' or body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < body.len and body[i] != '"') : (i += 1) {
        if (body[i] == '\\' and i + 1 < body.len) i += 1; // skip escaped char
    }
    if (i > body.len) return null;
    return body[start..i];
}

// ── tests ─────────────────────────────────────────────────────────────────

// The Server embeds the (large, fixed-capacity) document store plus a decode
// scratch buffer. Tests use a static instance and reset it per test, rather
// than a stack local, so they never depend on the test thread's stack size.
var test_srv: Server = .{};

test "initialize advertises capabilities and serverInfo" {
    const srv = &test_srv;
    srv.* = .{};
    const msg = message.parse("{\"id\":1,\"method\":\"initialize\"}");
    var out: [4096]u8 = undefined;
    const res = srv.handle(msg, &out);
    try std.testing.expectEqual(Outcome.respond, res.outcome);
    try std.testing.expect(srv.initialized);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"documentSymbolProvider\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"name\":\"sls\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"id\":1") != null);
}

test "shutdown then exit" {
    const srv = &test_srv;
    srv.* = .{};
    var out: [1024]u8 = undefined;
    const sd = srv.handle(message.parse("{\"id\":2,\"method\":\"shutdown\"}"), &out);
    try std.testing.expectEqual(Outcome.respond, sd.outcome);
    try std.testing.expect(srv.shutdown_requested);
    try std.testing.expect(std.mem.indexOf(u8, sd.body, "\"result\":null") != null);

    const ex = srv.handle(message.parse("{\"method\":\"exit\"}"), &out);
    try std.testing.expectEqual(Outcome.exit, ex.outcome);
}

test "unknown request yields MethodNotFound, unknown notification ignored" {
    const srv = &test_srv;
    srv.* = .{};
    var out: [1024]u8 = undefined;
    const req = srv.handle(message.parse("{\"id\":9,\"method\":\"textDocument/nope\"}"), &out);
    try std.testing.expectEqual(Outcome.respond, req.outcome);
    try std.testing.expect(std.mem.indexOf(u8, req.body, "-32601") != null);

    const note = srv.handle(message.parse("{\"method\":\"$/whatever\"}"), &out);
    try std.testing.expectEqual(Outcome.none, note.outcome);
}

test "didOpen stores document, documentSymbol returns outline" {
    const srv = &test_srv;
    srv.* = .{};
    var out: [8192]u8 = undefined;

    const open_body =
        "{\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{" ++
        "\"uri\":\"file:///m.sig\",\"version\":1," ++
        "\"text\":\"pub fn main() void {}\"}}}";
    const open_res = srv.handle(message.parse(open_body), &out);
    try std.testing.expectEqual(Outcome.none, open_res.outcome);
    try std.testing.expectEqual(@as(usize, 1), srv.store.count());

    const ds_body =
        "{\"id\":5,\"method\":\"textDocument/documentSymbol\",\"params\":{" ++
        "\"textDocument\":{\"uri\":\"file:///m.sig\"}}}";
    const ds_res = srv.handle(message.parse(ds_body), &out);
    try std.testing.expectEqual(Outcome.respond, ds_res.outcome);
    try std.testing.expect(std.mem.indexOf(u8, ds_res.body, "\"name\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ds_res.body, "\"kind\":12") != null);
}

test "didChange full sync updates text" {
    const srv = &test_srv;
    srv.* = .{};
    var out: [8192]u8 = undefined;
    _ = srv.handle(message.parse(
        "{\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{" ++
            "\"uri\":\"file:///c.sig\",\"version\":1,\"text\":\"const a = 1;\"}}}",
    ), &out);

    _ = srv.handle(message.parse(
        "{\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{" ++
            "\"uri\":\"file:///c.sig\",\"version\":2},\"contentChanges\":[{" ++
            "\"text\":\"const b = 2;\"}]}}",
    ), &out);

    const doc = srv.store.get("file:///c.sig").?;
    try std.testing.expectEqualStrings("const b = 2;", doc.text());
    try std.testing.expectEqual(@as(i64, 2), doc.version);
}

test "unescapeJson decodes standard escapes and \\uXXXX" {
    var buf: [64]u8 = undefined;
    const out = unescapeJson("a\\\"b\\nc\\u0041", &buf);
    try std.testing.expectEqualStrings("a\"b\ncA", out);
}

test "didOpen with escaped source yields all symbols" {
    const srv = &test_srv;
    srv.* = .{};
    var out: [8192]u8 = undefined;
    // Text as it arrives on the wire: escaped quotes and \n newlines.
    const open_body =
        "{\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{" ++
        "\"uri\":\"file:///d.sig\",\"version\":1," ++
        "\"text\":\"const std = @import(\\\"std\\\");\\npub fn main() void {}\\npub const Point = struct { x: i32 };\"}}}";
    _ = srv.handle(message.parse(open_body), &out);

    const doc = srv.store.get("file:///d.sig").?;
    // Stored text has real newlines and quotes now.
    try std.testing.expect(std.mem.indexOf(u8, doc.text(), "@import(\"std\")") != null);

    const ds = srv.handle(message.parse(
        "{\"id\":7,\"method\":\"textDocument/documentSymbol\",\"params\":{" ++
            "\"textDocument\":{\"uri\":\"file:///d.sig\"}}}",
    ), &out);
    try std.testing.expect(std.mem.indexOf(u8, ds.body, "\"name\":\"std\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ds.body, "\"name\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ds.body, "\"name\":\"Point\"") != null);
}

test "documentSymbol on unknown document returns empty array" {
    const srv = &test_srv;
    srv.* = .{};
    var out: [1024]u8 = undefined;
    const res = srv.handle(message.parse(
        "{\"id\":3,\"method\":\"textDocument/documentSymbol\",\"params\":{" ++
            "\"textDocument\":{\"uri\":\"file:///missing.sig\"}}}",
    ), &out);
    try std.testing.expectEqual(Outcome.respond, res.outcome);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"result\":[]") != null);
}
