const SlabSize = @import("ecs/coreheap.zig").SlabSize;

pub const BlockSize = 64;
pub const SlabHeaderSize = BlockSize; // same as Block size for alignment
pub const BlocksPerSlab = (SlabSize - SlabHeaderSize) / BlockSize; // expected 255 blocks per slab

pub const BlockOrientation = enum(u2) {
    North,
    East,
    South,
    West,
    pub fn rotateClockwise(self: BlockOrientation) BlockOrientation {
        return @enumFromInt(@as(u2, @intFromEnum(self)) +% 1);
    }
    pub fn rotateCounterClockwise(self: BlockOrientation) BlockOrientation {
        return @enumFromInt(@as(u2, @intFromEnum(self)) -% 1);
    }
};

pub const Block = struct {
    kind: u16, // e.g. collider, armor, engine, etc.
    health: f16,
    local_pos: [2]i16,
    orientation: BlockOrientation,
    // Padding to align to 64 bytes
    _pad: [BlockSize - @sizeOf(u16) - @sizeOf(f16) - @sizeOf([2]i16) - @sizeOf(BlockOrientation)]u8,
};

pub const Slab = struct {
    ship_id: u32,
    used_blocks: u8, // max 255 blocks used, -1 for header (this struct)
    block_bitmap: [32]u8 = [_]u8{0} ** 32, // Block allocation bitmap: 255 bits (32 bytes, fits in header padding)
    // Remaining padding to align to header size
    _pad: [SlabHeaderSize - @sizeOf(u32) - @sizeOf(u8) - @sizeOf([32]u8)]u8,

    blocks: [BlocksPerSlab]Block,

    /// Set block as allocated
    pub fn setBlockUsed(self: *Slab, idx: usize) void {
        self.block_bitmap[idx / 8] |= @as(u8, 1) << @intCast(idx % 8);
    }
    /// Set block as free
    pub fn setBlockFree(self: *Slab, idx: usize) void {
        self.block_bitmap[idx / 8] &= ~(@as(u8, 1) << @intCast(idx % 8));
    }
    /// Check if block is used
    pub fn isBlockUsed(self: *Slab, idx: usize) bool {
        return (self.block_bitmap[idx / 8] & (@as(u8, 1) << @intCast(idx % 8))) != 0;
    }
};
