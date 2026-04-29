/// Extracted mutations module tests.
#[test_only, allow(unused_variable, duplicate_alias)]
module mercator::mutation_tests {
    use mercator::{aabb, index::{Self, Index}, mutations, polygon};
    use sui::{object, test_scenario::{Self, Scenario}, tx_context};

    const ADMIN: address = @0xCAFE;
    const USER: address = @0xBEEF;
    const ENotContained: u64 = 5001;
    const EOverlap: u64 = 5002;
    const ESelfRepartition: u64 = 5003;
    const ENotAdjacent: u64 = 5004;
    const EOwnerMismatch: u64 = 5005;
    const ESelfMerge: u64 = 5006;
    const EAreaConservationViolation: u64 = 2012;
    const EEdgeTooShort: u64 = 2010;
    const ENotConvex: u64 = 2003;
    const ENotFound: u64 = 4005;
    const EInvalidChildCount: u64 = 5007;
    const SCALE: u64 = 1_000_000;

    fun square_xs(min: u64, max: u64): vector<u64> {
        vector[min, max, max, min]
    }

    fun square_ys(min: u64, max: u64): vector<u64> {
        vector[min, min, max, max]
    }

    fun register_square(
        index: &mut Index,
        min_x: u64,
        min_y: u64,
        max_x: u64,
        max_y: u64,
        scenario: &mut Scenario,
    ): ID {
        index::register(
            index,
            vector[square_xs(min_x, max_x)],
            vector[square_ys(min_y, max_y)],
            test_scenario::ctx(scenario),
        )
    }

    fun test_index(ctx: &mut tx_context::TxContext): Index {
        index::with_config(1_000_000, 3, 64, 10, 1024, 64, 2_000_000, ctx)
    }

    fun sq_xs(min: u64, max: u64): vector<u64> {
        vector[min, max, max, min]
    }

    fun sq_ys(min: u64, max: u64): vector<u64> {
        vector[min, min, max, max]
    }

    fun poc_register_square(
        idx: &mut Index,
        x0: u64,
        y0: u64,
        x1: u64,
        y1: u64,
        ctx: &mut tx_context::TxContext,
    ): object::ID {
        index::register(idx, vector[sq_xs(x0, x1)], vector[sq_ys(y0, y1)], ctx)
    }

    fun rect_xs(min_x: u64, max_x: u64): vector<u64> {
        vector[min_x, max_x, max_x, min_x]
    }

    fun rect_ys(min_y: u64, max_y: u64): vector<u64> {
        vector[min_y, min_y, max_y, max_y]
    }

    fun register_rect(
        idx: &mut Index,
        min_x: u64,
        min_y: u64,
        max_x: u64,
        max_y: u64,
        ctx: &mut tx_context::TxContext,
    ): object::ID {
        index::register(idx, vector[rect_xs(min_x, max_x)], vector[rect_ys(min_y, max_y)], ctx)
    }

    fun register_rect_in_scenario(
        idx: &mut Index,
        min_x: u64,
        min_y: u64,
        max_x: u64,
        max_y: u64,
        scenario: &mut Scenario,
    ): object::ID {
        register_rect(idx, min_x, min_y, max_x, max_y, test_scenario::ctx(scenario))
    }

    fun contains_id(v: &vector<object::ID>, id: object::ID): bool {
        let mut i = 0;
        while (i < vector::length(v)) {
            if (*vector::borrow(v, i) == id) {
                return true
            };
            i = i + 1;
        };
        false
    }

    #[test]
    fun reshape_unclaimed_happy() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::with_config(
            1_000_000,
            2,
            16,
            4,
            1024,
            64,
            2_000_000,
            test_scenario::ctx(&mut scenario),
        );
        let polygon_id = register_square(&mut idx, 0, 0, 1_000_000, 1_000_000, &mut scenario);

        let before = index::get(&idx, polygon_id);
        let old_area = polygon::area(before);
        let old_cell = *vector::borrow(polygon::cells(before), 0);

        mutations::reshape_unclaimed(
            &mut idx,
            polygon_id,
            vector[square_xs(0, 2_000_000)],
            vector[square_ys(0, 1_000_000)],
            test_scenario::ctx(&mut scenario),
        );

        let after = index::get(&idx, polygon_id);
        let new_area = polygon::area(after);
        let new_cell = *vector::borrow(polygon::cells(after), 0);

        assert!(old_area != new_area, 0);
        assert!(old_cell != new_cell, 1);
        assert!(index::count(&idx) == 1, 2);

        index::remove(&mut idx, polygon_id, test_scenario::ctx(&mut scenario));
        index::destroy_empty(idx);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ENotContained, location = mercator::mutations)]
    fun reshape_unclaimed_not_contained() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let polygon_id = register_square(&mut idx, 0, 0, 1_000_000, 1_000_000, &mut scenario);

        mutations::reshape_unclaimed(
            &mut idx,
            polygon_id,
            vector[square_xs(2_000_000, 3_000_000)],
            vector[square_ys(0, 1_000_000)],
            test_scenario::ctx(&mut scenario),
        );
        index::destroy_empty(idx);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EOverlap, location = mercator::mutations)]
    fun reshape_unclaimed_overlap() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let polygon_id = register_square(&mut idx, 0, 0, 1_000_000, 1_000_000, &mut scenario);
        let _neighbor_id = register_square(
            &mut idx,
            2_000_000,
            0,
            3_000_000,
            1_000_000,
            &mut scenario,
        );

        mutations::reshape_unclaimed(
            &mut idx,
            polygon_id,
            vector[square_xs(0, 3_000_000)],
            vector[square_ys(0, 1_000_000)],
            test_scenario::ctx(&mut scenario),
        );
        index::destroy_empty(idx);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EEdgeTooShort, location = mercator::polygon)]
    fun reshape_unclaimed_invalid_topology() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let polygon_id = register_square(&mut idx, 0, 0, 1_000_000, 1_000_000, &mut scenario);

        mutations::reshape_unclaimed(
            &mut idx,
            polygon_id,
            vector[vector[0u64, 4_000_000, 4_000_000, 0u64]],
            vector[vector[0u64, 0u64, 1u64, 1u64]],
            test_scenario::ctx(&mut scenario),
        );
        index::destroy_empty(idx);
        test_scenario::end(scenario);
    }

    #[test]
    /// After reshape widens the polygon across a quadtree cell boundary, the
    /// spatial index remains consistent: the reshaped polygon is still
    /// discoverable as a broadphase candidate for an adjacent region.
    /// Uses a shallow index (max_depth=6) to keep the broadphase fast.
    fun reshape_unclaimed_index_remains_consistent() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::with_config(
            1_000_000,
            6,
            64,
            10,
            1024,
            64,
            2_000_000,
            test_scenario::ctx(&mut scenario),
        );
        let polygon_id = register_square(&mut idx, 0, 0, 1_000_000, 1_000_000, &mut scenario);
        // Register an adjacent square just beyond the reshape target (3m mark).
        let neighbour_id = register_square(
            &mut idx,
            3_000_000,
            0,
            4_000_000,
            1_000_000,
            &mut scenario,
        );

        // Reshape to 3m×1m — AABB crosses a cell boundary; the region now
        // touches the neighbour.
        mutations::reshape_unclaimed(
            &mut idx,
            polygon_id,
            vector[square_xs(0, 3_000_000)],
            vector[square_ys(0, 1_000_000)],
            test_scenario::ctx(&mut scenario),
        );

        // The polygon is still retrievable after re-indexing.
        let _poly = index::get(&idx, polygon_id);

        // The neighbour's broadphase candidates must include the reshaped polygon.
        let cands = index::candidates(&idx, neighbour_id);
        let mut found = false;
        let mut i = 0;
        while (i < vector::length(&cands)) {
            if (*vector::borrow(&cands, i) == polygon_id) {
                found = true
            };
            i = i + 1;
        };
        assert!(found, 0);

        // Touching edge is not an overlap.
        assert!(vector::length(&index::overlapping(&idx, polygon_id)) == 0, 1);
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ENotContained, location = mercator::mutations)]
    /// Shrinking a polygon — even slightly — is forbidden.
    /// reshape_unclaimed requires the new AABB to contain the old AABB on every
    /// axis: new_min ≤ old_min AND new_max ≥ old_max.  Any reduction in any
    /// direction violates this and aborts with ENotContained.
    fun reshape_shrink_aborts() {
        let mut scenario = test_scenario::begin(ADMIN);
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let polygon_id = register_square(&mut idx, 0, 0, 2_000_000, 2_000_000, &mut scenario);

        // Attempt to shrink to 1m×1m — new_max_x (1m) < old_max_x (2m).
        mutations::reshape_unclaimed(
            &mut idx,
            polygon_id,
            vector[square_xs(0, 1_000_000)],
            vector[square_ys(0, 1_000_000)],
            test_scenario::ctx(&mut scenario),
        );
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ENotContained, location = mercator::mutations)]
    /// Shrinkage on one axis is forbidden even when the other axis expands.
    /// The AABB check is per-axis: each dimension must independently not shrink.
    /// A 2m-wide × 1m-tall polygon cannot be reshaped to 1m-wide × 2m-tall
    /// even though the area is the same — the x-axis shrinks.
    fun reshape_shrink_one_axis_aborts_even_when_other_expands() {
        let mut scenario = test_scenario::begin(ADMIN);
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let polygon_id = register_square(&mut idx, 0, 0, 2_000_000, 1_000_000, &mut scenario);

        // Attempt to swap dimensions: 1m-wide × 2m-tall (same area = 2m²).
        // new_max_x (1m) < old_max_x (2m) → ENotContained despite same area.
        mutations::reshape_unclaimed(
            &mut idx,
            polygon_id,
            vector[square_xs(0, 1_000_000)],
            vector[square_ys(0, 2_000_000)],
            test_scenario::ctx(&mut scenario),
        );
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    /// Reshaping to the identical geometry succeeds.
    /// This is the boundary case: no expansion and no shrinkage.
    /// It confirms that ENotContained is triggered by ANY reduction,
    /// not just cases where the new shape is strictly smaller.
    fun reshape_identical_geometry_succeeds() {
        let mut scenario = test_scenario::begin(ADMIN);
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let polygon_id = register_square(&mut idx, 0, 0, 1_000_000, 1_000_000, &mut scenario);
        let area_before = polygon::area(
            index::get(&idx, polygon_id),
        );

        // Reshape to the same geometry — AABB unchanged, shape unchanged.
        mutations::reshape_unclaimed(
            &mut idx,
            polygon_id,
            vector[square_xs(0, 1_000_000)],
            vector[square_ys(0, 1_000_000)],
            test_scenario::ctx(&mut scenario),
        );

        // Area and count unchanged — the operation is a legal no-op.
        assert!(polygon::area(index::get(&idx, polygon_id)) == area_before, 0);
        assert!(index::count(&idx) == 1, 1);

        index::remove(&mut idx, polygon_id, test_scenario::ctx(&mut scenario));
        index::destroy_empty(idx);
        test_scenario::end(scenario);
    }

    #[test]
    fun repartition_adjacent_happy() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let a_id = register_square(&mut idx, 0, 0, 1_000_000, 2_000_000, &mut scenario);
        let b_id = register_square(&mut idx, 1_000_000, 0, 2_000_000, 2_000_000, &mut scenario);

        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[square_xs(0, 2_000_000)],
            vector[square_ys(0, 1_000_000)],
            b_id,
            vector[square_xs(0, 2_000_000)],
            vector[square_ys(1_000_000, 2_000_000)],
            test_scenario::ctx(&mut scenario),
        );

        let a_after = index::get(&idx, a_id);
        let b_after = index::get(&idx, b_id);
        let a_area = polygon::area(a_after) as u128;
        let b_area = polygon::area(b_after) as u128;

        assert!(a_area == 2, 0);
        assert!(b_area == 2, 1);
        assert!(a_area + b_area == 4, 2);
        assert!(index::count(&idx) == 2, 3);
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    fun repartition_adjacent_area_conservation() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let a_id = register_square(&mut idx, 0, 0, 1_000_000, 2_000_000, &mut scenario);
        let b_id = register_square(&mut idx, 1_000_000, 0, 2_000_000, 2_000_000, &mut scenario);

        let old_sum =
            (polygon::area(index::get(&idx, a_id)) as u128)
        + (polygon::area(index::get(&idx, b_id)) as u128);

        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[square_xs(0, 2_000_000)],
            vector[square_ys(0, 1_000_000)],
            b_id,
            vector[square_xs(0, 2_000_000)],
            vector[square_ys(1_000_000, 2_000_000)],
            test_scenario::ctx(&mut scenario),
        );

        let new_sum =
            (polygon::area(index::get(&idx, a_id)) as u128)
        + (polygon::area(index::get(&idx, b_id)) as u128);
        assert!(old_sum == new_sum, 0);
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ENotAdjacent, location = mercator::mutations)]
    fun repartition_adjacent_not_adjacent() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let a_id = register_square(&mut idx, 0, 0, 1_000_000, 1_000_000, &mut scenario);
        let b_id = register_square(&mut idx, 3_000_000, 0, 4_000_000, 1_000_000, &mut scenario);

        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[square_xs(0, 2_000_000)],
            vector[square_ys(0, 1_000_000)],
            b_id,
            vector[square_xs(2_000_000, 4_000_000)],
            vector[square_ys(0, 1_000_000)],
            test_scenario::ctx(&mut scenario),
        );
        index::destroy_empty(idx);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ESelfRepartition, location = mercator::mutations)]
    fun repartition_adjacent_self_id() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let a_id = register_square(&mut idx, 0, 0, 1_000_000, 1_000_000, &mut scenario);

        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[square_xs(0, 1_000_000)],
            vector[square_ys(0, 1_000_000)],
            a_id,
            vector[square_xs(0, 1_000_000)],
            vector[square_ys(0, 1_000_000)],
            test_scenario::ctx(&mut scenario),
        );
        index::destroy_empty(idx);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EOverlap, location = mercator::mutations)]
    fun repartition_adjacent_result_overlap() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let a_id = register_square(&mut idx, 0, 0, 1_000_000, 2_000_000, &mut scenario);
        let b_id = register_square(&mut idx, 1_000_000, 0, 2_000_000, 2_000_000, &mut scenario);

        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[square_xs(0, 2_000_000)],
            vector[square_ys(0, 1_000_000)],
            b_id,
            vector[square_xs(1_000_000, 2_000_000)],
            vector[square_ys(0, 2_000_000)],
            test_scenario::ctx(&mut scenario),
        );
        index::destroy_empty(idx);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EEdgeTooShort, location = mercator::polygon)]
    fun repartition_adjacent_invalid_topology() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let a_id = register_square(&mut idx, 0, 0, 1_000_000, 1_000_000, &mut scenario);
        let b_id = register_square(&mut idx, 1_000_000, 0, 2_000_000, 1_000_000, &mut scenario);

        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[vector[0u64, 4_000_000, 4_000_000, 0u64]],
            vector[vector[0u64, 0u64, 1u64, 1u64]],
            b_id,
            vector[square_xs(1_000_000, 2_000_000)],
            vector[square_ys(0, 1_000_000)],
            test_scenario::ctx(&mut scenario),
        );
        index::destroy_empty(idx);
        test_scenario::end(scenario);
    }

    #[test]
    fun merge_keep_happy() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let keep_id = register_square(&mut idx, 0, 0, 1_000_000, 1_000_000, &mut scenario);
        let absorb_id = register_square(
            &mut idx,
            1_000_000,
            0,
            2_000_000,
            1_000_000,
            &mut scenario,
        );

        mutations::merge_keep(
            &mut idx,
            keep_id,
            absorb_id,
            vector[square_xs(0, 2_000_000)],
            vector[square_ys(0, 1_000_000)],
            test_scenario::ctx(&mut scenario),
        );

        assert!(index::count(&idx) == 1, 0);
        let keep_after = index::get(&idx, keep_id);
        assert!(polygon::area(keep_after) == 2, 1);
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    fun merge_keep_loser_removed_from_index() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let keep_id = register_square(&mut idx, 0, 0, 1_000_000, 1_000_000, &mut scenario);
        let absorb_id = register_square(
            &mut idx,
            1_000_000,
            0,
            2_000_000,
            1_000_000,
            &mut scenario,
        );

        mutations::merge_keep(
            &mut idx,
            keep_id,
            absorb_id,
            vector[square_xs(0, 2_000_000)],
            vector[square_ys(0, 1_000_000)],
            test_scenario::ctx(&mut scenario),
        );

        let keep_after = index::get(&idx, keep_id);
        assert!(polygon::area(keep_after) == 2, 0);
        assert!(index::count(&idx) == 1, 1);
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ENotFound, location = mercator::index)]
    fun merge_keep_loser_uid_not_found_after_merge() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let keep_id = register_square(&mut idx, 0, 0, 1_000_000, 1_000_000, &mut scenario);
        let absorb_id = register_square(
            &mut idx,
            1_000_000,
            0,
            2_000_000,
            1_000_000,
            &mut scenario,
        );

        mutations::merge_keep(
            &mut idx,
            keep_id,
            absorb_id,
            vector[square_xs(0, 2_000_000)],
            vector[square_ys(0, 1_000_000)],
            test_scenario::ctx(&mut scenario),
        );

        index::get(&idx, absorb_id); // aborts here — absorb_id was deleted
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    fun merge_keep_area_conservation() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let keep_id = register_square(&mut idx, 0, 0, 1_000_000, 2_000_000, &mut scenario);
        let absorb_id = register_square(
            &mut idx,
            1_000_000,
            0,
            2_000_000,
            2_000_000,
            &mut scenario,
        );

        let old_area_sum =
            (polygon::area(index::get(&idx, keep_id)) as u128)
        + (polygon::area(index::get(&idx, absorb_id)) as u128);

        mutations::merge_keep(
            &mut idx,
            keep_id,
            absorb_id,
            vector[square_xs(0, 2_000_000)],
            vector[square_ys(0, 2_000_000)],
            test_scenario::ctx(&mut scenario),
        );

        let merged_area = polygon::area(index::get(&idx, keep_id)) as u128;
        assert!(old_area_sum == merged_area, 0);
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ESelfMerge, location = mercator::mutations)]
    fun merge_keep_self_merge() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let keep_id = register_square(&mut idx, 0, 0, 1_000_000, 1_000_000, &mut scenario);

        mutations::merge_keep(
            &mut idx,
            keep_id,
            keep_id,
            vector[square_xs(0, 1_000_000)],
            vector[square_ys(0, 1_000_000)],
            test_scenario::ctx(&mut scenario),
        );
        index::destroy_empty(idx);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ENotAdjacent, location = mercator::mutations)]
    fun merge_keep_not_adjacent() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let keep_id = register_square(&mut idx, 0, 0, 1_000_000, 1_000_000, &mut scenario);
        let absorb_id = register_square(
            &mut idx,
            3_000_000,
            0,
            4_000_000,
            1_000_000,
            &mut scenario,
        );

        mutations::merge_keep(
            &mut idx,
            keep_id,
            absorb_id,
            vector[square_xs(0, 2_000_000)],
            vector[square_ys(0, 1_000_000)],
            test_scenario::ctx(&mut scenario),
        );
        index::destroy_empty(idx);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EOwnerMismatch, location = mercator::mutations)]
    fun merge_keep_different_owner() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let keep_id = register_square(&mut idx, 0, 0, 1_000_000, 1_000_000, &mut scenario);
        let absorb_id = register_square(
            &mut idx,
            1_000_000,
            0,
            2_000_000,
            1_000_000,
            &mut scenario,
        );

        index::transfer_ownership(&mut idx, absorb_id, USER, test_scenario::ctx(&mut scenario));

        mutations::merge_keep(
            &mut idx,
            keep_id,
            absorb_id,
            vector[square_xs(0, 2_000_000)],
            vector[square_ys(0, 1_000_000)],
            test_scenario::ctx(&mut scenario),
        );
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EEdgeTooShort, location = mercator::polygon)]
    fun merge_keep_invalid_merged_topology() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let keep_id = register_square(&mut idx, 0, 0, 1_000_000, 1_000_000, &mut scenario);
        let absorb_id = register_square(
            &mut idx,
            1_000_000,
            0,
            2_000_000,
            1_000_000,
            &mut scenario,
        );

        mutations::merge_keep(
            &mut idx,
            keep_id,
            absorb_id,
            vector[vector[0u64, 4_000_000, 4_000_000, 0u64]],
            vector[vector[0u64, 0u64, 1u64, 1u64]],
            test_scenario::ctx(&mut scenario),
        );
        index::destroy_empty(idx);
        test_scenario::end(scenario);
    }

    #[test]
    /// After merge the kept polygon's AABB grows to span both originals.
    /// The spatial index must reflect this: a region adjacent to the
    /// absorbed region's former right edge is still a broadphase candidate
    /// of the merged result.
    /// Uses a shallow index (max_depth=6) to keep the broadphase fast.
    fun merge_keep_index_reflects_new_footprint() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::with_config(
            1_000_000,
            6,
            64,
            10,
            1024,
            64,
            2_000_000,
            test_scenario::ctx(&mut scenario),
        );
        let keep_id = register_square(&mut idx, 0, 0, 1_000_000, 1_000_000, &mut scenario);
        let absorb_id = register_square(
            &mut idx,
            1_000_000,
            0,
            2_000_000,
            1_000_000,
            &mut scenario,
        );
        let neighbour_id = register_square(
            &mut idx,
            2_000_000,
            0,
            3_000_000,
            1_000_000,
            &mut scenario,
        );

        // Merge keep and absorb into a 2m×1m rectangle.
        mutations::merge_keep(
            &mut idx,
            keep_id,
            absorb_id,
            vector[square_xs(0, 2_000_000)],
            vector[square_ys(0, 1_000_000)],
            test_scenario::ctx(&mut scenario),
        );

        // Absorbed region is gone; merged region and neighbour remain.
        assert!(index::count(&idx) == 2, 0);
        let _merged = index::get(&idx, keep_id); // still retrievable

        // Neighbour's broadphase candidates must include the merged region
        // (the merged footprint now extends to the neighbour's left edge).
        let cands = index::candidates(&idx, neighbour_id);
        let mut found = false;
        let mut i = 0;
        while (i < vector::length(&cands)) {
            if (*vector::borrow(&cands, i) == keep_id) {
                found = true
            };
            i = i + 1;
        };
        assert!(found, 1);

        // Touching edge is not an overlap.
        assert!(vector::length(&index::overlapping(&idx, keep_id)) == 0, 2);
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    fun split_replace_happy() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let parent_id = register_square(&mut idx, 0, 0, 2_000_000, 2_000_000, &mut scenario);

        let child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[vector[square_xs(0, 1_000_000)], vector[square_xs(1_000_000, 2_000_000)]],
            vector[vector[square_ys(0, 2_000_000)], vector[square_ys(0, 2_000_000)]],
            test_scenario::ctx(&mut scenario),
        );

        assert!(vector::length(&child_ids) == 2, 0);
        assert!(index::count(&idx) == 2, 1);
        assert!(*vector::borrow(&child_ids, 0) != parent_id, 2);
        assert!(*vector::borrow(&child_ids, 1) != parent_id, 3);

        let c0 = index::get(
            &idx,
            *vector::borrow(&child_ids, 0),
        );
        let c1 = index::get(
            &idx,
            *vector::borrow(&child_ids, 1),
        );
        assert!(polygon::area(c0) as u128 + (polygon::area(c1) as u128) == 4, 4);
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    fun split_replace_original_removed_from_index() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let parent_id = register_square(&mut idx, 0, 0, 2_000_000, 2_000_000, &mut scenario);

        let child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[vector[square_xs(0, 1_000_000)], vector[square_xs(1_000_000, 2_000_000)]],
            vector[vector[square_ys(0, 2_000_000)], vector[square_ys(0, 2_000_000)]],
            test_scenario::ctx(&mut scenario),
        );

        assert!(vector::length(&child_ids) == 2, 0);
        assert!(index::count(&idx) == 2, 1);
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ENotFound, location = mercator::index)]
    fun split_replace_original_uid_not_found_after_split() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let parent_id = register_square(&mut idx, 0, 0, 2_000_000, 2_000_000, &mut scenario);

        mutations::split_replace(
            &mut idx,
            parent_id,
            vector[vector[square_xs(0, 1_000_000)], vector[square_xs(1_000_000, 2_000_000)]],
            vector[vector[square_ys(0, 2_000_000)], vector[square_ys(0, 2_000_000)]],
            test_scenario::ctx(&mut scenario),
        );

        index::get(&idx, parent_id); // aborts here — parent_id was deleted
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EAreaConservationViolation, location = mercator::polygon)]
    fun split_replace_area_conservation() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let parent_id = register_square(&mut idx, 0, 0, 2_000_000, 2_000_000, &mut scenario);

        let _child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[vector[square_xs(0, 1_000_000)], vector[square_xs(1_000_000, 2_000_000)]],
            vector[vector[square_ys(0, 1_000_000)], vector[square_ys(0, 2_000_000)]],
            test_scenario::ctx(&mut scenario),
        );
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    fun split_replace_children_owned() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let parent_id = register_square(&mut idx, 0, 0, 2_000_000, 2_000_000, &mut scenario);
        let parent_owner = polygon::owner(
            index::get(&idx, parent_id),
        );

        let child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[vector[square_xs(0, 1_000_000)], vector[square_xs(1_000_000, 2_000_000)]],
            vector[vector[square_ys(0, 2_000_000)], vector[square_ys(0, 2_000_000)]],
            test_scenario::ctx(&mut scenario),
        );

        let c0 = index::get(
            &idx,
            *vector::borrow(&child_ids, 0),
        );
        let c1 = index::get(
            &idx,
            *vector::borrow(&child_ids, 1),
        );
        assert!(polygon::owner(c0) == parent_owner, 0);
        assert!(polygon::owner(c1) == parent_owner, 1);
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ENotConvex, location = mercator::polygon)]
    fun split_replace_nonconvex_parts() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let parent_id = register_square(&mut idx, 0, 0, 2_000_000, 2_000_000, &mut scenario);

        let _child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[
                vector[vector[0u64, 2_000_000, 1_000_000, 2_000_000, 0u64]],
                vector[square_xs(1_000_000, 2_000_000)],
            ],
            vector[
                vector[vector[0u64, 0u64, 1_000_000, 2_000_000, 2_000_000]],
                vector[square_ys(0, 2_000_000)],
            ],
            test_scenario::ctx(&mut scenario),
        );
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EOverlap, location = mercator::mutations)]
    fun split_replace_children_overlap() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let parent_id = register_square(&mut idx, 0, 0, 2_000_000, 2_000_000, &mut scenario);

        let _child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[vector[square_xs(0, 1_000_000)], vector[square_xs(500_000, 1_500_000)]],
            vector[vector[square_ys(0, 2_000_000)], vector[square_ys(0, 2_000_000)]],
            test_scenario::ctx(&mut scenario),
        );
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    fun split_replace_returns_ids() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let parent_id = register_square(&mut idx, 0, 0, 2_000_000, 2_000_000, &mut scenario);

        let child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[vector[square_xs(0, 1_000_000)], vector[square_xs(1_000_000, 2_000_000)]],
            vector[vector[square_ys(0, 2_000_000)], vector[square_ys(0, 2_000_000)]],
            test_scenario::ctx(&mut scenario),
        );

        assert!(vector::length(&child_ids) == 2, 0);
        let left_id = *vector::borrow(&child_ids, 0);
        let right_id = *vector::borrow(&child_ids, 1);
        assert!(left_id != right_id, 1);
        let _left = index::get(&idx, left_id);
        let _right = index::get(&idx, right_id);
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    fun stage3_split_then_merge_roundtrip() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let parent_id = register_square(&mut idx, 0, 0, 2_000_000, 1_000_000, &mut scenario);

        let child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[vector[square_xs(0, 1_000_000)], vector[square_xs(1_000_000, 2_000_000)]],
            vector[vector[square_ys(0, 1_000_000)], vector[square_ys(0, 1_000_000)]],
            test_scenario::ctx(&mut scenario),
        );

        let keep_id = *vector::borrow(&child_ids, 0);
        let absorb_id = *vector::borrow(&child_ids, 1);

        mutations::merge_keep(
            &mut idx,
            keep_id,
            absorb_id,
            vector[square_xs(0, 2_000_000)],
            vector[square_ys(0, 1_000_000)],
            test_scenario::ctx(&mut scenario),
        );

        assert!(index::count(&idx) == 1, 0);
        assert!(polygon::area(index::get(&idx, keep_id)) == 2, 1);
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    fun stage3_merge_then_split_roundtrip() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::new(
            test_scenario::ctx(&mut scenario),
        );
        let keep_id = register_square(&mut idx, 0, 0, 1_000_000, 1_000_000, &mut scenario);
        let absorb_id = register_square(
            &mut idx,
            1_000_000,
            0,
            2_000_000,
            1_000_000,
            &mut scenario,
        );

        mutations::merge_keep(
            &mut idx,
            keep_id,
            absorb_id,
            vector[square_xs(0, 2_000_000)],
            vector[square_ys(0, 1_000_000)],
            test_scenario::ctx(&mut scenario),
        );

        let child_ids = mutations::split_replace(
            &mut idx,
            keep_id,
            vector[vector[square_xs(0, 1_000_000)], vector[square_xs(1_000_000, 2_000_000)]],
            vector[vector[square_ys(0, 1_000_000)], vector[square_ys(0, 1_000_000)]],
            test_scenario::ctx(&mut scenario),
        );

        assert!(index::count(&idx) == 2, 0);
        assert!(vector::length(&child_ids) == 2, 1);
        assert!(polygon::area(index::get(&idx, *vector::borrow(&child_ids, 0))) == 1, 2);
        assert!(polygon::area(index::get(&idx, *vector::borrow(&child_ids, 1))) == 1, 3);
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    #[test]
    /// Regression: reshape_unclaimed with a 2-part L-shaped new polygon must succeed
    /// when the old polygon is genuinely inside the L-shape.
    /// Previously failed with ENotContained due to integer truncation in edge sampling.
    fun reshape_unclaimed_non_convex_expansion_succeeds() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::with_config(
            1_000_000,
            2,
            16,
            4,
            1024,
            64,
            2_000_000,
            test_scenario::ctx(&mut scenario),
        );
        // It sits at [0, S] × [0, S] where S = 1_000_000.
        let polygon_id = register_square(&mut idx, 0, 0, 1_000_000, 1_000_000, &mut scenario);

        // Reshape to an L-shaped 2-part polygon that contains the old square.
        // Part 1 (bottom bar): [(0,0),(3S,0),(3S,S),(S,S),(0,S)] — 5 vertices with collinear bend
        // Part 2 (left column): [(0,S),(S,S),(S,2S),(0,2S)]
        // The old square [0,S]×[0,S] is inside Part 1.
        // Edge sampling of the old square's edges against the 2-part outer polygon
        // exercises the scaled arithmetic fix.
        mutations::reshape_unclaimed(
            &mut idx,
            polygon_id,
            vector[
                vector[0u64, 3_000_000, 3_000_000, 1_000_000, 0u64],
                vector[0u64, 1_000_000, 1_000_000, 0u64],
            ],
            vector[
                vector[0u64, 0u64, 1_000_000, 1_000_000, 1_000_000],
                vector[1_000_000, 1_000_000, 2_000_000, 2_000_000],
            ],
            test_scenario::ctx(&mut scenario),
        );

        // Verify the polygon was updated.
        let after = index::get(&idx, polygon_id);
        assert!(polygon::area(after) > 0, 0);

        index::remove(&mut idx, polygon_id, test_scenario::ctx(&mut scenario));
        index::destroy_empty(idx);
        test_scenario::end(scenario);
    }

    #[test]
    /// Regression: edge sampling where the t=1/3 sample lands exactly on the
    /// shared boundary between two outer parts (cross product = 0) must pass.
    /// Verifies that boundary points are correctly treated as "inside".
    fun edge_sampling_exact_boundary_point() {
        let mut scenario: Scenario = test_scenario::begin(
            ADMIN,
        );
        let mut idx = index::with_config(
            1_000_000,
            2,
            16,
            4,
            1024,
            64,
            2_000_000,
            test_scenario::ctx(&mut scenario),
        );
        let polygon_id = register_square(&mut idx, 0, 0, 1_000_000, 1_000_000, &mut scenario);

        // Reshape to the same L-shape.
        // The top edge of the old square goes from (1S,1S) to (0,1S).
        // t=1/3 sample: x=(2*1S+0)/3=2S/3, y=(2*1S+1S)/3=1S → exactly on the
        // shared boundary between Part 1 and Part 2 (y=1S).
        // With scaled arithmetic: t1x_scaled=2S, t1y_scaled=3S → cross product=0 (on boundary) → inside.
        mutations::reshape_unclaimed(
            &mut idx,
            polygon_id,
            vector[
                vector[0u64, 3_000_000, 3_000_000, 1_000_000, 0u64],
                vector[0u64, 1_000_000, 1_000_000, 0u64],
            ],
            vector[
                vector[0u64, 0u64, 1_000_000, 1_000_000, 1_000_000],
                vector[1_000_000, 1_000_000, 2_000_000, 2_000_000],
            ],
            test_scenario::ctx(&mut scenario),
        );

        let after = index::get(&idx, polygon_id);
        assert!(polygon::area(after) > 0, 0);

        index::remove(&mut idx, polygon_id, test_scenario::ctx(&mut scenario));
        index::destroy_empty(idx);
        test_scenario::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // F-01: split_replace — child teleportation outside parent bounds
    // ═════════════════════════════════════════════════════════════════════════════
    //
    // ATTACK: Owner splits a 2m×1m region at origin into two 1m×1m children,
    // but places the second child 10m away. Area is conserved, no overlap
    // with existing polygons, so the transaction succeeds — the attacker
    // now controls land they never paid for.
    //
    // EXPECTED BEHAVIOR: The protocol should reject children whose AABB
    // extends beyond the parent's AABB.

    #[test]
    #[expected_failure(abort_code = ENotContained, location = mercator::mutations)]
    /// F-01 PoC (FIXED): split_replace now rejects children outside parent bounds.
    /// Before fix: succeeded, teleporting child B 10m away.
    /// After fix: aborts with ENotContained (5001).
    fun f01_split_child_teleportation_outside_parent() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let parent_id = poc_register_square(&mut idx, 0, 0, 2 * SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 1);

        // ATTACK: Split into two 1m×1m children.
        // Child A stays at origin — legitimate.
        // Child B is placed 10m away — teleported!
        // → must abort with ENotContained
        let _child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[
                // Child A: [0, S] × [0, S]  — inside parent ✓
                vector[sq_xs(0, SCALE)],
                // Child B: [10S, 11S] × [0, S]  — OUTSIDE parent!
                vector[sq_xs(10 * SCALE, 11 * SCALE)],
            ],
            vector[vector[sq_ys(0, SCALE)], vector[sq_ys(0, SCALE)]],
            &mut ctx,
        );
        std::unit_test::destroy(idx);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // F-05: Protocol mutations lack ownership checks
    // ═════════════════════════════════════════════════════════════════════════════
    //
    // reshape_unclaimed and repartition_adjacent now reject non-owner calls.

    #[test]
    #[expected_failure(abort_code = EOwnerMismatch, location = mercator::mutations)]
    /// F-05 regression: a non-owner owner auth holder cannot reshape a region.
    fun f05_reshape_unclaimed_no_owner_check() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let transfer_cap = index::mint_transfer_cap_for_testing(&mut idx, &mut ctx);

        let s = SCALE;

        // Register polygon, then transfer it away so the caller is no longer owner.
        let id = poc_register_square(&mut idx, 0, 0, s, s, &mut ctx);
        index::force_transfer(&transfer_cap, &mut idx, id, @0xA77AC);

        mutations::reshape_unclaimed(
            &mut idx,
            id,
            vector[sq_xs(0, 2 * s)],
            vector[sq_ys(0, s)],
            &ctx,
        );
        std::unit_test::destroy(transfer_cap);
        std::unit_test::destroy(idx);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // F-05b: repartition_adjacent cross-owner land theft
    // ═════════════════════════════════════════════════════════════════════════════
    //
    // ATTACK: Attacker owns region B adjacent to victim's region A. Using a
    // owner auth, attacker calls repartition_adjacent to redraw the shared
    // boundary, shrinking victim's region and expanding their own.
    // No owner check → no payment needed → free land theft within union AABB.

    #[test]
    #[expected_failure(abort_code = EOwnerMismatch, location = mercator::mutations)]
    /// F-05b regression: repartition_adjacent rejects cross-owner boundary changes.
    fun f05b_repartition_cross_owner_land_theft() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let transfer_cap = index::mint_transfer_cap_for_testing(&mut idx, &mut ctx);

        let s = SCALE;

        // Victim owns A: [0,2S]×[0,S] — area = 2m²
        let a_id = poc_register_square(&mut idx, 0, 0, 2 * s, s, &mut ctx);
        // Attacker owns B: [2S,3S]×[0,S] — area = 1m²
        let b_id = poc_register_square(&mut idx, 2 * s, 0, 3 * s, s, &mut ctx);

        // Transfer B to attacker address (different from ctx sender @0x0)
        let attacker = @0xA77AC;
        index::force_transfer(&transfer_cap, &mut idx, b_id, attacker);
        assert!(polygon::owner(index::get(&idx, b_id)) == attacker);

        // Verify initial state
        let victim = polygon::owner(index::get(&idx, a_id));
        assert!(victim != attacker); // different owners
        assert!(polygon::area(index::get(&idx, a_id)) == 2); // victim has 2m²
        assert!(polygon::area(index::get(&idx, b_id)) == 1); // attacker has 1m²

        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[sq_xs(0, s)],
            vector[sq_ys(0, s)],
            b_id,
            vector[sq_xs(s, 3 * s)],
            vector[sq_ys(0, s)],
            &ctx,
        );
        std::unit_test::destroy(transfer_cap);
        std::unit_test::destroy(idx);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // F-18: split_replace with 1 child — polygon ID laundering — FIXED
    // ═════════════════════════════════════════════════════════════════════════════
    //
    // FIXED: assert!(child_count >= 2, EInvalidChildCount) now prevents 1-child splits.

    #[test]
    #[expected_failure(abort_code = EInvalidChildCount, location = mercator::mutations)]
    /// F-18 regression: split_replace must reject single-child "splits".
    fun f18_split_with_single_child_id_laundering() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let s = SCALE;
        let parent_id = poc_register_square(&mut idx, 0, 0, s, s, &mut ctx);
        let parent_area = polygon::area(index::get(&idx, parent_id));
        assert!(parent_area == 1);

        // "Split" into 1 child — same geometry as parent
        let _child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[vector[sq_xs(0, s)]],
            vector[vector[sq_ys(0, s)]],
            &mut ctx,
        );
        std::unit_test::destroy(idx);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // F-01: split_replace Does Not Verify Children Are Contained Within Parent
    // ═════════════════════════════════════════════════════════════════════════
    //
    // Covered in detail by audit_poc_tests::f01_split_child_teleportation_outside_parent.
    // Included here as a reference and to provide complete coverage from the
    // Security Audit Report.
    //
    // ATTACK: Owner splits a 2m² region at origin into two 1m² children,
    // placing child B 10m away. Area conserved, no overlaps → succeeds.
    // Child B claims land the owner never paid for.

    #[test]
    #[expected_failure(abort_code = ENotContained, location = mercator::mutations)]
    /// F-01 PoC (FIXED): split_replace now rejects children outside parent bounds.
    /// Before fix: succeeded, teleporting land 10m away.
    /// After fix: aborts with ENotContained (5001).
    fun f01_split_child_teleportation_reference() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let parent_id = poc_register_square(&mut idx, 0, 0, 2 * SCALE, SCALE, &mut ctx);

        // Split: child A at origin (inside parent), child B 10m away (outside)
        // → must abort with ENotContained because child B is outside parent
        let _child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[
                vector[sq_xs(0, SCALE)], // Child A: inside parent
                vector[sq_xs(10 * SCALE, 11 * SCALE)], // Child B: 10m away!
            ],
            vector[vector[sq_ys(0, SCALE)], vector[sq_ys(0, SCALE)]],
            &mut ctx,
        );
        std::unit_test::destroy(idx);
    }

    #[test]
    /// F-01 positive: legitimate split where all children are inside parent still works.
    fun f01_split_children_inside_parent_succeeds() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let parent_id = poc_register_square(&mut idx, 0, 0, 2 * SCALE, SCALE, &mut ctx);

        // Split into two 1m×1m children both inside parent
        let child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[vector[sq_xs(0, SCALE)], vector[sq_xs(SCALE, 2 * SCALE)]],
            vector[vector[sq_ys(0, SCALE)], vector[sq_ys(0, SCALE)]],
            &mut ctx,
        );

        assert!(vector::length(&child_ids) == 2);
        assert!(index::count(&idx) == 2);
        std::unit_test::destroy(idx);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // F-09: split_replace Has No Upper Bound on Child Count — Gas Griefing
    // ═════════════════════════════════════════════════════════════════════════
    //
    // split_replace asserts child_count >= 2 but has no upper bound.
    // Pairwise overlap check is O(C² × P² × V²). With many children, the
    // SAT computation can exceed gas limits. An attacker can calibrate
    // child_count to maximize compute load on the shared Index object.
    //
    // Recommendation: MAX_SPLIT_CHILDREN = 10.

    #[test]
    #[expected_failure(abort_code = 5008, location = mercator::mutations)]
    /// F-09 PoC (FIXED): 20 children now rejected by MAX_SPLIT_CHILDREN = 10.
    /// Before fix: succeeded with 20 children (gas griefing vector).
    /// After fix: aborts with 5008.
    fun f09_unbounded_split_child_count() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(SCALE, 6, 64, 20, 1024, 64, 2_000_000, &mut ctx);
        let parent_id = poc_register_square(&mut idx, 0, 0, 20 * SCALE, SCALE, &mut ctx);

        // Build 20 children → exceeds MAX_SPLIT_CHILDREN (10)
        let mut all_xs = vector[];
        let mut all_ys = vector[];
        let mut i = 0u64;
        while (i < 20) {
            vector::push_back(&mut all_xs, vector[sq_xs(i * SCALE, (i + 1) * SCALE)]);
            vector::push_back(&mut all_ys, vector[sq_ys(0, SCALE)]);
            i = i + 1;
        };

        let _child_ids = mutations::split_replace(&mut idx, parent_id, all_xs, all_ys, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = 5008, location = mercator::mutations)]
    /// F-09b (FIXED): 15 children also rejected (> 10).
    fun f09b_fifteen_children_split() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(SCALE, 6, 64, 20, 1024, 64, 2_000_000, &mut ctx);
        let parent_id = poc_register_square(&mut idx, 0, 0, 15 * SCALE, SCALE, &mut ctx);

        let mut all_xs = vector[];
        let mut all_ys = vector[];
        let mut i = 0u64;
        while (i < 15) {
            vector::push_back(&mut all_xs, vector[sq_xs(i * SCALE, (i + 1) * SCALE)]);
            vector::push_back(&mut all_ys, vector[sq_ys(0, SCALE)]);
            i = i + 1;
        };

        let _child_ids = mutations::split_replace(&mut idx, parent_id, all_xs, all_ys, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// F-09 positive: splitting into exactly 10 children (the limit) still works.
    fun f09_ten_children_at_limit_succeeds() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(SCALE, 6, 64, 20, 1024, 64, 2_000_000, &mut ctx);
        let parent_id = poc_register_square(&mut idx, 0, 0, 10 * SCALE, SCALE, &mut ctx);

        let mut all_xs = vector[];
        let mut all_ys = vector[];
        let mut i = 0u64;
        while (i < 10) {
            vector::push_back(&mut all_xs, vector[sq_xs(i * SCALE, (i + 1) * SCALE)]);
            vector::push_back(&mut all_ys, vector[sq_ys(0, SCALE)]);
            i = i + 1;
        };

        let child_ids = mutations::split_replace(&mut idx, parent_id, all_xs, all_ys, &mut ctx);

        assert!(vector::length(&child_ids) == 10);
        assert!(index::count(&idx) == 10);
        std::unit_test::destroy(idx);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // CORE-01: reshape_unclaimed Rejects Area Shrinkage
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = ENotContained, location = mercator::mutations)]
    /// CORE-01: reshape_unclaimed rejects shrinkage. The containment check
    /// (ENotContained 5001) fires first since smaller geometry can't contain
    /// the original. EAreaShrunk (5009) is defense-in-depth for edge cases.
    fun core01_reshape_unclaimed_rejects_shrinkage() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = poc_register_square(&mut idx, 0, 0, 2 * SCALE, 2 * SCALE, &mut ctx);
        assert!(polygon::area(index::get(&idx, id)) == 4);

        // Reshape to 1m×1m = 1m² — fails containment (new doesn't contain old)
        mutations::reshape_unclaimed(
            &mut idx,
            id,
            vector[sq_xs(0, SCALE)],
            vector[sq_ys(0, SCALE)],
            &ctx,
        );
        std::unit_test::destroy(idx);
    }

    #[test]
    /// CORE-01 positive: reshape_unclaimed allows area growth.
    fun core01_reshape_unclaimed_allows_expansion() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = poc_register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        assert!(polygon::area(index::get(&idx, id)) == 1);

        // Reshape to 2m×2m = 4m² — expansion allowed
        mutations::reshape_unclaimed(
            &mut idx,
            id,
            vector[sq_xs(0, 2 * SCALE)],
            vector[sq_ys(0, 2 * SCALE)],
            &ctx,
        );
        assert!(polygon::area(index::get(&idx, id)) == 4);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// GEO-01 PoC: reshape_unclaimed accepts a geometry with different exact fp2
    /// area as long as whole-meter area stays unchanged after truncation.
    fun geo01_reshape_unclaimed_ignores_sub_meter_area_delta() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(
            SCALE,
            8,
            64,
            10,
            1024,
            64,
            2_000_000,
            &mut ctx,
        );
        let id = poc_register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        assert!(polygon::area(index::get(&idx, id)) == 1, 0);

        // Expand by 1 raw unit in x. Exact fp2 area changes, but truncated whole
        // square-meter area remains 1, so reshape_unclaimed succeeds.
        mutations::reshape_unclaimed(
            &mut idx,
            id,
            vector[vector[0, SCALE + 1, SCALE + 1, 0]],
            vector[vector[0, 0, SCALE, SCALE]],
            &ctx,
        );

        let reshaped = index::get(&idx, id);
        assert!(polygon::area(reshaped) == 1, 1);
        assert!(aabb::max_x(&polygon::bounds(reshaped)) == SCALE + 1, 2);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = ENotContained, location = mercator::mutations)]
    fun repartition_teleport_outside_union_bounds_rejected() {
        let mut scenario = test_scenario::begin(ADMIN);
        let mut idx = index::new(test_scenario::ctx(&mut scenario));
        let a_id = register_rect_in_scenario(&mut idx, 0, 0, 2 * SCALE, SCALE, &mut scenario);
        let b_id = register_rect_in_scenario(
            &mut idx,
            2 * SCALE,
            0,
            4 * SCALE,
            SCALE,
            &mut scenario,
        );

        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[rect_xs(0, SCALE)],
            vector[rect_ys(0, SCALE)],
            b_id,
            vector[rect_xs(5 * SCALE, 8 * SCALE)],
            vector[rect_ys(0, SCALE)],
            test_scenario::ctx(&mut scenario),
        );
        index::destroy_empty(idx);
        test_scenario::end(scenario);
    }

    #[test]
    fun repartition_within_union_bounds_succeeds() {
        let mut scenario = test_scenario::begin(ADMIN);
        let mut idx = index::new(test_scenario::ctx(&mut scenario));
        let a_id = register_rect_in_scenario(&mut idx, 0, 0, 2 * SCALE, SCALE, &mut scenario);
        let b_id = register_rect_in_scenario(
            &mut idx,
            2 * SCALE,
            0,
            4 * SCALE,
            SCALE,
            &mut scenario,
        );

        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[rect_xs(0, 3 * SCALE)],
            vector[rect_ys(0, SCALE)],
            b_id,
            vector[rect_xs(3 * SCALE, 4 * SCALE)],
            vector[rect_ys(0, SCALE)],
            test_scenario::ctx(&mut scenario),
        );

        let a_after = index::get(&idx, a_id);
        let b_after = index::get(&idx, b_id);
        let a_bounds = polygon::bounds(a_after);
        let b_bounds = polygon::bounds(b_after);

        assert!(polygon::area(a_after) == 3, 0);
        assert!(polygon::area(b_after) == 1, 1);
        assert!(polygon::area(a_after) + polygon::area(b_after) == 4, 2);
        assert!(aabb::min_x(&a_bounds) == 0, 3);
        assert!(aabb::max_x(&a_bounds) == 3 * SCALE, 4);
        assert!(aabb::min_x(&b_bounds) == 3 * SCALE, 5);
        assert!(aabb::max_x(&b_bounds) == 4 * SCALE, 6);
        assert!(index::count(&idx) == 2, 7);
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }
}
