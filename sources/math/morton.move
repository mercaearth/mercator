/// Morton code (Z-order curve) utilities for hierarchical quadtree spatial indexing.
/// Provides bit-interleaving of 2D coordinates and depth-prefixed keys for
/// representing quadtree cells as unique u64 identifiers.
module mercator::morton {
    // === Errors ===

    const EDepthTooLarge: u64 = 3001;
    const ECannotGetParentOfRoot: u64 = 3002;
    const EBitsOverflow: u64 = 3003;

    // === Constants ===

    /// Maximum supported quadtree depth. Limited to 31 so that
    /// depth-prefixed keys (1 sentinel bit + 2*depth data bits = max 63 bits) fit in u64.
    const MAX_DEPTH: u8 = 31;

    // === Public Functions ===

    /// Interleave two 32-bit integers into a 64-bit Morton code (Z-order curve).
    /// Bit 2i of result = bit i of x, bit 2i+1 of result = bit i of y.
    public fun interleave(x: u32, y: u32): u64 {
        interleave_n(x, y, 32)
    }

    /// Interleave the bottom `bits` bits of x and y into a Morton code.
    /// More gas-efficient when only a few bits are needed (e.g., at shallow quadtree depths).
    public fun interleave_n(x: u32, y: u32, bits: u8): u64 {
        assert!(bits <= 32, EBitsOverflow);
        let mut result: u64 = 0;
        let mut i: u8 = 0;
        while (i < bits) {
            result =
                result
            | ((((x as u64) >> i) & 1) << (i * 2))
            | ((((y as u64) >> i) & 1) << (i * 2 + 1));
            i = i + 1;
        };
        result
    }

    /// Prefix a Morton code with its depth level using a sentinel bit.
    /// Key format: 1-bit sentinel at position 2*depth, followed by 2*depth data bits.
    /// This makes keys unique across all quadtree depths.
    ///
    /// The caller provides the Morton code of CELL coordinates at the given depth
    /// (i.e., `interleave(cx, cy)` where cx, cy have at most `depth` significant bits).
    ///
    /// Examples:
    ///   depth=0 → key=1 (root, single cell)
    ///   depth=1 → keys 4..7 (four quadrants)
    ///   depth=2 → keys 16..31 (sixteen cells)
    public fun depth_prefix(morton_code: u64, depth: u8): u64 {
        assert!(depth <= MAX_DEPTH, EDepthTooLarge);
        if (depth == 0) {
            return 1
        };
        let d2: u8 = depth * 2;
        let sentinel = 1u64 << d2;
        sentinel | (morton_code & (sentinel - 1))
    }

    /// Get the parent key (one level up in the quadtree).
    /// Strips the bottom 2 Morton bits and shifts the sentinel down.
    /// Aborts if called on the root key (1).
    public fun parent_key(key: u64): u64 {
        assert!(key > 1, ECannotGetParentOfRoot);
        key >> 2
    }

    /// Return the maximum supported quadtree depth.
    public fun max_depth(): u8 {
        MAX_DEPTH
    }
}
