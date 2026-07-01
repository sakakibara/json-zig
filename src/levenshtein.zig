//! Bounded Levenshtein edit distance and best-match-within-threshold.
//! Used for "did you mean X?" suggestions in parser and decode errors.

const std = @import("std");
const testing = std.testing;

/// Edit distance between `a` and `b`. The DP path returns `cap + 1`
/// when the true distance is > `cap`, but the shortcuts do not clamp
/// uniformly: an empty input returns the other string's raw length
/// even when that exceeds `cap`. Callers must treat any result > `cap`
/// as "no match", not as an exact distance. O(a.len * b.len) DP, no
/// allocation (uses two stack rows up to 256 chars).
pub fn levenshtein(a: []const u8, b: []const u8, cap: usize) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    if (a.len > 256 or b.len > 256) {
        // Bail to length-difference lower bound; we don't expect such long keys.
        const diff = if (a.len > b.len) a.len - b.len else b.len - a.len;
        return if (diff > cap) cap + 1 else diff;
    }

    var prev: [257]usize = undefined;
    var curr: [257]usize = undefined;
    var i: usize = 0;
    while (i <= b.len) : (i += 1) prev[i] = i;

    i = 0;
    while (i < a.len) : (i += 1) {
        curr[0] = i + 1;
        var min_in_row: usize = curr[0];
        var j: usize = 0;
        while (j < b.len) : (j += 1) {
            const cost: usize = if (a[i] == b[j]) 0 else 1;
            const del = prev[j + 1] + 1;
            const ins = curr[j] + 1;
            const sub = prev[j] + cost;
            curr[j + 1] = @min(@min(del, ins), sub);
            if (curr[j + 1] < min_in_row) min_in_row = curr[j + 1];
        }
        if (min_in_row > cap) return cap + 1;
        @memcpy(prev[0 .. b.len + 1], curr[0 .. b.len + 1]);
    }
    return if (prev[b.len] > cap) cap + 1 else prev[b.len];
}

/// Return the candidate with the smallest edit distance <= `threshold`
/// from `target`. Ties are broken by earlier position in `candidates`.
/// Returns null if no candidate is within `threshold`.
pub fn closestMatch(target: []const u8, candidates: []const []const u8, threshold: usize) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = threshold + 1;
    for (candidates) |cand| {
        const d = levenshtein(target, cand, threshold);
        if (d <= threshold and d < best_dist) {
            best = cand;
            best_dist = d;
        }
    }
    return best;
}

/// Suggested threshold for "did you mean": max(2, len/4). Allows
/// typos in long identifiers without matching unrelated short ones.
pub fn suggestionThreshold(target_len: usize) usize {
    return @max(2, target_len / 4);
}

test "levenshtein: edge cases" {
    try testing.expectEqual(@as(usize, 0), levenshtein("", "", 10));
    try testing.expectEqual(@as(usize, 5), levenshtein("", "hello", 10));
    try testing.expectEqual(@as(usize, 5), levenshtein("hello", "", 10));
    try testing.expectEqual(@as(usize, 0), levenshtein("hello", "hello", 10));
    try testing.expectEqual(@as(usize, 1), levenshtein("hello", "hallo", 10));
    try testing.expectEqual(@as(usize, 2), levenshtein("hello", "hxllx", 10));
    try testing.expectEqual(@as(usize, 3), levenshtein("kitten", "sitting", 10));
}

test "levenshtein: cap returns cap+1 when exceeded" {
    // Real distance is 4 ("kitten" + "more" -> "kittenmore");
    // with cap=2 we should get 3 (i.e., cap+1).
    try testing.expectEqual(@as(usize, 3), levenshtein("kitten", "kittenmore", 2));
}

test "closestMatch: returns best within threshold" {
    const cands = [_][]const u8{ "port", "host", "tls", "name" };
    try testing.expectEqualStrings("port", closestMatch("prt", &cands, 2).?);
    try testing.expectEqualStrings("host", closestMatch("hosts", &cands, 2).?);
    try testing.expect(closestMatch("xyz", &cands, 2) == null);
}

test "closestMatch: ties broken by candidate order" {
    const cands = [_][]const u8{ "apple", "april" };
    // "appl" is distance 1 from both. Should return "apple" (first).
    try testing.expectEqualStrings("apple", closestMatch("appl", &cands, 2).?);
}

test "suggestionThreshold" {
    try testing.expectEqual(@as(usize, 2), suggestionThreshold(0));
    try testing.expectEqual(@as(usize, 2), suggestionThreshold(7));
    try testing.expectEqual(@as(usize, 2), suggestionThreshold(8));
    try testing.expectEqual(@as(usize, 3), suggestionThreshold(12));
    try testing.expectEqual(@as(usize, 5), suggestionThreshold(20));
}
