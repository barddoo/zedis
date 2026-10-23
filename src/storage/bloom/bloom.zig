const std = @import("std");
const scalable = @import("scalable.zig");

// Re-export the main types for easier access
pub const BloomFilter = scalable.ScalableBloomFilter;
