//! `rosegold dap`: a Debug Adapter Protocol server over stdio. It drives the
//! tree-walking interpreter through its per-statement debug hook
//! (`interpreter.runProgramDebug`): line breakpoints, step over/into/out and
//! continue, a call-stack backtrace, and each frame's locals.
//!
//! The model is cooperative and single-threaded: the interpreter runs until the
//! hook decides to pause (a breakpoint or a completed step), at which point the
//! adapter emits a `stopped` event and services inspection/step requests inline
//! until the client resumes — exactly what a DAP client sends while stopped.

const std = @import("std");
const Io = std.Io;
const parser = @import("parser.zig");
const interpreter = @import("interpreter.zig");

pub fn run(gpa: std.mem.Allocator, io: Io, out: *Io.Writer) !u8 {
    var in_buf: [64 * 1024]u8 = undefined;
    var reader: Io.File.Reader = .init(.stdin(), io, &in_buf);
    var dap = Dap{ .gpa = gpa, .io = io, .out = out, .in = &reader.interface };
    try dap.serve();
    return 0;
}

const RunMode = enum { cont, step_in, step_over, step_out };

const Dap = struct {
    gpa: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    in: *Io.Reader,
    out_seq: i64 = 1,

    program: ?[]const u8 = null,
    stop_on_entry: bool = false,
    launched: bool = false,
    config_done: bool = false,
    started: bool = false,
    breakpoints: std.AutoHashMapUnmanaged(u32, void) = .{},

    // Live stepping state (read/written by the interpreter hook).
    mode: RunMode = .cont,
    step_depth: usize = 0,
    resume_requested: bool = false,
    terminated: bool = false,
    ip: ?*interpreter.Interpreter = null,

    // --- top-level dispatch ---------------------------------------------------

    fn serve(self: *Dap) !void {
        while (true) {
            const body = (try self.readMessage()) orelse break;
            defer self.gpa.free(body);
            var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, body, .{}) catch continue;
            defer parsed.deinit();
            const msg = parsed.value;
            if (!std.mem.eql(u8, strField(msg, "type") orelse "", "request")) continue;
            const seq = intField(msg, "seq") orelse 0;
            const command = strField(msg, "command") orelse continue;
            const args = objGet(msg, "arguments");

            if (try self.handleRequest(seq, command, args)) return; // disconnect
            // Once launched and configured, run the program (blocks; the hook
            // services further requests while paused). Then wait for disconnect.
            if (self.launched and self.config_done and !self.started) {
                self.started = true;
                try self.runProgram();
            }
        }
    }

    /// Handle a request. Returns true when the session should end (disconnect).
    fn handleRequest(self: *Dap, seq: i64, command: []const u8, args: ?std.json.Value) !bool {
        if (std.mem.eql(u8, command, "initialize")) {
            try self.respond(seq, command, .{ .supportsConfigurationDoneRequest = true });
            try self.event("initialized", .{});
        } else if (std.mem.eql(u8, command, "launch")) {
            if (args) |a| {
                if (strField(a, "program")) |p| self.program = try self.gpa.dupe(u8, p);
                self.stop_on_entry = boolField(a, "stopOnEntry") orelse false;
            }
            self.launched = true;
            try self.respond(seq, command, .{});
        } else if (std.mem.eql(u8, command, "setBreakpoints")) {
            try self.onSetBreakpoints(seq, command, args);
        } else if (std.mem.eql(u8, command, "setExceptionBreakpoints")) {
            try self.respond(seq, command, .{});
        } else if (std.mem.eql(u8, command, "configurationDone")) {
            self.config_done = true;
            try self.respond(seq, command, .{});
        } else if (std.mem.eql(u8, command, "threads")) {
            try self.respond(seq, command, .{ .threads = &[_]Thread{.{ .id = 1, .name = "main" }} });
        } else if (std.mem.eql(u8, command, "disconnect")) {
            try self.respond(seq, command, .{});
            return true;
        } else {
            // Anything else outside a pause (e.g. before the program runs) gets
            // an empty success so the client never blocks.
            try self.respond(seq, command, .{});
        }
        return false;
    }

    fn onSetBreakpoints(self: *Dap, seq: i64, command: []const u8, args: ?std.json.Value) !void {
        self.breakpoints.clearRetainingCapacity();
        var verified: std.ArrayList(Breakpoint) = .empty;
        defer verified.deinit(self.gpa);
        if (args) |a| {
            if (objGet(a, "breakpoints")) |bps| {
                if (bps == .array) {
                    for (bps.array.items) |bp| {
                        const line: u32 = @intCast(intField(bp, "line") orelse continue);
                        try self.breakpoints.put(self.gpa, line, {});
                        try verified.append(self.gpa, .{ .verified = true, .line = line });
                    }
                }
            }
        }
        try self.respond(seq, command, .{ .breakpoints = verified.items });
    }

    // --- running + the pause loop ---------------------------------------------

    fn runProgram(self: *Dap) !void {
        const path = self.program orelse {
            try self.event("terminated", .{});
            return;
        };
        const src = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(16 << 20)) catch {
            try self.outputEvent("could not read program\n");
            try self.event("terminated", .{});
            return;
        };
        var tree = parser.parse(self.gpa, src) catch {
            try self.outputEvent("out of memory\n");
            try self.event("terminated", .{});
            return;
        };
        defer tree.deinit();
        if (tree.diagnostics.len > 0) {
            try self.outputEvent("the program has syntax errors; cannot debug\n");
            try self.event("terminated", .{});
            return;
        }

        self.mode = if (self.stop_on_entry) .step_in else .cont;
        const modules = [_]interpreter.ProgramModule{.{ .module = tree.module, .imports = &.{} }};
        var result = interpreter.runProgramDebug(self.gpa, &modules, self, hook) catch {
            try self.outputEvent("debug session error\n");
            try self.event("terminated", .{});
            return;
        };
        defer result.deinit();

        if (!self.terminated) {
            try self.outputEvent(result.output);
            if (result.runtime_error) |re| {
                var buf: [256]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "runtime error: {s}\n", .{re.message}) catch "runtime error\n";
                try self.outputEvent(line);
            }
        }
        try self.event("terminated", .{});
    }

    /// The interpreter's per-statement hook (see `interpreter.StepFn`).
    fn hook(ctx: *anyopaque, ip: *interpreter.Interpreter, line: u32, col: u32) interpreter.Error!void {
        _ = col;
        const self: *Dap = @ptrCast(@alignCast(ctx));
        const depth = interpreter.debugFrameCount(ip);
        const at_breakpoint = self.breakpoints.contains(line);
        const stepped = switch (self.mode) {
            .cont => false,
            .step_in => true,
            .step_over => depth <= self.step_depth,
            .step_out => depth < self.step_depth,
        };
        if (!at_breakpoint and !stepped) return;

        self.ip = ip;
        self.event("stopped", .{
            .reason = if (at_breakpoint) "breakpoint" else "step",
            .threadId = @as(i64, 1),
            .allThreadsStopped = true,
        }) catch return error.Terminate;
        // Service requests until the client resumes (or disconnects).
        self.resume_requested = false;
        while (!self.resume_requested) {
            const body = (self.readMessage() catch return error.Terminate) orelse {
                self.terminated = true;
                return error.Terminate;
            };
            defer self.gpa.free(body);
            var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, body, .{}) catch continue;
            defer parsed.deinit();
            const msg = parsed.value;
            if (!std.mem.eql(u8, strField(msg, "type") orelse "", "request")) continue;
            const seq = intField(msg, "seq") orelse 0;
            const command = strField(msg, "command") orelse continue;
            self.handlePaused(ip, seq, command, objGet(msg, "arguments")) catch return error.Terminate;
        }
        if (self.terminated) return error.Terminate;
    }

    fn handlePaused(self: *Dap, ip: *interpreter.Interpreter, seq: i64, command: []const u8, args: ?std.json.Value) !void {
        if (std.mem.eql(u8, command, "continue")) {
            self.mode = .cont;
            try self.respond(seq, command, .{ .allThreadsContinued = true });
            self.resume_requested = true;
        } else if (std.mem.eql(u8, command, "next")) {
            self.mode = .step_over;
            self.step_depth = interpreter.debugFrameCount(ip);
            try self.respond(seq, command, .{});
            self.resume_requested = true;
        } else if (std.mem.eql(u8, command, "stepIn")) {
            self.mode = .step_in;
            try self.respond(seq, command, .{});
            self.resume_requested = true;
        } else if (std.mem.eql(u8, command, "stepOut")) {
            self.mode = .step_out;
            self.step_depth = interpreter.debugFrameCount(ip);
            try self.respond(seq, command, .{});
            self.resume_requested = true;
        } else if (std.mem.eql(u8, command, "stackTrace")) {
            try self.onStackTrace(ip, seq, command);
        } else if (std.mem.eql(u8, command, "scopes")) {
            try self.onScopes(seq, command, args);
        } else if (std.mem.eql(u8, command, "variables")) {
            try self.onVariables(ip, seq, command, args);
        } else if (std.mem.eql(u8, command, "threads")) {
            try self.respond(seq, command, .{ .threads = &[_]Thread{.{ .id = 1, .name = "main" }} });
        } else if (std.mem.eql(u8, command, "disconnect")) {
            try self.respond(seq, command, .{});
            self.terminated = true;
            self.resume_requested = true;
        } else {
            try self.respond(seq, command, .{});
        }
    }

    fn onStackTrace(self: *Dap, ip: *interpreter.Interpreter, seq: i64, command: []const u8) !void {
        const n = interpreter.debugFrameCount(ip);
        var frames: std.ArrayList(StackFrame) = .empty;
        defer frames.deinit(self.gpa);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const f = interpreter.debugFrameAt(ip, i);
            try frames.append(self.gpa, .{
                .id = @intCast(i),
                .name = f.name,
                .line = f.line,
                .column = 1,
                .source = .{ .name = std.fs.path.basename(self.program orelse ""), .path = self.program orelse "" },
            });
        }
        try self.respond(seq, command, .{ .stackFrames = frames.items, .totalFrames = @as(i64, @intCast(n)) });
    }

    fn onScopes(self: *Dap, seq: i64, command: []const u8, args: ?std.json.Value) !void {
        const frame_id: i64 = if (args) |a| (intField(a, "frameId") orelse 0) else 0;
        // variablesReference encodes the frame (id + 1, so it's never 0).
        const scopes = [_]Scope{.{ .name = "Locals", .variablesReference = frame_id + 1, .expensive = false }};
        try self.respond(seq, command, .{ .scopes = &scopes });
    }

    fn onVariables(self: *Dap, ip: *interpreter.Interpreter, seq: i64, command: []const u8, args: ?std.json.Value) !void {
        const ref: i64 = if (args) |a| (intField(a, "variablesReference") orelse 0) else 0;
        var vars: std.ArrayList(Variable) = .empty;
        defer vars.deinit(self.gpa);
        if (ref >= 1) {
            const frame: usize = @intCast(ref - 1);
            if (frame < interpreter.debugFrameCount(ip)) {
                const locals = try interpreter.debugLocals(ip, frame);
                for (locals) |v| try vars.append(self.gpa, .{ .name = v.name, .value = v.value, .variablesReference = 0 });
            }
        }
        try self.respond(seq, command, .{ .variables = vars.items });
    }

    // --- transport ------------------------------------------------------------

    fn readMessage(self: *Dap) !?[]u8 {
        var content_length: ?usize = null;
        while (true) {
            const maybe = self.in.takeDelimiter('\n') catch return null;
            const line = maybe orelse return null;
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (trimmed.len == 0) break;
            const prefix = "Content-Length:";
            if (std.mem.startsWith(u8, trimmed, prefix)) {
                const v = std.mem.trim(u8, trimmed[prefix.len..], " \t");
                content_length = std.fmt.parseInt(usize, v, 10) catch null;
            }
        }
        const n = content_length orelse return error.BadHeader;
        const body = try self.gpa.alloc(u8, n);
        errdefer self.gpa.free(body);
        try self.in.readSliceAll(body);
        return body;
    }

    fn send(self: *Dap, payload: anytype) !void {
        const body = try std.json.Stringify.valueAlloc(self.gpa, payload, .{});
        defer self.gpa.free(body);
        try self.out.print("Content-Length: {d}\r\n\r\n", .{body.len});
        try self.out.writeAll(body);
        try self.out.flush();
    }

    fn respond(self: *Dap, request_seq: i64, command: []const u8, body: anytype) !void {
        try self.send(.{ .seq = self.nextSeq(), .type = "response", .request_seq = request_seq, .success = true, .command = command, .body = body });
    }

    fn event(self: *Dap, name: []const u8, body: anytype) !void {
        try self.send(.{ .seq = self.nextSeq(), .type = "event", .event = name, .body = body });
    }

    fn outputEvent(self: *Dap, text: []const u8) !void {
        if (text.len == 0) return;
        try self.event("output", .{ .category = "stdout", .output = text });
    }

    fn nextSeq(self: *Dap) i64 {
        const s = self.out_seq;
        self.out_seq += 1;
        return s;
    }
};

// --- wire types (serialized to JSON) -----------------------------------------

const Thread = struct { id: i64, name: []const u8 };
const Breakpoint = struct { verified: bool, line: u32 };
const Source = struct { name: []const u8, path: []const u8 };
const StackFrame = struct { id: i64, name: []const u8, line: u32, column: u32, source: Source };
const Scope = struct { name: []const u8, variablesReference: i64, expensive: bool };
const Variable = struct { name: []const u8, value: []const u8, variablesReference: i64 };

// --- JSON helpers ------------------------------------------------------------

fn objGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn strField(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = objGet(v, key) orelse return null;
    return if (f == .string) f.string else null;
}

fn intField(v: std.json.Value, key: []const u8) ?i64 {
    const f = objGet(v, key) orelse return null;
    return switch (f) {
        .integer => f.integer,
        .float => @intFromFloat(f.float),
        else => null,
    };
}

fn boolField(v: std.json.Value, key: []const u8) ?bool {
    const f = objGet(v, key) orelse return null;
    return if (f == .bool) f.bool else null;
}
