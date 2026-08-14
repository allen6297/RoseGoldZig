//! RoseGold parser.
//! Targets Zig 0.16.0.
//!
//! A recursive-descent parser over the token stream produced by `lexer.zig`.
//! It covers the subset the language currently exercises:
//!   * top-level declarations: `import` (dotted paths), `const`/`var`, `enum`,
//!     `func` (with optional parameter types), `class`, `struct`, `signal`
//!   * statements: `return`, `if`/`elif`/`else`, `while`, `for`, `break`,
//!     `continue`, `pass`, local `var`/`const`, assignments, and expression
//!     statements
//!   * expressions: literals (incl. `nil`), identifiers, member access, calls,
//!     indexing, array/map literals, unary `-`/`not`, arithmetic/comparison/
//!     logical operators with precedence, and `match` (patterns: literals, `_`,
//!     a binding name, or an enum case `Enum.CASE`)
//!   * types may be optional: `?T` holds a value of type `T` or `nil`
//!
//! Layout: colon-blocks are delimited by INDENT/DEDENT, brace-blocks by
//! `{`/`}`, and statements are separated by NEWLINE. Errors are reported as
//! diagnostics and recovered from with panic-mode synchronization so one bad
//! construct does not abort the whole parse.
//!
//! The returned `Tree` owns an arena holding the AST and diagnostics. All text
//! slices point into the original `src`, which must outlive the tree.

const std = @import("std");
const lexer = @import("lexer.zig");

const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const Span = lexer.Span;
const Diagnostic = lexer.Diagnostic;

// --- AST ---------------------------------------------------------------------

pub const Visibility = enum { default, public, private };

pub const TypeRef = struct {
    name: []const u8,
    span: Span,
    /// A leading `?` makes the type optional (may hold `nil`).
    optional: bool = false,
    /// Type arguments for generic builtins: `list<T>` → `{T}`, `map<K, V>` →
    /// `{K, V}`. Empty for a plain type.
    args: []const TypeRef = &.{},
    /// A module qualifier for an imported type: `mod.T` → `module = "mod"`,
    /// `name = "T"`. Null for an unqualified type.
    module: ?[]const u8 = null,
    /// A tuple type `(A, B, ...)`: `is_tuple` is set and `args` holds the element
    /// types (`name` is the placeholder `"tuple"`).
    is_tuple: bool = false,
};

pub const Param = struct {
    name: []const u8,
    type: ?TypeRef,
    /// An optional default value (`p = expr`); when present the argument may be
    /// omitted at the call site. Defaults must be trailing.
    default: ?*const Expr = null,
    span: Span,
};

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    logical_and,
    logical_or,
};

pub const UnaryOp = enum { neg, not, bit_not };

pub const Expr = union(enum) {
    int_literal: Literal,
    float_literal: Literal,
    string_literal: Literal,
    bool_literal: Bool,
    nil_literal: Span,
    identifier: Ident,
    unary: Unary,
    binary: Binary,
    call: Call,
    index: Index,
    slice: Slice,
    member: MemberAccess,
    array: Array,
    map: Map,
    match: Match,
    lambda: *const Lambda,
    interpolation: *const Interpolation,
    range: Range,
    tuple: Tuple,
    comprehension: *const Comprehension,
    map_comprehension: *const MapComprehension,
    conditional: *const Conditional,

    pub const Literal = struct { text: []const u8, span: Span };
    /// `[output for binding[, value_binding] in iter [if cond]]` — builds a list.
    pub const Comprehension = struct {
        output: *Expr,
        binding: []const u8,
        value_binding: ?[]const u8,
        iter: *Expr,
        cond: ?*Expr,
        span: Span,
    };
    /// `{key: value for binding[, value_binding] in iter [if cond]}` — builds a map.
    pub const MapComprehension = struct {
        key: *Expr,
        value: *Expr,
        binding: []const u8,
        value_binding: ?[]const u8,
        iter: *Expr,
        cond: ?*Expr,
        span: Span,
    };
    /// A fixed, ordered group of values: `(a, b, ...)` (two or more elements).
    pub const Tuple = struct { elements: []const *Expr, span: Span };
    pub const Range = struct { start: *Expr, end: *Expr, span: Span };
    /// `then_val if cond else else_val` — a conditional (ternary) expression.
    pub const Conditional = struct { cond: *Expr, then_val: *Expr, else_val: *Expr, span: Span };
    pub const Bool = struct { value: bool, span: Span };
    pub const Ident = struct { name: []const u8, span: Span };
    pub const Unary = struct { op: UnaryOp, operand: *Expr, span: Span };
    pub const Binary = struct { op: BinaryOp, lhs: *Expr, rhs: *Expr, span: Span };
    /// A call argument: positional (`name == null`) or named (`name: value`).
    pub const Arg = struct { name: ?[]const u8 = null, value: *Expr };
    pub const Call = struct { callee: *Expr, args: []const Arg, span: Span };
    pub const Index = struct { object: *Expr, index: *Expr, span: Span };
    /// `object[start:end]` — a sub-range of a list or string; `start`/`end` are
    /// optional (default 0 / length).
    pub const Slice = struct { object: *Expr, start: ?*Expr, end: ?*Expr, span: Span };
    pub const MemberAccess = struct { object: *Expr, name: []const u8, span: Span };
    pub const Array = struct { elements: []const *Expr, span: Span };
    pub const Map = struct { entries: []const MapEntry, span: Span };
    pub const Match = struct { subject: *Expr, arms: []const MatchArm, span: Span };
    /// An anonymous function `func(params): expr` (single expression, implicitly
    /// returned) or `func(params):` + an indented block.
    pub const Lambda = struct { params: []const Param, body: []const Stmt, span: Span };
    /// A string with `${expr}` holes: alternating literal (raw, still escaped)
    /// and expression parts, in order.
    pub const Interpolation = struct {
        parts: []const Part,
        span: Span,
        pub const Part = union(enum) { literal: []const u8, expr: *Expr };
    };
};

pub const MatchArm = struct {
    pattern: Pattern,
    body: *Expr,
    span: Span,
};

pub const MapEntry = struct {
    key: *Expr,
    value: *Expr,
};

pub const Pattern = union(enum) {
    wildcard: Span,
    int_literal: Expr.Literal,
    float_literal: Expr.Literal,
    string_literal: Expr.Literal,
    bool_literal: Expr.Bool,
    binding: Expr.Ident,
    enum_case: EnumCase,

    pub const EnumCase = struct { enum_name: []const u8, case: []const u8, span: Span };
};

pub const VarDecl = struct {
    visibility: Visibility,
    is_const: bool,
    /// `static` on a class/struct member: the var belongs to the type, not each
    /// instance. Ignored at module level.
    is_static: bool = false,
    name: []const u8,
    type: ?TypeRef,
    value: ?*Expr,
    span: Span,
};

pub const Stmt = union(enum) {
    var_decl: VarDecl,
    destructure: Destructure,
    return_stmt: Return,
    if_stmt: If,
    while_stmt: While,
    for_stmt: For,
    assign: Assign,
    expr_stmt: *Expr,
    pass: Span,
    break_stmt: Span,
    continue_stmt: Span,
    try_catch: TryCatch,
    raise: Raise,

    /// `var a, b, ... = tuple` — binds each name to the corresponding element.
    pub const Destructure = struct { names: []const []const u8, value: *Expr, is_const: bool, span: Span };
    /// `try: ... catch name: ...` — runs the body, and on a raised error runs the
    /// handler with `name` bound to the error value.
    pub const TryCatch = struct { body: []const Stmt, catch_name: []const u8, handler: []const Stmt, span: Span };
    /// `raise expr` — throws `expr`'s value, unwinding to the nearest `catch`.
    pub const Raise = struct { value: *Expr, span: Span };
    pub const Return = struct { value: ?*Expr, span: Span };
    pub const ElseIf = struct { cond: *Expr, body: []const Stmt };
    pub const If = struct {
        cond: *Expr,
        then_body: []const Stmt,
        elifs: []const ElseIf,
        else_body: ?[]const Stmt,
        span: Span,
    };
    pub const While = struct { cond: *Expr, body: []const Stmt, span: Span };
    pub const For = struct {
        binding: []const u8,
        /// A second binding (`for i, x in ...`): the first is the index/key, the
        /// second the value. Null for a single-binding loop.
        value_binding: ?[]const u8,
        iter: *Expr,
        body: []const Stmt,
        span: Span,
    };
    pub const Assign = struct { target: *Expr, value: *Expr, span: Span };
};

pub const EnumMember = struct { name: []const u8, value: ?*Expr, span: Span };

pub const Decl = union(enum) {
    import: Import,
    var_decl: VarDecl,
    func: Func,
    class: Class,
    struct_decl: Struct,
    enum_decl: Enum,
    signal: Signal,

    /// A dotted module path. `name` is the last segment (the bound name); `path`
    /// holds every segment, e.g. `import a.b.c` → path `{a, b, c}`, name `c`.
    pub const Import = struct { path: []const []const u8, name: []const u8, span: Span };
    /// An event declaration: `signal name` or `signal name(params)`.
    pub const Signal = struct {
        visibility: Visibility,
        name: []const u8,
        params: []const Param,
        span: Span,
    };
    pub const Func = struct {
        visibility: Visibility,
        is_static: bool,
        name: []const u8,
        params: []const Param,
        return_type: ?TypeRef,
        body: []const Stmt,
        span: Span,
    };
    pub const Class = struct {
        visibility: Visibility,
        name: []const u8,
        extends: ?TypeRef,
        uses: []const TypeRef,
        members: []const Decl,
        span: Span,
    };
    /// Like a class, but a plain aggregate: no `extends` / `uses`.
    pub const Struct = struct {
        visibility: Visibility,
        name: []const u8,
        members: []const Decl,
        span: Span,
    };
    pub const Enum = struct {
        visibility: Visibility,
        name: []const u8,
        members: []const EnumMember,
        span: Span,
    };
};

pub const Module = struct {
    decls: []const Decl,
};

// --- span helpers ------------------------------------------------------------

fn joinSpan(a: Span, b: Span) Span {
    return .{ .start = a.start, .end = b.end, .line = a.line, .col = a.col };
}

fn spanFrom(a: Token, b: Token) Span {
    return joinSpan(a.span, b.span);
}

pub fn exprSpan(e: Expr) Span {
    return switch (e) {
        .int_literal, .float_literal, .string_literal => |lit| lit.span,
        .bool_literal => |b| b.span,
        .nil_literal => |s| s,
        .identifier => |id| id.span,
        .unary => |u| u.span,
        .binary => |b| b.span,
        .call => |c| c.span,
        .index => |i| i.span,
        .slice => |s| s.span,
        .member => |m| m.span,
        .array => |a| a.span,
        .map => |m| m.span,
        .match => |m| m.span,
        .lambda => |l| l.span,
        .interpolation => |x| x.span,
        .range => |r| r.span,
        .tuple => |t| t.span,
        .comprehension => |c| c.span,
        .map_comprehension => |c| c.span,
        .conditional => |c| c.span,
    };
}

fn patternSpan(p: Pattern) Span {
    return switch (p) {
        .wildcard => |s| s,
        .int_literal, .float_literal, .string_literal => |lit| lit.span,
        .bool_literal => |b| b.span,
        .binding => |id| id.span,
        .enum_case => |ec| ec.span,
    };
}

// --- operator tables ---------------------------------------------------------

// Precedence tiers (higher binds tighter). Bitwise sits between comparison and
// additive, Python-style: `|` < `^` < `&` < shift < `+ -` < `* / %`. Shifts
// (`<<` `>>`) are two adjacent `<`/`>` tokens, handled specially in `parseBinary`
// (tier 5) so nested generics like `list<list<int>>` still close with single `>`.
fn precedence(kind: TokenKind) u8 {
    return switch (kind) {
        .star, .slash, .percent => 7,
        .plus, .minus => 6,
        .amp => 4,
        .caret => 3,
        .pipe => 2,
        .eq, .bang_eq, .lt, .lt_eq, .gt, .gt_eq => 1,
        else => 0,
    };
}

const shift_prec: u8 = 5;

/// The arithmetic op behind a compound-assignment token (`+=` → `add`, …), or
/// null if the token isn't one.
fn compoundOp(kind: TokenKind) ?BinaryOp {
    return switch (kind) {
        .plus_eq => .add,
        .minus_eq => .sub,
        .star_eq => .mul,
        .slash_eq => .div,
        .percent_eq => .mod,
        else => null,
    };
}

fn binaryOp(kind: TokenKind) BinaryOp {
    return switch (kind) {
        .plus => .add,
        .minus => .sub,
        .star => .mul,
        .slash => .div,
        .percent => .mod,
        .eq => .eq,
        .bang_eq => .ne,
        .lt => .lt,
        .lt_eq => .le,
        .gt => .gt,
        .gt_eq => .ge,
        .amp => .bit_and,
        .pipe => .bit_or,
        .caret => .bit_xor,
        else => unreachable,
    };
}

// --- result ------------------------------------------------------------------

pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    module: Module,
    diagnostics: []const Diagnostic,
    /// `##` line comments, in source order, for the formatter.
    comments: []const lexer.Comment,

    pub fn deinit(self: *Tree) void {
        self.arena.deinit();
    }
};

const Error = std.mem.Allocator.Error || error{ParseError};

// --- parser ------------------------------------------------------------------

/// Bound on how deeply expressions/blocks may nest, so pathological input
/// (e.g. thousands of nested parens) is rejected instead of overflowing the
/// recursive-descent stack.
const max_nesting = 300;

const Parser = struct {
    alloc: std.mem.Allocator,
    tokens: []const Token,
    src: []const u8,
    pos: usize = 0,
    diagnostics: *std.ArrayList(Diagnostic),
    /// Current recursion depth (expressions + statement blocks).
    depth: u32 = 0,

    /// Enter a nesting level, failing if it is too deep. Pair with `leave`.
    fn enter(self: *Parser) Error!void {
        self.depth += 1;
        if (self.depth > max_nesting) {
            try self.err("nested too deeply");
            return error.ParseError;
        }
    }

    fn leave(self: *Parser) void {
        self.depth -= 1;
    }

    fn peek(self: *Parser) Token {
        return self.tokens[self.pos];
    }

    fn peekKind(self: *Parser) TokenKind {
        return self.tokens[self.pos].kind;
    }

    fn at(self: *Parser, kind: TokenKind) bool {
        return self.peekKind() == kind;
    }

    fn atEnd(self: *Parser) bool {
        return self.at(.eof);
    }

    fn advance(self: *Parser) Token {
        const t = self.tokens[self.pos];
        if (self.pos + 1 < self.tokens.len) self.pos += 1;
        return t;
    }

    fn prev(self: *Parser) Token {
        return self.tokens[self.pos - 1];
    }

    fn eat(self: *Parser, kind: TokenKind) bool {
        if (self.at(kind)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, kind: TokenKind, message: []const u8) Error!Token {
        if (self.at(kind)) return self.advance();
        try self.err(message);
        return error.ParseError;
    }

    fn err(self: *Parser, message: []const u8) Error!void {
        const t = self.peek();
        try self.diagnostics.append(self.alloc, .{
            .message = message,
            .line = t.span.line,
            .col = t.span.col,
        });
    }

    fn mkExpr(self: *Parser, e: Expr) Error!*Expr {
        const p = try self.alloc.create(Expr);
        p.* = e;
        return p;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.at(.newline)) _ = self.advance();
    }

    /// Panic-mode recovery: skip to the next statement/declaration boundary.
    /// Stops (without consuming) at DEDENT / `}` / EOF so the enclosing block
    /// loop can terminate; otherwise consumes through the next NEWLINE.
    fn synchronize(self: *Parser) void {
        while (!self.atEnd()) {
            switch (self.peekKind()) {
                .newline => {
                    _ = self.advance();
                    return;
                },
                .dedent, .r_brace => return,
                else => _ = self.advance(),
            }
        }
    }

    // --- declarations --------------------------------------------------------

    fn parseModule(self: *Parser) Error!Module {
        var decls: std.ArrayList(Decl) = .empty;
        self.skipNewlines();
        while (!self.atEnd()) {
            const d = self.parseDecl() catch |e| switch (e) {
                error.ParseError => {
                    self.recover();
                    continue;
                },
                else => return e,
            };
            try decls.append(self.alloc, d);
            self.skipNewlines();
        }
        return .{ .decls = try decls.toOwnedSlice(self.alloc) };
    }

    /// After an error, skip to a boundary and guarantee forward progress so the
    /// enclosing loop can never spin.
    fn recover(self: *Parser) void {
        const before = self.pos;
        self.synchronize();
        if (self.pos == before and !self.atEnd()) _ = self.advance();
        self.skipNewlines();
    }

    fn parseVisibility(self: *Parser) Visibility {
        if (self.eat(.kw_pub)) return .public;
        if (self.eat(.kw_private)) return .private;
        return .default;
    }

    fn parseDecl(self: *Parser) Error!Decl {
        const visibility = self.parseVisibility();
        const is_static = self.eat(.kw_static);
        switch (self.peekKind()) {
            .kw_import => return .{ .import = try self.parseImport() },
            .kw_const, .kw_var => return .{ .var_decl = try self.parseVarDecl(visibility, is_static) },
            .kw_func => return .{ .func = try self.parseFunc(visibility, is_static) },
            .kw_class => return .{ .class = try self.parseClass(visibility) },
            .kw_struct => return .{ .struct_decl = try self.parseStruct(visibility) },
            .kw_enum => return .{ .enum_decl = try self.parseEnum(visibility) },
            .kw_signal => return .{ .signal = try self.parseSignal(visibility) },
            else => {
                try self.err("expected a declaration");
                return error.ParseError;
            },
        }
    }

    fn parseImport(self: *Parser) Error!Decl.Import {
        const kw = try self.expect(.kw_import, "expected 'import'");
        var segments: std.ArrayList([]const u8) = .empty;
        const first = try self.expect(.identifier, "expected a module name after 'import'");
        try segments.append(self.alloc, first.text);
        var last = first;
        while (self.eat(.dot)) {
            last = try self.expect(.identifier, "expected a name after '.'");
            try segments.append(self.alloc, last.text);
        }
        const path = try segments.toOwnedSlice(self.alloc);
        return .{ .path = path, .name = path[path.len - 1], .span = spanFrom(kw, last) };
    }

    fn parseType(self: *Parser) Error!TypeRef {
        const optional = self.eat(.question);
        // A tuple type: `(A, B, ...)`.
        if (self.at(.l_paren)) {
            const lp = self.advance();
            var arg_list: std.ArrayList(TypeRef) = .empty;
            try arg_list.append(self.alloc, try self.parseType());
            while (self.eat(.comma)) {
                try arg_list.append(self.alloc, try self.parseType());
            }
            const rp = try self.expect(.r_paren, "expected ')' to close the tuple type");
            return .{ .name = "tuple", .is_tuple = true, .args = try arg_list.toOwnedSlice(self.alloc), .span = joinSpan(lp.span, rp.span), .optional = optional };
        }
        const first = try self.expect(.identifier, "expected a type name");
        // A `mod.T` qualifier names a type exported by an imported module.
        var module: ?[]const u8 = null;
        var name_tok = first;
        if (self.eat(.dot)) {
            module = first.text;
            name_tok = try self.expect(.identifier, "expected a type name after '.'");
        }
        var end = name_tok.span;
        var args: []const TypeRef = &.{};
        // Optional `<T, ...>` type arguments (e.g. `list<int>`, `map<str, int>`).
        if (self.at(.lt)) {
            _ = self.advance(); // '<'
            var arg_list: std.ArrayList(TypeRef) = .empty;
            try arg_list.append(self.alloc, try self.parseType());
            while (self.eat(.comma)) {
                try arg_list.append(self.alloc, try self.parseType());
            }
            const close = try self.expect(.gt, "expected '>' after type arguments");
            end = close.span;
            args = try arg_list.toOwnedSlice(self.alloc);
        }
        return .{ .name = name_tok.text, .module = module, .span = joinSpan(first.span, end), .optional = optional, .args = args };
    }

    fn parseVarDecl(self: *Parser, visibility: Visibility, is_static: bool) Error!VarDecl {
        const kw = self.advance(); // 'const' or 'var'
        const is_const = kw.kind == .kw_const;
        const name = try self.expect(.identifier, "expected a variable name");
        var type_ref: ?TypeRef = null;
        if (self.eat(.colon)) type_ref = try self.parseType();
        var value: ?*Expr = null;
        if (self.eat(.assign)) value = try self.parseExpr();
        return .{
            .visibility = visibility,
            .is_const = is_const,
            .is_static = is_static,
            .name = name.text,
            .type = type_ref,
            .value = value,
            .span = spanFrom(kw, self.prev()),
        };
    }

    /// A `var`/`const` statement: either a single binding (with optional type and
    /// initializer) or a destructuring `var a, b = tuple`.
    fn parseVarOrDestructure(self: *Parser) Error!Stmt {
        const kw = self.advance(); // 'var' or 'const'
        const is_const = kw.kind == .kw_const;
        const first = try self.expect(.identifier, "expected a variable name");
        if (self.at(.comma)) {
            var names: std.ArrayList([]const u8) = .empty;
            try names.append(self.alloc, first.text);
            while (self.eat(.comma)) {
                const n = try self.expect(.identifier, "expected a variable name");
                try names.append(self.alloc, n.text);
            }
            _ = try self.expect(.assign, "expected '=' in a destructuring binding");
            const value = try self.parseExpr();
            return .{ .destructure = .{
                .names = try names.toOwnedSlice(self.alloc),
                .value = value,
                .is_const = is_const,
                .span = spanFrom(kw, self.prev()),
            } };
        }
        var type_ref: ?TypeRef = null;
        if (self.eat(.colon)) type_ref = try self.parseType();
        var value: ?*Expr = null;
        if (self.eat(.assign)) value = try self.parseExpr();
        return .{ .var_decl = .{
            .visibility = .default,
            .is_const = is_const,
            .is_static = false,
            .name = first.text,
            .type = type_ref,
            .value = value,
            .span = spanFrom(kw, self.prev()),
        } };
    }

    /// Parse `( name[: type], ... )`. Parameter types are optional.
    fn parseParamList(self: *Parser) Error![]const Param {
        _ = try self.expect(.l_paren, "expected '('");
        var params: std.ArrayList(Param) = .empty;
        if (!self.at(.r_paren)) {
            var seen_default = false;
            while (true) {
                const pname = try self.expect(.identifier, "expected a parameter name");
                var ptype: ?TypeRef = null;
                if (self.eat(.colon)) ptype = try self.parseType();
                var default: ?*const Expr = null;
                if (self.eat(.assign)) {
                    default = try self.parseExpr();
                    seen_default = true;
                } else if (seen_default) {
                    try self.err("a parameter without a default cannot follow one with a default");
                }
                try params.append(self.alloc, .{
                    .name = pname.text,
                    .type = ptype,
                    .default = default,
                    .span = spanFrom(pname, self.prev()),
                });
                if (!self.eat(.comma)) break;
            }
        }
        _ = try self.expect(.r_paren, "expected ')' after the parameters");
        return params.toOwnedSlice(self.alloc);
    }

    fn parseFunc(self: *Parser, visibility: Visibility, is_static: bool) Error!Decl.Func {
        const kw = try self.expect(.kw_func, "expected 'func'");
        const name = try self.expect(.identifier, "expected a function name");
        const params = try self.parseParamList();
        var return_type: ?TypeRef = null;
        if (self.eat(.arrow)) return_type = try self.parseType();
        const body = try self.parseColonStmtBlock();
        return .{
            .visibility = visibility,
            .is_static = is_static,
            .name = name.text,
            .params = params,
            .return_type = return_type,
            .body = body,
            .span = spanFrom(kw, self.prev()),
        };
    }

    fn parseSignal(self: *Parser, visibility: Visibility) Error!Decl.Signal {
        const kw = try self.expect(.kw_signal, "expected 'signal'");
        const name = try self.expect(.identifier, "expected a signal name");
        const params: []const Param = if (self.at(.l_paren)) try self.parseParamList() else &.{};
        return .{
            .visibility = visibility,
            .name = name.text,
            .params = params,
            .span = spanFrom(kw, self.prev()),
        };
    }

    fn parseClass(self: *Parser, visibility: Visibility) Error!Decl.Class {
        const kw = try self.expect(.kw_class, "expected 'class'");
        const name = try self.expect(.identifier, "expected a class name");
        // `extends`/`uses` targets are types, so an imported base `mod.Base` works.
        var extends: ?TypeRef = null;
        if (self.eat(.kw_extends)) extends = try self.parseType();
        var uses: std.ArrayList(TypeRef) = .empty;
        if (self.eat(.kw_uses)) {
            while (true) {
                try uses.append(self.alloc, try self.parseType());
                if (!self.eat(.comma)) break;
            }
        }
        const members = try self.parseColonDeclBlock();
        return .{
            .visibility = visibility,
            .name = name.text,
            .extends = extends,
            .uses = try uses.toOwnedSlice(self.alloc),
            .members = members,
            .span = spanFrom(kw, self.prev()),
        };
    }

    fn parseStruct(self: *Parser, visibility: Visibility) Error!Decl.Struct {
        const kw = try self.expect(.kw_struct, "expected 'struct'");
        const name = try self.expect(.identifier, "expected a struct name");
        const members = try self.parseColonDeclBlock();
        return .{
            .visibility = visibility,
            .name = name.text,
            .members = members,
            .span = spanFrom(kw, self.prev()),
        };
    }

    fn parseEnum(self: *Parser, visibility: Visibility) Error!Decl.Enum {
        const kw = try self.expect(.kw_enum, "expected 'enum'");
        const name = try self.expect(.identifier, "expected an enum name");
        _ = try self.expect(.l_brace, "expected '{' to open the enum body");
        self.skipNewlines();
        var members: std.ArrayList(EnumMember) = .empty;
        while (!self.at(.r_brace) and !self.atEnd()) {
            const m = try self.expect(.identifier, "expected an enum member name");
            var value: ?*Expr = null;
            if (self.eat(.assign)) value = try self.parseExpr();
            try members.append(self.alloc, .{
                .name = m.text,
                .value = value,
                .span = if (value) |v| joinSpan(m.span, exprSpan(v.*)) else m.span,
            });
            // Members may be separated by a newline, a comma, or both.
            _ = self.eat(.comma);
            self.skipNewlines();
        }
        _ = try self.expect(.r_brace, "expected '}' to close the enum body");
        return .{
            .visibility = visibility,
            .name = name.text,
            .members = try members.toOwnedSlice(self.alloc),
            .span = spanFrom(kw, self.prev()),
        };
    }

    /// If the string literal `text` (including its quotes) contains a `${...}`
    /// hole, split it into an interpolation expression; otherwise return null.
    /// Each hole's expression is lexed and parsed on its own. A `$` may be
    /// escaped as `\$`. String literals inside a hole are not supported (the
    /// lexer ends the outer string at the first quote).
    fn maybeInterpolation(self: *Parser, text: []const u8, span: Span) Error!?*Expr {
        if (text.len < 2) return null;
        const inner = text[1 .. text.len - 1];
        if (std.mem.indexOf(u8, inner, "${") == null) return null;

        var parts: std.ArrayList(Expr.Interpolation.Part) = .empty;
        var i: usize = 0;
        var lit_start: usize = 0;
        while (i < inner.len) {
            if (inner[i] == '\\') {
                i += 2; // keep the escape in the literal run; the interpreter unescapes
                continue;
            }
            if (inner[i] == '$' and i + 1 < inner.len and inner[i + 1] == '{') {
                if (i > lit_start) try parts.append(self.alloc, .{ .literal = inner[lit_start..i] });
                // Find the matching `}`, honoring nested braces (e.g. a map hole).
                var depth: usize = 1;
                var j = i + 2;
                while (j < inner.len) : (j += 1) {
                    if (inner[j] == '{') depth += 1;
                    if (inner[j] == '}') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                if (depth != 0) {
                    try self.reportAt(span, "unterminated '${' in string");
                    return self.mkExpr(.{ .string_literal = .{ .text = text, .span = span } });
                }
                const e = try self.subParseExpr(inner[i + 2 .. j], span);
                try parts.append(self.alloc, .{ .expr = e });
                i = j + 1;
                lit_start = i;
            } else i += 1;
        }
        if (inner.len > lit_start) try parts.append(self.alloc, .{ .literal = inner[lit_start..] });

        const interp = try self.alloc.create(Expr.Interpolation);
        interp.* = .{ .parts = try parts.toOwnedSlice(self.alloc), .span = span };
        return self.mkExpr(.{ .interpolation = interp });
    }

    /// Lex and parse `text` as a single expression, threading any diagnostics
    /// into this parser. On failure, yields a `nil` placeholder.
    fn subParseExpr(self: *Parser, text: []const u8, span: Span) Error!*Expr {
        const lex = try lexer.tokenize(self.alloc, text);
        for (lex.diagnostics.items) |d| try self.diagnostics.append(self.alloc, d);
        var sub = Parser{
            .alloc = self.alloc,
            .tokens = lex.tokens.items,
            .src = text,
            .diagnostics = self.diagnostics,
        };
        return sub.parseExpr() catch self.mkExpr(.{ .nil_literal = span });
    }

    fn reportAt(self: *Parser, span: Span, comptime msg: []const u8) Error!void {
        try self.diagnostics.append(self.alloc, .{ .message = msg, .line = span.line, .col = span.col });
    }

    /// Parse an anonymous function expression: `func(params): expr` (single
    /// expression, implicitly returned) or `func(params):` + an indented block.
    fn parseLambda(self: *Parser) Error!*Expr {
        const kw = try self.expect(.kw_func, "expected 'func'");
        const params = try self.parseParamList();
        _ = try self.expect(.colon, "expected ':' after lambda parameters");
        var body: []const Stmt = undefined;
        if (self.at(.newline)) {
            body = try self.parseIndentedStmts();
        } else {
            const e = try self.parseExpr();
            const stmts = try self.alloc.alloc(Stmt, 1);
            stmts[0] = .{ .return_stmt = .{ .value = e, .span = exprSpan(e.*) } };
            body = stmts;
        }
        const lam = try self.alloc.create(Expr.Lambda);
        lam.* = .{ .params = params, .body = body, .span = joinSpan(kw.span, self.prev().span) };
        return self.mkExpr(.{ .lambda = lam });
    }

    // --- blocks --------------------------------------------------------------

    fn parseColonStmtBlock(self: *Parser) Error![]const Stmt {
        _ = try self.expect(.colon, "expected ':' to open a block");
        return self.parseIndentedStmts();
    }

    /// Parse an indented statement block, assuming the opening `:` is consumed.
    fn parseIndentedStmts(self: *Parser) Error![]const Stmt {
        try self.enter();
        defer self.leave();
        self.skipNewlines();
        _ = try self.expect(.indent, "expected an indented block");
        var stmts: std.ArrayList(Stmt) = .empty;
        self.skipNewlines();
        while (!self.at(.dedent) and !self.atEnd()) {
            const s = self.parseStmt() catch |e| switch (e) {
                error.ParseError => {
                    self.recover();
                    continue;
                },
                else => return e,
            };
            try stmts.append(self.alloc, s);
            self.skipNewlines();
        }
        _ = try self.expect(.dedent, "expected the block to end");
        return try stmts.toOwnedSlice(self.alloc);
    }

    fn parseColonDeclBlock(self: *Parser) Error![]const Decl {
        _ = try self.expect(.colon, "expected ':' to open a block");
        self.skipNewlines();
        _ = try self.expect(.indent, "expected an indented block");
        var decls: std.ArrayList(Decl) = .empty;
        self.skipNewlines();
        while (!self.at(.dedent) and !self.atEnd()) {
            const d = self.parseDecl() catch |e| switch (e) {
                error.ParseError => {
                    self.recover();
                    continue;
                },
                else => return e,
            };
            try decls.append(self.alloc, d);
            self.skipNewlines();
        }
        _ = try self.expect(.dedent, "expected the block to end");
        return try decls.toOwnedSlice(self.alloc);
    }

    // --- statements ----------------------------------------------------------

    fn parseStmt(self: *Parser) Error!Stmt {
        switch (self.peekKind()) {
            .kw_return => return .{ .return_stmt = try self.parseReturn() },
            .kw_if => return .{ .if_stmt = try self.parseIf() },
            .kw_while => return .{ .while_stmt = try self.parseWhile() },
            .kw_for => return .{ .for_stmt = try self.parseFor() },
            .kw_pass => {
                const t = self.advance();
                return .{ .pass = t.span };
            },
            .kw_break => {
                const t = self.advance();
                return .{ .break_stmt = t.span };
            },
            .kw_continue => {
                const t = self.advance();
                return .{ .continue_stmt = t.span };
            },
            .kw_var, .kw_const => return self.parseVarOrDestructure(),
            .kw_raise => {
                const kw = self.advance();
                const value = try self.parseExpr();
                return .{ .raise = .{ .value = value, .span = spanFrom(kw, self.prev()) } };
            },
            .kw_try => return .{ .try_catch = try self.parseTryCatch() },
            else => {
                const expr = try self.parseExpr();
                if (self.eat(.assign)) {
                    const value = try self.parseExpr();
                    return .{ .assign = .{
                        .target = expr,
                        .value = value,
                        .span = joinSpan(exprSpan(expr.*), exprSpan(value.*)),
                    } };
                }
                // Compound assignment `x <op>= e` desugars to `x = x <op> e`,
                // reusing the target node as the operator's left operand.
                if (compoundOp(self.peekKind())) |op| {
                    _ = self.advance();
                    const rhs = try self.parseExpr();
                    const span = joinSpan(exprSpan(expr.*), exprSpan(rhs.*));
                    const bin = try self.alloc.create(Expr);
                    bin.* = .{ .binary = .{ .op = op, .lhs = expr, .rhs = rhs, .span = span } };
                    return .{ .assign = .{ .target = expr, .value = bin, .span = span } };
                }
                return .{ .expr_stmt = expr };
            },
        }
    }

    fn parseReturn(self: *Parser) Error!Stmt.Return {
        const kw = self.advance(); // 'return'
        var value: ?*Expr = null;
        if (!self.at(.newline) and !self.at(.dedent) and !self.at(.r_brace) and !self.atEnd()) {
            value = try self.parseExpr();
        }
        return .{ .value = value, .span = spanFrom(kw, self.prev()) };
    }

    fn parseIf(self: *Parser) Error!Stmt.If {
        const kw = self.advance(); // 'if'
        const cond = try self.parseExpr();
        const then_body = try self.parseColonStmtBlock();
        var elifs: std.ArrayList(Stmt.ElseIf) = .empty;
        while (self.at(.kw_elif)) {
            _ = self.advance();
            const econd = try self.parseExpr();
            const ebody = try self.parseColonStmtBlock();
            try elifs.append(self.alloc, .{ .cond = econd, .body = ebody });
        }
        var else_body: ?[]const Stmt = null;
        if (self.eat(.kw_else)) else_body = try self.parseColonStmtBlock();
        return .{
            .cond = cond,
            .then_body = then_body,
            .elifs = try elifs.toOwnedSlice(self.alloc),
            .else_body = else_body,
            .span = spanFrom(kw, self.prev()),
        };
    }

    fn parseTryCatch(self: *Parser) Error!Stmt.TryCatch {
        const kw = self.advance(); // 'try'
        const body = try self.parseColonStmtBlock();
        _ = try self.expect(.kw_catch, "expected 'catch' after a try block");
        const name = try self.expect(.identifier, "expected an error variable name after 'catch'");
        const handler = try self.parseColonStmtBlock();
        return .{ .body = body, .catch_name = name.text, .handler = handler, .span = spanFrom(kw, self.prev()) };
    }

    fn parseWhile(self: *Parser) Error!Stmt.While {
        const kw = self.advance(); // 'while'
        const cond = try self.parseExpr();
        const body = try self.parseColonStmtBlock();
        return .{ .cond = cond, .body = body, .span = spanFrom(kw, self.prev()) };
    }

    fn parseFor(self: *Parser) Error!Stmt.For {
        const kw = self.advance(); // 'for'
        const binding = try self.expect(.identifier, "expected a loop variable after 'for'");
        var value_binding: ?[]const u8 = null;
        if (self.eat(.comma)) {
            const second = try self.expect(.identifier, "expected a second loop variable after ','");
            value_binding = second.text;
        }
        _ = try self.expect(.kw_in, "expected 'in' after the loop variable");
        const iter = try self.parseExpr();
        const body = try self.parseColonStmtBlock();
        return .{
            .binding = binding.text,
            .value_binding = value_binding,
            .iter = iter,
            .body = body,
            .span = spanFrom(kw, self.prev()),
        };
    }

    // --- expressions ---------------------------------------------------------

    fn parseExpr(self: *Parser) Error!*Expr {
        try self.enter();
        defer self.leave();
        const left = try self.parseRangeExpr();
        // A conditional (ternary) `then if cond else else`, looser than anything
        // above and right-associative. Only fires when `if` follows on the same
        // line (a statement-leading `if` sits after a NEWLINE). Parsed here so it
        // stays *outside* a comprehension's iterable/filter (which use
        // `parseRangeExpr`), keeping `[x for x in xs if cond]` unambiguous.
        if (self.at(.kw_if)) {
            _ = self.advance();
            const cond = try self.parseRangeExpr();
            _ = try self.expect(.kw_else, "expected 'else' in a conditional expression");
            const else_val = try self.parseExpr();
            const c = try self.alloc.create(Expr.Conditional);
            c.* = .{
                .cond = cond,
                .then_val = left,
                .else_val = else_val,
                .span = joinSpan(exprSpan(left.*), exprSpan(else_val.*)),
            };
            return self.mkExpr(.{ .conditional = c });
        }
        return left;
    }

    /// `or`/`and`/comparison/arithmetic/bitwise, plus a trailing range `a..b`.
    /// Everything below the conditional (ternary) level.
    fn parseRangeExpr(self: *Parser) Error!*Expr {
        const left = try self.parseOr();
        if (self.eat(.dot_dot)) {
            const right = try self.parseOr();
            return self.mkExpr(.{ .range = .{
                .start = left,
                .end = right,
                .span = joinSpan(exprSpan(left.*), exprSpan(right.*)),
            } });
        }
        return left;
    }

    // Logical operators sit below the comparison/arithmetic precedence table:
    // `or` is loosest, then `and`, then the prefix `not` (which binds looser
    // than comparisons, so `not a == b` is `not (a == b)`).

    fn parseOr(self: *Parser) Error!*Expr {
        var lhs = try self.parseAnd();
        while (self.at(.kw_or)) {
            _ = self.advance();
            const lhs_span = exprSpan(lhs.*);
            const rhs = try self.parseAnd();
            lhs = try self.mkExpr(.{ .binary = .{
                .op = .logical_or,
                .lhs = lhs,
                .rhs = rhs,
                .span = joinSpan(lhs_span, exprSpan(rhs.*)),
            } });
        }
        return lhs;
    }

    fn parseAnd(self: *Parser) Error!*Expr {
        var lhs = try self.parseNot();
        while (self.at(.kw_and)) {
            _ = self.advance();
            const lhs_span = exprSpan(lhs.*);
            const rhs = try self.parseNot();
            lhs = try self.mkExpr(.{ .binary = .{
                .op = .logical_and,
                .lhs = lhs,
                .rhs = rhs,
                .span = joinSpan(lhs_span, exprSpan(rhs.*)),
            } });
        }
        return lhs;
    }

    fn parseNot(self: *Parser) Error!*Expr {
        if (self.at(.kw_not)) {
            const op = self.advance();
            const operand = try self.parseNot();
            return self.mkExpr(.{ .unary = .{
                .op = .not,
                .operand = operand,
                .span = joinSpan(op.span, exprSpan(operand.*)),
            } });
        }
        return self.parseBinary(1);
    }

    /// If the next two tokens are an adjacent `<<` or `>>`, the shift op. They lex
    /// as separate `<`/`>` tokens, so a nested generic like `list<list<int>>`
    /// still closes with single `>` tokens in `parseType`.
    fn peekShift(self: *Parser) ?BinaryOp {
        const k = self.peekKind();
        if (k != .lt and k != .gt) return null;
        if (self.pos + 1 >= self.tokens.len) return null;
        const t0 = self.tokens[self.pos];
        const t1 = self.tokens[self.pos + 1];
        if (t1.kind != k or t1.span.start != t0.span.end) return null;
        return if (k == .lt) .shl else .shr;
    }

    fn parseBinary(self: *Parser, min_prec: u8) Error!*Expr {
        var lhs = try self.parseUnary();
        while (true) {
            if (self.peekShift()) |op| {
                if (shift_prec < min_prec) break;
                _ = self.advance(); // first '<' or '>'
                _ = self.advance(); // second
                const lhs_span = exprSpan(lhs.*);
                const rhs = try self.parseBinary(shift_prec + 1);
                lhs = try self.mkExpr(.{ .binary = .{
                    .op = op,
                    .lhs = lhs,
                    .rhs = rhs,
                    .span = joinSpan(lhs_span, exprSpan(rhs.*)),
                } });
                continue;
            }
            const prec = precedence(self.peekKind());
            if (prec == 0 or prec < min_prec) break;
            const op_tok = self.advance();
            const lhs_span = exprSpan(lhs.*);
            const rhs = try self.parseBinary(prec + 1);
            lhs = try self.mkExpr(.{ .binary = .{
                .op = binaryOp(op_tok.kind),
                .lhs = lhs,
                .rhs = rhs,
                .span = joinSpan(lhs_span, exprSpan(rhs.*)),
            } });
        }
        return lhs;
    }

    fn parseUnary(self: *Parser) Error!*Expr {
        if (self.at(.minus) or self.at(.tilde)) {
            const op = self.advance();
            const operand = try self.parseUnary();
            return self.mkExpr(.{ .unary = .{
                .op = if (op.kind == .tilde) .bit_not else .neg,
                .operand = operand,
                .span = joinSpan(op.span, exprSpan(operand.*)),
            } });
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) Error!*Expr {
        var expr = try self.parsePrimary();
        while (true) {
            switch (self.peekKind()) {
                .dot => {
                    _ = self.advance();
                    const name = try self.expect(.identifier, "expected a member name after '.'");
                    expr = try self.mkExpr(.{ .member = .{
                        .object = expr,
                        .name = name.text,
                        .span = joinSpan(exprSpan(expr.*), name.span),
                    } });
                },
                .l_paren => {
                    _ = self.advance();
                    var args: std.ArrayList(Expr.Arg) = .empty;
                    var seen_named = false;
                    if (!self.at(.r_paren)) {
                        while (true) {
                            // A named argument is `name: value` — an identifier
                            // immediately followed by a colon.
                            var name: ?[]const u8 = null;
                            if (self.at(.identifier) and self.tokens[self.pos + 1].kind == .colon) {
                                name = self.advance().text;
                                _ = self.advance(); // ':'
                                seen_named = true;
                            } else if (seen_named) {
                                try self.err("a positional argument cannot follow a named one");
                            }
                            try args.append(self.alloc, .{ .name = name, .value = try self.parseExpr() });
                            if (!self.eat(.comma)) break;
                        }
                    }
                    const rparen = try self.expect(.r_paren, "expected ')' to close the call");
                    expr = try self.mkExpr(.{ .call = .{
                        .callee = expr,
                        .args = try args.toOwnedSlice(self.alloc),
                        .span = joinSpan(exprSpan(expr.*), rparen.span),
                    } });
                },
                .l_bracket => {
                    _ = self.advance();
                    // `[expr]` is an index; `[a:b]` / `[a:]` / `[:b]` / `[:]` a slice.
                    var start: ?*Expr = null;
                    if (!self.at(.colon)) start = try self.parseExpr();
                    if (self.eat(.colon)) {
                        var end: ?*Expr = null;
                        if (!self.at(.r_bracket)) end = try self.parseExpr();
                        const rbracket = try self.expect(.r_bracket, "expected ']' to close the slice");
                        expr = try self.mkExpr(.{ .slice = .{
                            .object = expr,
                            .start = start,
                            .end = end,
                            .span = joinSpan(exprSpan(expr.*), rbracket.span),
                        } });
                    } else {
                        const rbracket = try self.expect(.r_bracket, "expected ']' to close the index");
                        expr = try self.mkExpr(.{ .index = .{
                            .object = expr,
                            .index = start.?,
                            .span = joinSpan(exprSpan(expr.*), rbracket.span),
                        } });
                    }
                },
                else => break,
            }
        }
        return expr;
    }

    fn parsePrimary(self: *Parser) Error!*Expr {
        const t = self.peek();
        switch (t.kind) {
            .int_literal => {
                _ = self.advance();
                return self.mkExpr(.{ .int_literal = .{ .text = t.text, .span = t.span } });
            },
            .float_literal => {
                _ = self.advance();
                return self.mkExpr(.{ .float_literal = .{ .text = t.text, .span = t.span } });
            },
            .string_literal => {
                _ = self.advance();
                if (try self.maybeInterpolation(t.text, t.span)) |e| return e;
                return self.mkExpr(.{ .string_literal = .{ .text = t.text, .span = t.span } });
            },
            .kw_true => {
                _ = self.advance();
                return self.mkExpr(.{ .bool_literal = .{ .value = true, .span = t.span } });
            },
            .kw_false => {
                _ = self.advance();
                return self.mkExpr(.{ .bool_literal = .{ .value = false, .span = t.span } });
            },
            .kw_nil => {
                _ = self.advance();
                return self.mkExpr(.{ .nil_literal = t.span });
            },
            .identifier => {
                _ = self.advance();
                return self.mkExpr(.{ .identifier = .{ .name = t.text, .span = t.span } });
            },
            .kw_func => return self.parseLambda(),
            .kw_match => return self.mkExpr(.{ .match = try self.parseMatch() }),
            .l_bracket => return self.parseArrayOrComprehension(),
            .l_brace => return self.parseMapOrComprehension(),
            .l_paren => {
                const lp = self.advance();
                const first = try self.parseExpr();
                // `(a, b, ...)` is a tuple; a single `(expr)` is just grouping.
                if (self.at(.comma)) {
                    var elements: std.ArrayList(*Expr) = .empty;
                    try elements.append(self.alloc, first);
                    while (self.eat(.comma)) {
                        if (self.at(.r_paren)) break; // trailing comma
                        try elements.append(self.alloc, try self.parseExpr());
                    }
                    const rp = try self.expect(.r_paren, "expected ')' to close the tuple");
                    return self.mkExpr(.{ .tuple = .{ .elements = try elements.toOwnedSlice(self.alloc), .span = joinSpan(lp.span, rp.span) } });
                }
                _ = try self.expect(.r_paren, "expected ')' to close the group");
                return first;
            },
            else => {
                try self.err("expected an expression");
                return error.ParseError;
            },
        }
    }

    /// `[e0, e1, ...]`. Newlines are suppressed inside `[`, so elements are
    /// comma-separated; a trailing comma is allowed.
    /// `[e0, e1, ...]` (array literal) or `[out for x[, v] in iter [if cond]]`
    /// (list comprehension), distinguished by a `for` after the first expression.
    fn parseArrayOrComprehension(self: *Parser) Error!*Expr {
        const lbracket = self.advance(); // '['
        if (self.at(.r_bracket)) {
            const rbracket = self.advance();
            return self.mkExpr(.{ .array = .{ .elements = &.{}, .span = spanFrom(lbracket, rbracket) } });
        }
        const first = try self.parseExpr();
        if (self.at(.kw_for)) return self.finishComprehension(lbracket, first);

        var elements: std.ArrayList(*Expr) = .empty;
        try elements.append(self.alloc, first);
        if (self.eat(.comma)) {
            while (!self.at(.r_bracket)) {
                try elements.append(self.alloc, try self.parseExpr());
                if (!self.eat(.comma)) break;
            }
        }
        const rbracket = try self.expect(.r_bracket, "expected ']' to close the array");
        return self.mkExpr(.{ .array = .{
            .elements = try elements.toOwnedSlice(self.alloc),
            .span = spanFrom(lbracket, rbracket),
        } });
    }

    fn finishComprehension(self: *Parser, lbracket: Token, output: *Expr) Error!*Expr {
        _ = self.advance(); // 'for'
        const binding = try self.expect(.identifier, "expected a loop variable after 'for'");
        var value_binding: ?[]const u8 = null;
        if (self.eat(.comma)) {
            const second = try self.expect(.identifier, "expected a second loop variable after ','");
            value_binding = second.text;
        }
        _ = try self.expect(.kw_in, "expected 'in' after the loop variable");
        const iter = try self.parseRangeExpr(); // not parseExpr: leave the filter `if` for us
        var cond: ?*Expr = null;
        if (self.eat(.kw_if)) cond = try self.parseRangeExpr();
        const rbracket = try self.expect(.r_bracket, "expected ']' to close the comprehension");
        const c = try self.alloc.create(Expr.Comprehension);
        c.* = .{
            .output = output,
            .binding = binding.text,
            .value_binding = value_binding,
            .iter = iter,
            .cond = cond,
            .span = spanFrom(lbracket, rbracket),
        };
        return self.mkExpr(.{ .comprehension = c });
    }

    /// `{k0: v0, k1: v1}`. Newlines stay significant inside `{`, so entries may
    /// be separated by commas, newlines, or both.
    /// `{k0: v0, ...}` (map literal) or `{k: v for x[, v2] in iter [if cond]}`
    /// (map comprehension), told apart by a `for` after the first entry.
    fn parseMapOrComprehension(self: *Parser) Error!*Expr {
        const lbrace = self.advance(); // '{'
        self.skipNewlines();
        if (self.at(.r_brace)) {
            const rbrace = self.advance();
            return self.mkExpr(.{ .map = .{ .entries = &.{}, .span = spanFrom(lbrace, rbrace) } });
        }
        const key0 = try self.parseExpr();
        _ = try self.expect(.colon, "expected ':' between a map key and value");
        const val0 = try self.parseExpr();
        if (self.at(.kw_for)) return self.finishMapComprehension(lbrace, key0, val0);

        var entries: std.ArrayList(MapEntry) = .empty;
        try entries.append(self.alloc, .{ .key = key0, .value = val0 });
        _ = self.eat(.comma);
        self.skipNewlines();
        while (!self.at(.r_brace) and !self.atEnd()) {
            const key = try self.parseExpr();
            _ = try self.expect(.colon, "expected ':' between a map key and value");
            const value = try self.parseExpr();
            try entries.append(self.alloc, .{ .key = key, .value = value });
            _ = self.eat(.comma);
            self.skipNewlines();
        }
        const rbrace = try self.expect(.r_brace, "expected '}' to close the map");
        return self.mkExpr(.{ .map = .{
            .entries = try entries.toOwnedSlice(self.alloc),
            .span = spanFrom(lbrace, rbrace),
        } });
    }

    fn finishMapComprehension(self: *Parser, lbrace: Token, key: *Expr, value: *Expr) Error!*Expr {
        _ = self.advance(); // 'for'
        const binding = try self.expect(.identifier, "expected a loop variable after 'for'");
        var value_binding: ?[]const u8 = null;
        if (self.eat(.comma)) {
            const second = try self.expect(.identifier, "expected a second loop variable after ','");
            value_binding = second.text;
        }
        _ = try self.expect(.kw_in, "expected 'in' after the loop variable");
        const iter = try self.parseRangeExpr(); // not parseExpr: leave the filter `if` for us
        var cond: ?*Expr = null;
        if (self.eat(.kw_if)) cond = try self.parseRangeExpr();
        const rbrace = try self.expect(.r_brace, "expected '}' to close the map comprehension");
        const c = try self.alloc.create(Expr.MapComprehension);
        c.* = .{
            .key = key,
            .value = value,
            .binding = binding.text,
            .value_binding = value_binding,
            .iter = iter,
            .cond = cond,
            .span = spanFrom(lbrace, rbrace),
        };
        return self.mkExpr(.{ .map_comprehension = c });
    }

    fn parseMatch(self: *Parser) Error!Expr.Match {
        const kw = self.advance(); // 'match'
        const subject = try self.parseExpr();
        _ = try self.expect(.l_brace, "expected '{' to open the match body");
        self.skipNewlines();
        var arms: std.ArrayList(MatchArm) = .empty;
        while (!self.at(.r_brace) and !self.atEnd()) {
            const pattern = try self.parsePattern();
            _ = try self.expect(.colon, "expected ':' after a match pattern");
            const body = try self.parseExpr();
            try arms.append(self.alloc, .{
                .pattern = pattern,
                .body = body,
                .span = joinSpan(patternSpan(pattern), exprSpan(body.*)),
            });
            self.skipNewlines();
        }
        const rbrace = try self.expect(.r_brace, "expected '}' to close the match body");
        return .{
            .subject = subject,
            .arms = try arms.toOwnedSlice(self.alloc),
            .span = spanFrom(kw, rbrace),
        };
    }

    fn parsePattern(self: *Parser) Error!Pattern {
        const t = self.peek();
        switch (t.kind) {
            .underscore => {
                _ = self.advance();
                return .{ .wildcard = t.span };
            },
            .int_literal => {
                _ = self.advance();
                return .{ .int_literal = .{ .text = t.text, .span = t.span } };
            },
            .float_literal => {
                _ = self.advance();
                return .{ .float_literal = .{ .text = t.text, .span = t.span } };
            },
            .string_literal => {
                _ = self.advance();
                return .{ .string_literal = .{ .text = t.text, .span = t.span } };
            },
            .kw_true => {
                _ = self.advance();
                return .{ .bool_literal = .{ .value = true, .span = t.span } };
            },
            .kw_false => {
                _ = self.advance();
                return .{ .bool_literal = .{ .value = false, .span = t.span } };
            },
            .identifier => {
                const first = self.advance();
                // `Enum.CASE` is an enum-case pattern; a bare name is a binding.
                if (self.eat(.dot)) {
                    const case = try self.expect(.identifier, "expected an enum case after '.'");
                    return .{ .enum_case = .{ .enum_name = first.text, .case = case.text, .span = spanFrom(first, case) } };
                }
                return .{ .binding = .{ .name = first.text, .span = first.span } };
            },
            else => {
                try self.err("expected a pattern");
                return error.ParseError;
            },
        }
    }
};

// --- entry point -------------------------------------------------------------

/// Tokenize and parse `src`. The returned tree borrows text slices from `src`,
/// which must outlive it. Both lexer and parser diagnostics are surfaced.
pub fn parse(gpa: std.mem.Allocator, src: []const u8) Error!Tree {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var lex = try lexer.tokenize(gpa, src);
    defer lex.deinit(gpa);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    for (lex.diagnostics.items) |d| try diagnostics.append(alloc, d);

    var parser = Parser{
        .alloc = alloc,
        .tokens = lex.tokens.items,
        .src = src,
        .diagnostics = &diagnostics,
    };
    const module = try parser.parseModule();
    const diags = try diagnostics.toOwnedSlice(alloc);
    const comments = try alloc.dupe(lexer.Comment, lex.comments.items);

    return .{ .arena = arena, .module = module, .diagnostics = diags, .comments = comments };
}

// --- REPL parsing ------------------------------------------------------------

/// One thing entered at the REPL: a top-level declaration or a statement (a bare
/// expression is a `stmt` holding an `expr_stmt`). Pointers reference the chunk's
/// arena, which must outlive the items.
pub const ReplItem = union(enum) { decl: *const Decl, stmt: *const Stmt };

pub const ReplChunk = struct {
    arena: std.heap.ArenaAllocator,
    items: []const ReplItem,
    diagnostics: []const Diagnostic,

    pub fn deinit(self: *ReplChunk) void {
        self.arena.deinit();
    }
};

fn isDeclStart(kind: TokenKind) bool {
    return switch (kind) {
        .kw_func, .kw_class, .kw_struct, .kw_enum, .kw_signal, .kw_import, .kw_pub, .kw_private, .kw_static => true,
        else => false,
    };
}

/// Parse a REPL entry: a mix of declarations and statements. Anything that isn't
/// a declaration keyword is parsed as a statement, so `1 + 1` and `print(x)` are
/// accepted directly.
pub fn parseRepl(gpa: std.mem.Allocator, src: []const u8) Error!ReplChunk {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var lex = try lexer.tokenize(gpa, src);
    defer lex.deinit(gpa);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    for (lex.diagnostics.items) |d| try diagnostics.append(alloc, d);

    var parser = Parser{
        .alloc = alloc,
        .tokens = lex.tokens.items,
        .src = src,
        .diagnostics = &diagnostics,
    };

    var items: std.ArrayList(ReplItem) = .empty;
    parser.skipNewlines();
    while (!parser.atEnd()) {
        if (isDeclStart(parser.peekKind())) {
            const d = parser.parseDecl() catch |e| switch (e) {
                error.ParseError => {
                    parser.recover();
                    continue;
                },
                else => return e,
            };
            const dp = try alloc.create(Decl);
            dp.* = d;
            try items.append(alloc, .{ .decl = dp });
        } else {
            const s = parser.parseStmt() catch |e| switch (e) {
                error.ParseError => {
                    parser.recover();
                    continue;
                },
                else => return e,
            };
            const sp = try alloc.create(Stmt);
            sp.* = s;
            try items.append(alloc, .{ .stmt = sp });
        }
        parser.skipNewlines();
    }

    const its = try items.toOwnedSlice(alloc);
    const diags = try diagnostics.toOwnedSlice(alloc);
    return .{ .arena = arena, .items = its, .diagnostics = diags };
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "parseRepl accepts a definition and a bare expression" {
    var chunk = try parseRepl(testing.allocator, "func f():\n    return 1\n\nf() + 2");
    defer chunk.deinit();
    try testing.expectEqual(@as(usize, 0), chunk.diagnostics.len);
    try testing.expectEqual(@as(usize, 2), chunk.items.len);
    try testing.expect(chunk.items[0] == .decl);
    try testing.expect(chunk.items[0].decl.* == .func);
    try testing.expect(chunk.items[1] == .stmt);
    try testing.expect(chunk.items[1].stmt.* == .expr_stmt);
}

test "parses an import" {
    var tree = try parse(testing.allocator, "import graphics");
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    try testing.expectEqual(@as(usize, 1), tree.module.decls.len);
    try testing.expect(std.meta.activeTag(tree.module.decls[0]) == .import);
    try testing.expectEqualStrings("graphics", tree.module.decls[0].import.name);
}

test "parses a dotted import path" {
    var tree = try parse(testing.allocator, "import engine.graphics.render");
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const imp = tree.module.decls[0].import;
    try testing.expectEqual(@as(usize, 3), imp.path.len);
    try testing.expectEqualStrings("engine", imp.path[0]);
    try testing.expectEqualStrings("graphics", imp.path[1]);
    try testing.expectEqualStrings("render", imp.path[2]);
    try testing.expectEqualStrings("render", imp.name); // bound name is the last segment
}

test "parameter types are optional" {
    var tree = try parse(testing.allocator, "func log(msg, level: int):\n    pass");
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const f = tree.module.decls[0].func;
    try testing.expectEqual(@as(usize, 2), f.params.len);
    try testing.expect(f.params[0].type == null); // msg is untyped
    try testing.expectEqualStrings("int", f.params[1].type.?.name);
}

test "parses generic collection type arguments" {
    var tree = try parse(testing.allocator, "var m: map<str, list<int>> = {}");
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const ty = tree.module.decls[0].var_decl.type.?;
    try testing.expectEqualStrings("map", ty.name);
    try testing.expectEqual(@as(usize, 2), ty.args.len);
    try testing.expectEqualStrings("str", ty.args[0].name);
    // The value is itself a generic: list<int>.
    try testing.expectEqualStrings("list", ty.args[1].name);
    try testing.expectEqual(@as(usize, 1), ty.args[1].args.len);
    try testing.expectEqualStrings("int", ty.args[1].args[0].name);
}

test "deeply nested expressions are rejected instead of overflowing" {
    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "var x = ");
    for (0..5000) |_| try buf.append(gpa, '(');
    try buf.append(gpa, '1');
    for (0..5000) |_| try buf.append(gpa, ')');
    var tree = try parse(gpa, buf.items);
    defer tree.deinit();
    try testing.expect(tree.diagnostics.len > 0);
    try testing.expect(std.mem.indexOf(u8, tree.diagnostics[0].message, "nested too deeply") != null);
}

test "a required parameter cannot follow one with a default" {
    var tree = try parse(testing.allocator, "func f(a = 1, b):\n    return a");
    defer tree.deinit();
    try testing.expect(tree.diagnostics.len > 0);
    try testing.expect(std.mem.indexOf(u8, tree.diagnostics[0].message, "cannot follow one with a default") != null);
}

test "a parameter default is parsed as an expression" {
    var tree = try parse(testing.allocator, "func f(a, b = 1 + 2):\n    return a");
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const params = tree.module.decls[0].func.params;
    try testing.expect(params[0].default == null);
    try testing.expect(params[1].default != null);
}

test "parses an interpolated string into literal and expression parts" {
    var tree = try parse(testing.allocator, "var s = \"a ${x} b\"");
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const val = tree.module.decls[0].var_decl.value.?;
    try testing.expect(val.* == .interpolation);
    const parts = val.interpolation.parts;
    try testing.expectEqual(@as(usize, 3), parts.len);
    try testing.expect(parts[0] == .literal);
    try testing.expect(parts[1] == .expr);
    try testing.expect(parts[1].expr.* == .identifier);
    try testing.expect(parts[2] == .literal);
}

test "a string without a hole is a plain literal" {
    var tree = try parse(testing.allocator, "var s = \"no holes here\"");
    defer tree.deinit();
    try testing.expect(tree.module.decls[0].var_decl.value.?.* == .string_literal);
}

test "parses a single-expression lambda" {
    var tree = try parse(testing.allocator, "var f = func(x): x * 2");
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const val = tree.module.decls[0].var_decl.value.?;
    try testing.expect(val.* == .lambda);
    const lam = val.lambda;
    try testing.expectEqual(@as(usize, 1), lam.params.len);
    try testing.expectEqualStrings("x", lam.params[0].name);
    try testing.expectEqual(@as(usize, 1), lam.body.len);
    try testing.expect(lam.body[0] == .return_stmt); // single expr becomes a return
}

test "compound assignment desugars to an assign" {
    var tree = try parse(testing.allocator, "func main():\n    x += 1");
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const body = tree.module.decls[0].func.body;
    try testing.expect(body[0] == .assign);
    const val = body[0].assign.value;
    try testing.expect(val.* == .binary);
    try testing.expect(val.binary.op == .add);
    try testing.expect(val.binary.lhs == body[0].assign.target); // target reused as lhs
}

test "parses a module-qualified type" {
    var tree = try parse(testing.allocator, "var p: geometry.Point = geometry.origin()");
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const ty = tree.module.decls[0].var_decl.type.?;
    try testing.expectEqualStrings("geometry", ty.module.?);
    try testing.expectEqualStrings("Point", ty.name);
}

test "parses an optional generic type" {
    var tree = try parse(testing.allocator, "var xs: ?list<int> = nil");
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const ty = tree.module.decls[0].var_decl.type.?;
    try testing.expect(ty.optional);
    try testing.expectEqualStrings("list", ty.name);
    try testing.expectEqual(@as(usize, 1), ty.args.len);
    try testing.expectEqualStrings("int", ty.args[0].name);
}

test "parses signals with and without parameters" {
    const src =
        \\signal started
        \\signal damaged(amount: int, source)
    ;
    var tree = try parse(testing.allocator, src);
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    try testing.expectEqual(@as(usize, 2), tree.module.decls.len);

    const a = tree.module.decls[0];
    try testing.expect(std.meta.activeTag(a) == .signal);
    try testing.expectEqualStrings("started", a.signal.name);
    try testing.expectEqual(@as(usize, 0), a.signal.params.len);

    const b = tree.module.decls[1].signal;
    try testing.expectEqualStrings("damaged", b.name);
    try testing.expectEqual(@as(usize, 2), b.params.len);
    try testing.expectEqualStrings("amount", b.params[0].name);
    try testing.expect(b.params[1].type == null); // source is untyped
}

test "parses optional types and the nil literal" {
    var tree = try parse(testing.allocator, "const x: ?int = nil");
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const d = tree.module.decls[0].var_decl;
    try testing.expectEqualStrings("int", d.type.?.name);
    try testing.expect(d.type.?.optional);
    try testing.expect(std.meta.activeTag(d.value.?.*) == .nil_literal);
}

test "parses a typed const with a string value" {
    var tree = try parse(testing.allocator, "const VERSION: str = \"0.1\"");
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const d = tree.module.decls[0];
    try testing.expect(std.meta.activeTag(d) == .var_decl);
    try testing.expect(d.var_decl.is_const);
    try testing.expectEqualStrings("VERSION", d.var_decl.name);
    try testing.expectEqualStrings("str", d.var_decl.type.?.name);
    try testing.expect(std.meta.activeTag(d.var_decl.value.?.*) == .string_literal);
}

test "parses a struct with fields and a method" {
    const src =
        \\struct Point:
        \\    var x: int = 0
        \\    var y: int = 0
        \\
        \\    func magnitude() -> int:
        \\        return x
    ;
    var tree = try parse(testing.allocator, src);
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const d = tree.module.decls[0];
    try testing.expect(std.meta.activeTag(d) == .struct_decl);
    try testing.expectEqualStrings("Point", d.struct_decl.name);
    try testing.expectEqual(@as(usize, 3), d.struct_decl.members.len);
    try testing.expect(std.meta.activeTag(d.struct_decl.members[0]) == .var_decl);
    try testing.expect(std.meta.activeTag(d.struct_decl.members[2]) == .func);
}

test "parses an enum body" {
    var tree = try parse(testing.allocator, "enum Status {\n    OK\n    NOT_FOUND\n}");
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const d = tree.module.decls[0];
    try testing.expect(std.meta.activeTag(d) == .enum_decl);
    try testing.expectEqual(@as(usize, 2), d.enum_decl.members.len);
    try testing.expectEqualStrings("OK", d.enum_decl.members[0].name);
    try testing.expectEqualStrings("NOT_FOUND", d.enum_decl.members[1].name);
}

test "parses enum-case patterns in match" {
    const src =
        \\func name(s: Status) -> str:
        \\    return match s {
        \\        Status.OK: "ok"
        \\        n: "other"
        \\    }
    ;
    var tree = try parse(testing.allocator, src);
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const arms = tree.module.decls[0].func.body[0].return_stmt.value.?.match.arms;
    try testing.expectEqual(@as(usize, 2), arms.len);
    try testing.expect(std.meta.activeTag(arms[0].pattern) == .enum_case);
    try testing.expectEqualStrings("Status", arms[0].pattern.enum_case.enum_name);
    try testing.expectEqualStrings("OK", arms[0].pattern.enum_case.case);
    try testing.expect(std.meta.activeTag(arms[1].pattern) == .binding);
}

test "parses a function with a match expression" {
    const src =
        \\pub func describe(code: int) -> str:
        \\    return match code {
        \\        200: "ok"
        \\        404: "not found"
        \\        _: "unknown"
        \\    }
    ;
    var tree = try parse(testing.allocator, src);
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const d = tree.module.decls[0];
    try testing.expect(std.meta.activeTag(d) == .func);
    const f = d.func;
    try testing.expect(f.visibility == .public);
    try testing.expectEqualStrings("describe", f.name);
    try testing.expectEqual(@as(usize, 1), f.params.len);
    try testing.expectEqualStrings("code", f.params[0].name);
    try testing.expectEqualStrings("int", f.params[0].type.?.name);
    try testing.expectEqualStrings("str", f.return_type.?.name);
    try testing.expectEqual(@as(usize, 1), f.body.len);

    const ret = f.body[0];
    try testing.expect(std.meta.activeTag(ret) == .return_stmt);
    const val = ret.return_stmt.value.?;
    try testing.expect(std.meta.activeTag(val.*) == .match);
    try testing.expectEqual(@as(usize, 3), val.match.arms.len);
    try testing.expect(std.meta.activeTag(val.match.arms[2].pattern) == .wildcard);
}

test "parses a class with methods, for loop, and if/else" {
    const src =
        \\pub class Player extends Entity uses Damageable:
        \\    var health: int = 100
        \\
        \\    pub func take_damage(amount: int) -> bool:
        \\        for effect in active_effects:
        \\            effect.tick()
        \\        if health <= 0:
        \\            return true
        \\        else:
        \\            return false
    ;
    var tree = try parse(testing.allocator, src);
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const d = tree.module.decls[0];
    try testing.expect(std.meta.activeTag(d) == .class);
    const c = d.class;
    try testing.expectEqualStrings("Player", c.name);
    try testing.expectEqualStrings("Entity", c.extends.?.name);
    try testing.expectEqual(@as(usize, 1), c.uses.len);
    try testing.expectEqualStrings("Damageable", c.uses[0].name);
    try testing.expectEqual(@as(usize, 2), c.members.len);

    try testing.expect(std.meta.activeTag(c.members[0]) == .var_decl);
    try testing.expect(std.meta.activeTag(c.members[1]) == .func);

    const m = c.members[1].func;
    try testing.expectEqual(@as(usize, 2), m.body.len);
    try testing.expect(std.meta.activeTag(m.body[0]) == .for_stmt);
    try testing.expect(std.meta.activeTag(m.body[1]) == .if_stmt);

    // for body: a single `effect.tick()` call statement
    const for_stmt = m.body[0].for_stmt;
    try testing.expectEqualStrings("effect", for_stmt.binding);
    try testing.expectEqual(@as(usize, 1), for_stmt.body.len);
    try testing.expect(std.meta.activeTag(for_stmt.body[0]) == .expr_stmt);
    try testing.expect(std.meta.activeTag(for_stmt.body[0].expr_stmt.*) == .call);

    // if/else with an else branch
    const iff = m.body[1].if_stmt;
    try testing.expect(std.meta.activeTag(iff.cond.*) == .binary);
    try testing.expect(iff.cond.binary.op == .le);
    try testing.expect(iff.else_body != null);
}

test "binary operators respect precedence" {
    // 1 + 2 * 3  ->  (1 + (2 * 3))
    var tree = try parse(testing.allocator, "const x = 1 + 2 * 3");
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const val = tree.module.decls[0].var_decl.value.?;
    try testing.expect(std.meta.activeTag(val.*) == .binary);
    try testing.expect(val.binary.op == .add);
    try testing.expect(std.meta.activeTag(val.binary.rhs.*) == .binary);
    try testing.expect(val.binary.rhs.binary.op == .mul);
}

test "reports an error and recovers to the next declaration" {
    // The middle line is not a valid declaration; the parser must flag it and
    // still parse the const declarations on either side.
    var tree = try parse(testing.allocator, "const x = 1\n+ +\nconst y = 2");
    defer tree.deinit();

    try testing.expect(tree.diagnostics.len > 0);
    var var_decls: usize = 0;
    for (tree.module.decls) |d| {
        if (std.meta.activeTag(d) == .var_decl) var_decls += 1;
    }
    try testing.expectEqual(@as(usize, 2), var_decls);
}

test "logical operators nest by precedence" {
    // a or b and c  ->  a or (b and c)
    var tree = try parse(testing.allocator, "const r = a or b and c");
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const v = tree.module.decls[0].var_decl.value.?;
    try testing.expect(std.meta.activeTag(v.*) == .binary);
    try testing.expect(v.binary.op == .logical_or);
    try testing.expect(std.meta.activeTag(v.binary.rhs.*) == .binary);
    try testing.expect(v.binary.rhs.binary.op == .logical_and);
}

test "not binds looser than comparison" {
    // not x == y  ->  not (x == y)
    var tree = try parse(testing.allocator, "const r = not x == y");
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const v = tree.module.decls[0].var_decl.value.?;
    try testing.expect(std.meta.activeTag(v.*) == .unary);
    try testing.expect(v.unary.op == .not);
    try testing.expect(std.meta.activeTag(v.unary.operand.*) == .binary);
    try testing.expect(v.unary.operand.binary.op == .eq);
}

test "parses indexing" {
    var tree = try parse(testing.allocator, "const x = items[0]");
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const v = tree.module.decls[0].var_decl.value.?;
    try testing.expect(std.meta.activeTag(v.*) == .index);
    try testing.expect(std.meta.activeTag(v.index.object.*) == .identifier);
    try testing.expect(std.meta.activeTag(v.index.index.*) == .int_literal);
}

test "parses an array literal" {
    var tree = try parse(testing.allocator, "const xs = [1, 2, 3]");
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const v = tree.module.decls[0].var_decl.value.?;
    try testing.expect(std.meta.activeTag(v.*) == .array);
    try testing.expectEqual(@as(usize, 3), v.array.elements.len);
    try testing.expect(std.meta.activeTag(v.array.elements[0].*) == .int_literal);
}

test "parses a map literal" {
    var tree = try parse(testing.allocator, "const m = {1: \"a\", 2: \"b\"}");
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const v = tree.module.decls[0].var_decl.value.?;
    try testing.expect(std.meta.activeTag(v.*) == .map);
    try testing.expectEqual(@as(usize, 2), v.map.entries.len);
    try testing.expect(std.meta.activeTag(v.map.entries[0].key.*) == .int_literal);
    try testing.expect(std.meta.activeTag(v.map.entries[0].value.*) == .string_literal);
}

test "parses enum members with values" {
    const src =
        \\enum Status {
        \\    OK = 200
        \\    NOT_FOUND = 404
        \\}
    ;
    var tree = try parse(testing.allocator, src);
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const e = tree.module.decls[0].enum_decl;
    try testing.expectEqual(@as(usize, 2), e.members.len);
    try testing.expectEqualStrings("OK", e.members[0].name);
    try testing.expect(e.members[0].value != null);
    try testing.expect(std.meta.activeTag(e.members[0].value.?.*) == .int_literal);
    try testing.expect(e.members[1].value != null);
}

test "enum members without values still parse" {
    var tree = try parse(testing.allocator, "enum E {\n    A\n    B\n}");
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const e = tree.module.decls[0].enum_decl;
    try testing.expectEqual(@as(usize, 2), e.members.len);
    try testing.expect(e.members[0].value == null);
}

test "parses break and continue statements" {
    const src =
        \\func f():
        \\    while true:
        \\        break
        \\    for x in xs:
        \\        continue
    ;
    var tree = try parse(testing.allocator, src);
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const body = tree.module.decls[0].func.body;
    try testing.expectEqual(@as(usize, 2), body.len);
    try testing.expect(std.meta.activeTag(body[0].while_stmt.body[0]) == .break_stmt);
    try testing.expect(std.meta.activeTag(body[1].for_stmt.body[0]) == .continue_stmt);
}

test "index and call chain in a for body" {
    const src =
        \\pub func run():
        \\    for i in items:
        \\        handlers[i].fire()
    ;
    var tree = try parse(testing.allocator, src);
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const body = tree.module.decls[0].func.body;
    try testing.expectEqual(@as(usize, 1), body.len);
    const stmt = body[0].for_stmt.body[0];
    // handlers[i].fire()  ->  call( member( index(handlers, i), fire ) )
    try testing.expect(std.meta.activeTag(stmt.expr_stmt.*) == .call);
    const callee = stmt.expr_stmt.call.callee;
    try testing.expect(std.meta.activeTag(callee.*) == .member);
    try testing.expect(std.meta.activeTag(callee.member.object.*) == .index);
}

test "enum members may be comma-separated on one line" {
    var tree = try parse(testing.allocator, "enum Http { OK = 200, NOT_FOUND = 404 }");
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const e = tree.module.decls[0].enum_decl;
    try testing.expectEqual(@as(usize, 2), e.members.len);
    try testing.expectEqualStrings("OK", e.members[0].name);
    try testing.expectEqualStrings("NOT_FOUND", e.members[1].name);
    try testing.expect(e.members[1].value != null);
}
