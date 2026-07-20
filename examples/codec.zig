const json = @import("json");
const std = @import("std");
const FieldAttributes = std.builtin.Type.UnionField.Attributes; // std.lang.Type.Union.Attributes in master

fn fullName(comptime container: []const u8, comptime short: []const u8) []const u8 {
    return "PvZCards.Engine." ++ container ++ "." ++ short ++ ", EngineLib, Version=1.0.0.0, Culture=neutral, PublicKeyToken=null";
}

fn buildRenames(comptime fields: anytype, container: []const u8, suffix: []const u8, decls: anytype) [fields.len]json.AnnotationRename {
    comptime {
        var renames: [fields.len]json.AnnotationRename = undefined;
        for (fields, 0..) |field, i| {
            const c = if (@hasField(@TypeOf(decls), field.name)) @field(decls, field.name) else container;
            renames[i] = .{ .json_name = fullName(c, field.name ++ suffix), .zig_name = field.name };
        }

        return renames;
    }
}

pub const Rarity = enum(u8) {
    R0 = 4,
    R1 = 0,
    R2 = 1,
    R3 = 2,
    R4 = 3,
    Event = 5,
};

pub const Color = enum(u8) {
    @"0",
    Kabloom,
    MegaGro,
    Guardian,
    Smarty,
    Solar,
    Brainy,
    Hearty,
    Sneaky,
    Hungry,
    Madcap,

    @"MegaGro, Smarty", // Green Shadow
    @"Kabloom, Solar", // Solar Flare
    @"Guardian, Solar", // Wall-Knight
    @"MegaGro, Solar", // Chompzilla
    @"Kabloom, Guardian", // Spudow
    @"Guardian, Smarty", // Citron
    @"MegaGro, Guardian", // Grass Knuckles
    @"Kabloom, Smarty", // Nightshade
    @"Smarty, Solar", // Rose
    @"Kabloom, MegaGro", // Captain Combustible

    @"Brainy, Sneaky", // Super Brainz, Impfinity
    @"Hearty, Hungry", // Smash
    @"Sneaky, Madcap", // Impfinity
    @"Brainy, Hearty", // Rustbolt
    @"Hearty, Madcap", // Z-Mech
    @"Sneaky, Hungry", // Brain Freeze
    @"Brainy, Madcap", // Professor Brainstorm
    @"Brainy, Hungry", // Immorticia
    @"Hungry, Madcap", // Electric Boolgalo
    @"Hearty, Sneaky", // Neptuna
};

pub const BaseId = enum(u8) {
    Base,
    BaseZombie,
    BasePlantOneTimeEffect,
    BaseZombieOneTimeEffect,
    BasePlantEnvironment,
    BaseZombieEnvironment,
};

pub const Faction = enum(u8) { All, Plants, Zombies };

pub const SpecialAbility = enum(u8) {
    Ambush = 9,
    Repeater = 11,
    Overshoot = 12,
    Unique = 13,
    ////////////
    Armor = 0,
    AttackOverride = 1,
    Deadly = 2,
    Frenzy = 3,
    Strikethrough = 4,
    Truestrike = 5,
    Untrickable = 6,
};

const _CardDescriptor: json.Annotations(CardDescriptor) = .{
    .json_skip = &[_][]const u8{ "_isGravestone", "_isSurprise" },
};

pub const CardDescriptor = struct {
    prefabName: ?[]const u8,
    baseId: BaseId,
    color: Color,
    set: ?[]const u8,
    rarity: u8,
    setAndRarityKey: ?[]const u8,
    craftingBuy: ?u16,
    craftingSell: ?u16,
    displayHealth: u8,
    displayAttack: u8,
    displaySunCost: u8,
    faction: Faction,
    ignoreDeckLimit: bool,
    isPower: bool,
    isPrimaryPower: bool,
    isFighter: bool,
    isEnv: bool,
    isAquatic: bool,
    isTeamup: bool,
    subtypes: [][]const u8,
    tags: [][]const u8,
    subtype_affinities: [][]const u8,
    subtype_affinity_weights: []f16,
    tag_affinities: [][]const u8,
    tag_affinity_weights: []f16,
    card_affinities: []u16,
    card_affinity_weights: []f16,
    usable: bool,
    special_abilities: []SpecialAbility,

    _isGravestone: bool = false,
    _isSurprise: bool = false,
};

pub const DescriptorJsonRegistry = json.TypedCodec(.{_CardDescriptor});
const src =
    \\{
    \\      "prefabName":"Pecanolith",
    \\      "baseId":"Base",
    \\      "color":"Guardian",
    \\      "set":"Set2",
    \\      "rarity":3,
    \\      "setAndRarityKey":"Galaxy_Legendary",
    \\      "craftingBuy":4000,
    \\      "craftingSell":1000,
    \\      "displayHealth":7,
    \\      "displayAttack":0,
    \\      "displaySunCost":5,
    \\      "faction":"Plants",
    \\      "ignoreDeckLimit":false,
    \\      "isPower":false,
    \\      "isPrimaryPower":false,
    \\      "isFighter":true,
    \\      "isEnv":false,
    \\      "isAquatic":false,
    \\      "isTeamup":false,
    \\      "subtypes":[
    \\         "Nut"
    \\      ],
    \\      "tags":[
    \\         "plantlegend",
    \\         "galaxyplant"
    \\      ],
    \\      "subtype_affinities":[
    \\         
    \\      ],
    \\      "subtype_affinity_weights":[
    \\         
    \\      ],
    \\      "tag_affinities":[
    \\         
    \\      ],
    \\      "tag_affinity_weights":[
    \\         
    \\      ],
    \\      "card_affinities":[
    \\         316,
    \\         81
    \\      ],
    \\      "card_affinity_weights":[
    \\         1.3,
    \\         1.3
    \\      ],
    \\      "usable":true,
    \\      "special_abilities":[
    \\         "AttackOverride",
    \\         "Unique"
    \\      ]
    \\}
;

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    comptime {
        @setEvalBranchQuota(15_000);
    }

    const card = try DescriptorJsonRegistry.parseInto(CardDescriptor, .codec_then_local, allocator, src, .{});
    std.debug.print("{s}\n", .{if (card.prefabName) |pn| pn else "null"});

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try DescriptorJsonRegistry.encode(.codec_then_local, &aw.writer, card, allocator, .{ .indent = 2, .sort_keys = false });
    std.debug.print("{s}", .{aw.written()});
}
