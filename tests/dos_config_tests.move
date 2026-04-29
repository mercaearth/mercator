#[test_only]
module mercator::dos_config_tests {
    use mercator::index;

    const SCALE: u64 = 1_000_000;
    const DEFAULT_SPAN: u64 = 1024;
    const DEFAULT_OCCUPANCY: u64 = 64;
    const DEFAULT_PROBES: u64 = 2_000_000;
    const BLOCK_CELL_SIZE: u64 = 200_000_000;

    fun square_xs(min: u64, max: u64): vector<u64> {
        vector[min, max, max, min]
    }

    fun square_ys(min: u64, max: u64): vector<u64> {
        vector[min, min, max, max]
    }

    fun register_square(
        idx: &mut index::Index,
        min: u64,
        max: u64,
        ctx: &mut tx_context::TxContext,
    ): sui::object::ID {
        index::register(idx, vector[square_xs(min, max)], vector[square_ys(min, max)], ctx)
    }

    #[test]
    fun test_new_config_with_dos_params() {
        let cfg = index::new_config(64, 10, SCALE, 16, 7, 512);
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(
            SCALE,
            8,
            64,
            10,
            DEFAULT_SPAN,
            DEFAULT_OCCUPANCY,
            DEFAULT_PROBES,
            &mut ctx,
        );
        index::set_config(&mut idx, cfg);

        assert!(index::max_vertices_per_part(&idx) == 64, 0);
        assert!(index::max_parts_per_polygon(&idx) == 10, 1);
        assert!(index::scaling_factor(&idx) == SCALE, 2);
        assert!(index::max_broadphase_span(&idx) == 16, 3);
        assert!(index::max_cell_occupancy(&idx) == 7, 4);
        assert!(index::max_probes_per_call(&idx) == 512, 5);

        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = index::EBadConfig)]
    fun test_new_config_zero_span_aborts() {
        let _cfg = index::new_config(64, 10, SCALE, 0, 1, 1);
    }

    #[test]
    #[expected_failure(abort_code = index::EBadConfig)]
    fun test_new_config_span_one_aborts() {
        let _cfg = index::new_config(64, 10, SCALE, 1, 1, 1);
    }

    #[test]
    #[expected_failure(abort_code = index::EBadConfig)]
    fun test_new_config_zero_occupancy_aborts() {
        let _cfg = index::new_config(64, 10, SCALE, 2, 0, 4);
    }

    #[test]
    #[expected_failure(abort_code = index::EBadConfig)]
    fun test_new_config_probes_too_low_aborts() {
        let _cfg = index::new_config(64, 10, SCALE, 4, 1, 3);
    }

    #[test]
    #[expected_failure(abort_code = index::EBadConfig)]
    fun test_set_config_span_exceeds_depth_aborts() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(
            SCALE,
            8,
            64,
            10,
            DEFAULT_SPAN,
            DEFAULT_OCCUPANCY,
            DEFAULT_PROBES,
            &mut ctx,
        );
        let cfg = index::new_config(64, 10, SCALE, 257, 8, 66_049);
        index::set_config(&mut idx, cfg);
        std::unit_test::destroy(idx);
    }

    #[test]
    fun test_set_config_span_at_depth_limit_passes() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(
            SCALE,
            8,
            64,
            10,
            DEFAULT_SPAN,
            DEFAULT_OCCUPANCY,
            DEFAULT_PROBES,
            &mut ctx,
        );
        let cfg = index::new_config(64, 10, SCALE, 256, 8, 65_536);
        index::set_config(&mut idx, cfg);

        assert!(index::max_broadphase_span(&idx) == 256, 0);
        assert!(index::max_cell_occupancy(&idx) == 8, 1);
        assert!(index::max_probes_per_call(&idx) == 65_536, 2);

        std::unit_test::destroy(idx);
    }

    #[test]
    fun test_config_updated_event_has_6_fields() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(
            SCALE,
            8,
            64,
            10,
            DEFAULT_SPAN,
            DEFAULT_OCCUPANCY,
            DEFAULT_PROBES,
            &mut ctx,
        );
        index::set_config(&mut idx, index::new_config(32, 5, SCALE, 64, 9, 4_096));

        assert!(index::max_vertices_per_part(&idx) == 32, 0);
        assert!(index::max_parts_per_polygon(&idx) == 5, 1);
        assert!(index::scaling_factor(&idx) == SCALE, 2);
        assert!(index::max_broadphase_span(&idx) == 64, 3);
        assert!(index::max_cell_occupancy(&idx) == 9, 4);
        assert!(index::max_probes_per_call(&idx) == 4_096, 5);

        std::unit_test::destroy(idx);
    }

    #[test]
    fun test_config_round_trip() {
        let mut ctx = tx_context::dummy();
        let idx = index::with_config(
            SCALE,
            9,
            99,
            12,
            128,
            3,
            16_384,
            &mut ctx,
        );

        assert!(index::max_vertices_per_part(&idx) == 99, 0);
        assert!(index::max_parts_per_polygon(&idx) == 12, 1);
        assert!(index::scaling_factor(&idx) == SCALE, 2);
        assert!(index::max_broadphase_span(&idx) == 128, 3);
        assert!(index::max_cell_occupancy(&idx) == 3, 4);
        assert!(index::max_probes_per_call(&idx) == 16_384, 5);

        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = index::EQueryTooLarge)]
    fun test_per_index_span_override() {
        let mut ctx = tx_context::dummy();
        let mut idx_wide = index::with_config(
            SCALE,
            8,
            64,
            10,
            128,
            8,
            65_536,
            &mut ctx,
        );
        let mut idx_tight = index::with_config(
            SCALE,
            8,
            64,
            10,
            16,
            8,
            65_536,
            &mut ctx,
        );
        let _wide_id = register_square(&mut idx_wide, 0, 20 * SCALE, &mut ctx);
        assert!(index::count(&idx_wide) == 1, 0);

        let _tight_id = register_square(&mut idx_tight, 0, 20 * SCALE, &mut ctx);
        std::unit_test::destroy(idx_wide);
        std::unit_test::destroy(idx_tight);
    }

    #[test]
    #[expected_failure(abort_code = index::ECellOccupancyExceeded)]
    fun test_per_index_occupancy_override() {
        let mut ctx = tx_context::dummy();
        let mut idx_wide = index::with_config(
            SCALE,
            8,
            64,
            10,
            128,
            64,
            65_536,
            &mut ctx,
        );
        let mut idx_tight = index::with_config(
            SCALE,
            8,
            64,
            10,
            128,
            4,
            65_536,
            &mut ctx,
        );
        let cell_key = 42u64;
        let depth = 0u8;

        let mut i = 0u64;
        while (i < 5) {
            let wide_id = sui::object::id_from_address(sui::address::from_u256((i as u256) + 1));
            index::register_in_cell(&mut idx_wide, wide_id, cell_key, depth);
            i = i + 1;
        };

        let mut j = 0u64;
        while (j < 4) {
            let tight_id = sui::object::id_from_address(sui::address::from_u256((j as u256) + 100));
            index::register_in_cell(&mut idx_tight, tight_id, cell_key, depth);
            j = j + 1;
        };
        let overflow_id = sui::object::id_from_address(sui::address::from_u256(1000));
        index::register_in_cell(&mut idx_tight, overflow_id, cell_key, depth);

        std::unit_test::destroy(idx_wide);
        std::unit_test::destroy(idx_tight);
    }

    #[test]
    #[expected_failure(abort_code = index::EQueryTooLarge)]
    fun test_headroom_block() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(
            BLOCK_CELL_SIZE,
            8,
            64,
            10,
            64,
            8,
            65_536,
            &mut ctx,
        );
        let _ok_id = register_square(&mut idx, 0, 64 * BLOCK_CELL_SIZE, &mut ctx);
        assert!(index::count(&idx) == 1, 0);

        let _too_wide_id = register_square(
            &mut idx,
            15_000_000_000,
            15_000_000_000 + (65 * BLOCK_CELL_SIZE),
            &mut ctx,
        );
        std::unit_test::destroy(idx);
    }
}
