/// Proof-of-concept tests for security findings in the Merca.tr Protocol.
/// These tests are tagged `poc_` for filterability: `sui move test --filter poc_`
/// Each test demonstrates a specific vulnerability identified in the audit.
#[test_only]
module mercator::poc_tests {
    use mercator::index;

    /// PoC for finding [IDX-01]: Missing coordinate range validation before u32 cast.
    ///
    /// Before the fix, `as u32` aborted with a generic ARITHMETIC_ERROR when the
    /// grid coordinate exceeded u32::MAX. The protocol now rejects the same input
    /// with a descriptive ECoordinateTooLarge abort before attempting the cast.
    ///
    /// With the default cell_size=1_000_000, the maximum supported coordinate
    /// is u32::MAX × 1_000_000 ≈ 4.295 × 10^15 fixed-point units.
    ///
    /// This regression test verifies the descriptive abort by registering a polygon
    /// above the threshold.
    #[test]
    #[expected_failure(abort_code = index::ECoordinateTooLarge)]
    fun poc_coordinate_overflow_bypass() {
        // With cell_size=1, threshold = u32::MAX = 4,294,967,295.
        // Coordinates above this value now abort with ECoordinateTooLarge.
        let mut ctx = sui::tx_context::dummy();
        let mut idx = index::with_config(
            1,
            8,
            64,
            10,
            1024,
            64,
            2_000_000,
            &mut ctx,
        );
        let xs = vector[
            vector[4_295_000_000u64, 4_296_000_000u64, 4_296_000_000u64, 4_295_000_000u64],
        ];
        let ys = vector[vector[0u64, 0u64, 1_000_000u64, 1_000_000u64]];
        let _id = index::register(&mut idx, xs, ys, &mut ctx);
        // Should never reach here — ECoordinateTooLarge aborts first.

        std::unit_test::destroy(idx);
    }
}
