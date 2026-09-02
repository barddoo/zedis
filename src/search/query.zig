const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const ParseError = error{ QuerySyntax, OutOfMemory };

/// Nodes borrow slices from the query string passed to `parse`.
pub const Node = union(enum) {
    all,
    term: Term,
    phrase: Phrase,
    field_term: FieldTerm,
    numeric: NumericRange,
    tag: TagSet,
    disjunction: []Node,
    conjunction: []Node,
    not: *Node,
};

pub const Term = struct {
    text: []const u8,
};

pub const Phrase = struct {
    text: []const u8,
};

pub const FieldTerm = struct {
    field: []const u8,
    term: []const u8,
};

pub const NumericRange = struct {
    field: []const u8,
    min: ?f64,
    max: ?f64,
};

pub const TagSet = struct {
    field: []const u8,
    tags: []const []const u8,
};

pub const Knn = struct {
    field: []const u8,
    k: usize,
    vec_param: []const u8,
};

pub const Query = struct {
    allocator: Allocator,
    filter: Node,
    knn: ?Knn = null,

    pub fn deinit(self: *Query) void {
        freeNode(self.allocator, &self.filter);
    }
};

const Scanner = struct {
    s: []const u8,
    pos: usize = 0,

    fn eof(self: *const Scanner) bool {
        return self.pos >= self.s.len;
    }

    fn peek(self: *const Scanner) u8 {
        return if (self.pos < self.s.len) self.s[self.pos] else 0;
    }

    fn skipWs(self: *Scanner) void {
        while (self.pos < self.s.len and std.ascii.isWhitespace(self.s[self.pos])) self.pos += 1;
    }
};

/// Parses a RediSearch query string into a Query AST.
/// Supports: `*`, bare terms, `"phrases"`, `@field:term`,
/// `@tag:{a|b}`, `@num:[min max]`, implicit AND, `|` OR, `-` NOT,
/// and the `=>[KNN k @vec $param]` suffix.
pub fn parse(allocator: Allocator, query: []const u8) ParseError!Query {
    if (std.mem.indexOf(u8, query, "=>")) |idx| {
        const filter_s = query[0..idx];
        const knn_s = query[idx + 2 ..];
        var sc = Scanner{ .s = filter_s };
        const filter = try parseExpr(allocator, &sc);
        const knn = try parseKnn(knn_s);
        return .{ .allocator = allocator, .filter = filter, .knn = knn };
    }

    var sc = Scanner{ .s = query };
    const filter = try parseExpr(allocator, &sc);
    return .{ .allocator = allocator, .filter = filter };
}

fn parseExpr(allocator: Allocator, sc: *Scanner) ParseError!Node {
    var conjuncts: std.ArrayListUnmanaged(Node) = .empty;
    defer conjuncts.deinit(allocator);

    while (true) {
        const conj = try parseConjunct(allocator, sc);
        try conjuncts.append(allocator, conj);
        sc.skipWs();
        if (sc.peek() == '|') {
            sc.pos += 1;
            continue;
        }
        break;
    }

    if (conjuncts.items.len == 1) return conjuncts.items[0];
    return .{ .disjunction = try conjuncts.toOwnedSlice(allocator) };
}

fn parseConjunct(allocator: Allocator, sc: *Scanner) ParseError!Node {
    var factors: std.ArrayListUnmanaged(Node) = .empty;
    defer factors.deinit(allocator);

    while (true) {
        sc.skipWs();
        if (sc.eof() or sc.peek() == '|' or sc.peek() == ')') break;
        const f = try parseFactor(allocator, sc);
        try factors.append(allocator, f);
    }

    if (factors.items.len == 1) return factors.items[0];
    return .{ .conjunction = try factors.toOwnedSlice(allocator) };
}

fn parseFactor(allocator: Allocator, sc: *Scanner) ParseError!Node {
    sc.skipWs();
    var negate = false;
    if (sc.peek() == '-') {
        negate = true;
        sc.pos += 1;
    }
    const atom = try parseAtom(allocator, sc);
    if (!negate) return atom;
    const boxed = try allocator.create(Node);
    boxed.* = atom;
    return .{ .not = boxed };
}

fn parseAtom(allocator: Allocator, sc: *Scanner) ParseError!Node {
    sc.skipWs();
    switch (sc.peek()) {
        '(' => {
            sc.pos += 1;
            const node = try parseExpr(allocator, sc);
            sc.skipWs();
            if (sc.peek() == ')') sc.pos += 1;
            return node;
        },
        '@' => return parseFieldPredicate(allocator, sc),
        '"' => {
            sc.pos += 1;
            const start = sc.pos;
            while (sc.pos < sc.s.len and sc.s[sc.pos] != '"') sc.pos += 1;
            const text = sc.s[start..sc.pos];
            if (sc.pos < sc.s.len) sc.pos += 1;
            return .{ .phrase = .{ .text = text } };
        },
        '*' => {
            sc.pos += 1;
            return .all;
        },
        0 => return error.QuerySyntax,
        else => {
            const start = sc.pos;
            while (sc.pos < sc.s.len and !isBareStop(sc.s[sc.pos])) sc.pos += 1;
            if (sc.pos == start) return error.QuerySyntax;
            return .{ .term = .{ .text = sc.s[start..sc.pos] } };
        },
    }
}

fn parseFieldPredicate(allocator: Allocator, sc: *Scanner) ParseError!Node {
    sc.pos += 1; // '@'
    const fstart = sc.pos;
    while (sc.pos < sc.s.len and sc.s[sc.pos] != ':' and !std.ascii.isWhitespace(sc.s[sc.pos])) sc.pos += 1;
    const field = sc.s[fstart..sc.pos];
    if (field.len == 0 or sc.pos >= sc.s.len or sc.s[sc.pos] != ':') return error.QuerySyntax;
    sc.pos += 1;

    if (sc.peek() == '{') {
        sc.pos += 1;
        var tags: std.ArrayListUnmanaged([]const u8) = .empty;
        defer tags.deinit(allocator);
        while (sc.pos < sc.s.len and sc.s[sc.pos] != '}') {
            const tstart = sc.pos;
            while (sc.pos < sc.s.len and sc.s[sc.pos] != '|' and sc.s[sc.pos] != '}') sc.pos += 1;
            if (sc.pos > tstart) try tags.append(allocator, sc.s[tstart..sc.pos]);
            if (sc.pos < sc.s.len and sc.s[sc.pos] == '|') sc.pos += 1;
        }
        if (sc.pos < sc.s.len) sc.pos += 1; // '}'
        return .{ .tag = .{ .field = field, .tags = try tags.toOwnedSlice(allocator) } };
    }

    if (sc.peek() == '[') {
        sc.pos += 1;
        const min = try parseBound(sc);
        const max = try parseBound(sc);
        sc.skipWs();
        if (sc.peek() == ']') sc.pos += 1;
        return .{ .numeric = .{ .field = field, .min = min, .max = max } };
    }

    const tstart = sc.pos;
    while (sc.pos < sc.s.len and !isBareStop(sc.s[sc.pos])) sc.pos += 1;
    const term = sc.s[tstart..sc.pos];
    if (term.len == 0) return error.QuerySyntax;
    return .{ .field_term = .{ .field = field, .term = term } };
}

fn parseBound(sc: *Scanner) ParseError!?f64 {
    if (sc.peek() == '(') sc.pos += 1;
    if (std.mem.startsWith(u8, sc.s[sc.pos..], "-inf") or std.mem.startsWith(u8, sc.s[sc.pos..], "+inf")) {
        sc.pos += 4;
        return null;
    }
    sc.skipWs();
    const start = sc.pos;
    while (sc.pos < sc.s.len and !std.ascii.isWhitespace(sc.s[sc.pos]) and sc.s[sc.pos] != ']') sc.pos += 1;
    const num_s = sc.s[start..sc.pos];
    return std.fmt.parseFloat(f64, num_s) catch return error.QuerySyntax;
}

fn parseKnn(s: []const u8) ParseError!Knn {
    var sc = Scanner{ .s = s };
    if (sc.peek() == '[') sc.pos += 1;
    sc.skipWs();
    if (!std.mem.startsWith(u8, sc.s[sc.pos..], "KNN")) return error.QuerySyntax;
    sc.pos += 3;
    sc.skipWs();
    const k = try parseUint(&sc);
    sc.skipWs();
    if (sc.peek() != '@') return error.QuerySyntax;
    sc.pos += 1;
    const fstart = sc.pos;
    while (sc.pos < sc.s.len and !std.ascii.isWhitespace(sc.s[sc.pos]) and sc.s[sc.pos] != '$') sc.pos += 1;
    const field = sc.s[fstart..sc.pos];
    sc.skipWs();
    if (sc.peek() != '$') return error.QuerySyntax;
    sc.pos += 1;
    const pstart = sc.pos;
    while (sc.pos < sc.s.len and !std.ascii.isWhitespace(sc.s[sc.pos]) and sc.s[sc.pos] != ']') sc.pos += 1;
    const param = sc.s[pstart..sc.pos];

    if (k == 0 or field.len == 0 or param.len == 0) return error.QuerySyntax;
    return .{ .field = field, .k = k, .vec_param = param };
}

fn parseUint(sc: *Scanner) ParseError!usize {
    const start = sc.pos;
    while (sc.pos < sc.s.len and std.ascii.isDigit(sc.s[sc.pos])) sc.pos += 1;
    if (sc.pos == start) return error.QuerySyntax;
    return std.fmt.parseInt(usize, sc.s[start..sc.pos], 10) catch return error.QuerySyntax;
}

inline fn isBareStop(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == '|' or c == ')' or c == '(';
}

fn freeNode(allocator: Allocator, node: *Node) void {
    switch (node.*) {
        .disjunction => |children| {
            for (children) |*child| freeNode(allocator, child);
            allocator.free(children);
        },
        .conjunction => |children| {
            for (children) |*child| freeNode(allocator, child);
            allocator.free(children);
        },
        .not => |child| {
            freeNode(allocator, child);
            allocator.destroy(child);
        },
        .tag => |t| allocator.free(t.tags),
        else => {},
    }
}

const testing = std.testing;

fn parseTest(allocator: Allocator, q: []const u8) !Query {
    return parse(allocator, q);
}

test "parse bare term" {
    var q = try parseTest(testing.allocator, "hello");
    defer q.deinit();
    try testing.expectEqual(std.meta.activeTag(q.filter), .term);
    try testing.expectEqualStrings("hello", q.filter.term.text);
}

test "parse implicit AND of terms" {
    var q = try parseTest(testing.allocator, "hello world");
    defer q.deinit();
    try testing.expectEqual(std.meta.activeTag(q.filter), .conjunction);
    try testing.expectEqual(@as(usize, 2), q.filter.conjunction.len);
}

test "parse OR" {
    var q = try parseTest(testing.allocator, "foo|bar");
    defer q.deinit();
    try testing.expectEqual(std.meta.activeTag(q.filter), .disjunction);
    try testing.expectEqual(@as(usize, 2), q.filter.disjunction.len);
}

test "parse fielded term" {
    var q = try parseTest(testing.allocator, "@title:zig");
    defer q.deinit();
    try testing.expectEqual(std.meta.activeTag(q.filter), .field_term);
    try testing.expectEqualStrings("title", q.filter.field_term.field);
    try testing.expectEqualStrings("zig", q.filter.field_term.term);
}

test "parse phrase" {
    var q = try parseTest(testing.allocator, "\"quick fox\"");
    defer q.deinit();
    try testing.expectEqual(std.meta.activeTag(q.filter), .phrase);
    try testing.expectEqualStrings("quick fox", q.filter.phrase.text);
}

test "parse numeric range" {
    var q = try parseTest(testing.allocator, "@price:[10 50]");
    defer q.deinit();
    try testing.expectEqual(std.meta.activeTag(q.filter), .numeric);
    try testing.expectApproxEqAbs(@as(f64, 10), q.filter.numeric.min.?, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 50), q.filter.numeric.max.?, 0.001);
}

test "parse numeric open range" {
    var q = try parseTest(testing.allocator, "@price:[-inf 20]");
    defer q.deinit();
    try testing.expectEqual(std.meta.activeTag(q.filter), .numeric);
    try testing.expect(q.filter.numeric.min == null);
    try testing.expectApproxEqAbs(@as(f64, 20), q.filter.numeric.max.?, 0.001);
}

test "parse tag set" {
    var q = try parseTest(testing.allocator, "@color:{red|blue}");
    defer q.deinit();
    try testing.expectEqual(std.meta.activeTag(q.filter), .tag);
    try testing.expectEqual(@as(usize, 2), q.filter.tag.tags.len);
    try testing.expectEqualStrings("red", q.filter.tag.tags[0]);
    try testing.expectEqualStrings("blue", q.filter.tag.tags[1]);
}

test "parse negation" {
    var q = try parseTest(testing.allocator, "-foo");
    defer q.deinit();
    try testing.expectEqual(std.meta.activeTag(q.filter), .not);
    try testing.expectEqual(std.meta.activeTag(q.filter.not.*), .term);
}

test "parse all" {
    var q = try parseTest(testing.allocator, "*");
    defer q.deinit();
    try testing.expectEqual(std.meta.activeTag(q.filter), .all);
}

test "parse knn suffix" {
    var q = try parseTest(testing.allocator, "*=>[KNN 5 @v $B]");
    defer q.deinit();
    try testing.expectEqual(std.meta.activeTag(q.filter), .all);
    try testing.expect(q.knn != null);
    try testing.expectEqual(@as(usize, 5), q.knn.?.k);
    try testing.expectEqualStrings("v", q.knn.?.field);
    try testing.expectEqualStrings("B", q.knn.?.vec_param);
}

test "parse knn with filter" {
    var q = try parseTest(testing.allocator, "@title:foo=>[KNN 3 @v $Q]");
    defer q.deinit();
    try testing.expectEqual(std.meta.activeTag(q.filter), .field_term);
    try testing.expect(q.knn != null);
    try testing.expectEqual(@as(usize, 3), q.knn.?.k);
}
