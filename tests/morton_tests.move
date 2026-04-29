/// Extracted morton module tests.
#[test_only]
module mercator::morton_tests {
    use mercator::morton;

    #[test]
    fun interleave_zero_zero() {
        assert!(morton::interleave(0, 0) == 0, 0);
    }

    #[test]
    fun interleave_one_zero() {
        assert!(morton::interleave(1, 0) == 1, 0);
    }

    #[test]
    fun interleave_zero_one() {
        assert!(morton::interleave(0, 1) == 2, 0);
    }

    #[test]
    fun interleave_one_one() {
        assert!(morton::interleave(1, 1) == 3, 0);
    }

    #[test]
    fun interleave_two_one() {
        assert!(morton::interleave(2, 1) == 6, 0);
    }

    #[test]
    fun interleave_three_zero() {
        assert!(morton::interleave(3, 0) == 5, 0);
    }

    #[test]
    fun interleave_max_values() {
        assert!(morton::interleave(0xFFFFFFFF, 0xFFFFFFFF)
            == 0xFFFFFFFFFFFFFFFF, 0);
    }

    #[test]
    fun depth_prefix_root_is_one() {
        assert!(morton::depth_prefix(0, 0) == 1, 0);
        assert!(morton::depth_prefix(999, 0) == 1, 1);
    }

    #[test]
    fun depth_prefix_depth_one_quadrants() {
        assert!(morton::depth_prefix(morton::interleave(0, 0), 1) == 4, 0);
        assert!(morton::depth_prefix(morton::interleave(1, 0), 1) == 5, 1);
        assert!(morton::depth_prefix(morton::interleave(0, 1), 1) == 6, 2);
        assert!(morton::depth_prefix(morton::interleave(1, 1), 1) == 7, 3);
    }

    #[test]
    fun depth_prefix_depth_two() {
        assert!(morton::depth_prefix(morton::interleave(2, 1), 2) == 22, 0);
        assert!(morton::depth_prefix(morton::interleave(0, 0), 2) == 16, 1);
        assert!(morton::depth_prefix(morton::interleave(3, 3), 2) == 31, 2);
    }

    #[test]
    fun parent_key_depth_one_to_root() {
        assert!(morton::parent_key(4) == 1, 0);
        assert!(morton::parent_key(5) == 1, 1);
        assert!(morton::parent_key(6) == 1, 2);
        assert!(morton::parent_key(7) == 1, 3);
    }

    #[test]
    fun parent_key_depth_two_to_depth_one() {
        assert!(morton::parent_key(22) == 5, 0);
        assert!(morton::parent_key(16) == 4, 1);
    }

    #[test]
    fun parent_chain_to_root() {
        let d2 = morton::depth_prefix(morton::interleave(3, 3), 2);
        assert!(d2 == 31, 0);
        let d1 = morton::parent_key(d2);
        assert!(d1 == 7, 1);
        let d0 = morton::parent_key(d1);
        assert!(d0 == 1, 2);
    }

    #[test]
    #[expected_failure(abort_code = morton::EDepthTooLarge)]
    fun depth_prefix_rejects_depth_32() {
        morton::depth_prefix(0, 32);
    }

    #[test]
    #[expected_failure(abort_code = morton::ECannotGetParentOfRoot)]
    fun parent_key_rejects_root() {
        morton::parent_key(1);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // F-19: interleave_n bit shift overflow for bits > 31
    // ═════════════════════════════════════════════════════════════════════════════
    // interleave_n(x, y, bits) shifts by (i*2+1). For bits=32, max shift = 63 (ok).
    // For bits=33, shift=65 which overflows u64. Currently guarded by max_depth=31
    // but the function itself has no assertion.

    #[test]
    #[expected_failure(abort_code = morton::EBitsOverflow)]
    /// Fixed (F-19): interleave_n now aborts with EBitsOverflow for bits > 32
    /// instead of a generic Move runtime shift overflow.
    fun f19_interleave_n_shift_overflow() {
        // bits=33 → last iteration: i=32, shift = 32*2+1 = 65 > 63 → overflow
        let _result = morton::interleave_n(1, 1, 33);
    }
}
