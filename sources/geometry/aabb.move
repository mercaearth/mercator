/// Axis-Aligned Bounding Box (AABB) scaffolding for geometry checks.
module mercator::aabb {
    // === Errors ===

    const EInvalidBox: u64 = 1000;
    const EBadVertices: u64 = 1001;
    const EMismatch: u64 = 1002;

    // === Structs ===

    /// Axis-aligned bounding box in fixed-point coordinates.
    public struct AABB has copy, drop, store {
        min_x: u64,
        min_y: u64,
        max_x: u64,
        max_y: u64,
    }

    // === Public Functions ===

    public fun new(min_x: u64, min_y: u64, max_x: u64, max_y: u64): AABB {
        assert!(min_x <= max_x, EInvalidBox);
        assert!(min_y <= max_y, EInvalidBox);
        AABB { min_x, min_y, max_x, max_y }
    }

    public fun from_vertices(xs: &vector<u64>, ys: &vector<u64>): AABB {
        let n = vector::length(xs);
        assert!(n >= 3, EBadVertices);
        assert!(n == vector::length(ys), EMismatch);

        let mut min_x = *vector::borrow(xs, 0);
        let mut max_x = min_x;
        let mut min_y = *vector::borrow(ys, 0);
        let mut max_y = min_y;

        let mut i = 1;
        while (i < n) {
            let x = *vector::borrow(xs, i);
            let y = *vector::borrow(ys, i);

            if (x < min_x) { min_x = x };
            if (x > max_x) { max_x = x };
            if (y < min_y) { min_y = y };
            if (y > max_y) { max_y = y };

            i = i + 1;
        };

        AABB { min_x, min_y, max_x, max_y }
    }

    public fun intersects(a: &AABB, b: &AABB): bool {
        a.min_x < b.max_x && a.max_x > b.min_x && a.min_y < b.max_y && a.max_y > b.min_y
    }

    public fun min_x(aabb: &AABB): u64 {
        aabb.min_x
    }

    public fun min_y(aabb: &AABB): u64 {
        aabb.min_y
    }

    public fun max_x(aabb: &AABB): u64 {
        aabb.max_x
    }

    public fun max_y(aabb: &AABB): u64 {
        aabb.max_y
    }

    #[test]
    fun aabb_from_vertices_tracks_extrema() {
        let xs = vector[1_000_000, 2_000_000, 2_000_000, 1_000_000];
        let ys = vector[1_000_000, 1_000_000, 2_000_000, 2_000_000];

        let aabb = from_vertices(&xs, &ys);

        assert!(min_x(&aabb) == 1_000_000, 0);
        assert!(max_x(&aabb) == 2_000_000, 1);
        assert!(min_y(&aabb) == 1_000_000, 2);
        assert!(max_y(&aabb) == 2_000_000, 3);
    }

    #[test]
    fun aabb_rejects_when_edges_only_touch() {
        let a = new(0, 0, 1_000_000, 1_000_000);
        let b = new(1_000_000, 0, 2_000_000, 1_000_000);

        assert!(!intersects(&a, &b), 0);
    }

    #[test]
    fun aabb_rejects_separated_boxes() {
        let a = new(0, 0, 1_000_000, 1_000_000);
        let b = new(2_000_000, 0, 3_000_000, 1_000_000);

        assert!(!intersects(&a, &b), 0);
    }
}
