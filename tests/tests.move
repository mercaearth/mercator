/// Integration tests for canonical shared Index behavior.
/// Adapted for the init-only model (no admin module).
#[test_only]
module mercator::tests {
    use mercator::index::{Self, ENotOwner, EOverlap, Index};
    use sui::test_scenario::{Self, Scenario};

    const DEPLOYER: address = @0xCAFE;
    const USER: address = @0xBEEF;

    fun vector_contains(v: &vector<ID>, id: ID): bool {
        let mut i = 0;
        while (i < vector::length(v)) {
            if (*vector::borrow(v, i) == id) {
                return true
            };
            i = i + 1;
        };
        false
    }

    /// Helper: create a shared Index directly (no admin module).
    fun create_shared_index(ctx: &mut tx_context::TxContext) {
        let index = index::with_config(
            1_000_000,
            20,
            64,
            10,
            1024,
            64,
            2_000_000,
            ctx,
        );
        index::share_existing(index);
    }

    #[test]
    fun spatial_index_is_shared() {
        let mut scenario: Scenario = test_scenario::begin(
            DEPLOYER,
        );
        {
            create_shared_index(
                test_scenario::ctx(&mut scenario),
            );
        };
        test_scenario::next_tx(&mut scenario, DEPLOYER);
        {
            let idx = test_scenario::take_shared<Index>(
                &scenario,
            );
            test_scenario::return_shared(idx);
        };
        test_scenario::end(scenario);
    }

    #[test]
    fun register_inserts_polygon() {
        let mut scenario: Scenario = test_scenario::begin(
            DEPLOYER,
        );
        {
            create_shared_index(
                test_scenario::ctx(&mut scenario),
            );
        };
        test_scenario::next_tx(&mut scenario, DEPLOYER);
        {
            let mut idx = test_scenario::take_shared<Index>(
                &scenario,
            );
            let id = index::register(
                &mut idx,
                vector[vector[0u64, 1_000_000u64, 1_000_000u64, 0u64]],
                vector[vector[0u64, 0u64, 1_000_000u64, 1_000_000u64]],
                test_scenario::ctx(&mut scenario),
            );
            assert!(index::count(&idx) == 1, 0);
            let _poly = index::get(&idx, id);
            test_scenario::return_shared(idx);
        };
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EOverlap)]
    fun overlap_is_rejected() {
        let mut scenario: Scenario = test_scenario::begin(
            DEPLOYER,
        );
        {
            create_shared_index(
                test_scenario::ctx(&mut scenario),
            );
        };
        test_scenario::next_tx(&mut scenario, DEPLOYER);
        {
            let mut idx = test_scenario::take_shared<Index>(
                &scenario,
            );
            let _id_a = index::register(
                &mut idx,
                vector[vector[0u64, 2_000_000u64, 2_000_000u64, 0u64]],
                vector[vector[0u64, 0u64, 2_000_000u64, 2_000_000u64]],
                test_scenario::ctx(&mut scenario),
            );
            let _id_b = index::register(
                &mut idx,
                vector[vector[1_000_000u64, 3_000_000u64, 3_000_000u64, 1_000_000u64]],
                vector[vector[1_000_000u64, 1_000_000u64, 3_000_000u64, 3_000_000u64]],
                test_scenario::ctx(&mut scenario),
            );
            test_scenario::return_shared(idx);
        };
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ENotOwner)]
    fun non_owner_remove_is_rejected() {
        let mut scenario: Scenario = test_scenario::begin(
            DEPLOYER,
        );
        {
            create_shared_index(
                test_scenario::ctx(&mut scenario),
            );
        };

        let polygon_id: ID;
        test_scenario::next_tx(&mut scenario, DEPLOYER);
        {
            let mut idx = test_scenario::take_shared<Index>(
                &scenario,
            );
            polygon_id =
                index::register(
                    &mut idx,
                    vector[vector[0u64, 1_000_000u64, 1_000_000u64, 0u64]],
                    vector[vector[0u64, 0u64, 1_000_000u64, 1_000_000u64]],
                    test_scenario::ctx(&mut scenario),
                );
            test_scenario::return_shared(idx);
        };

        test_scenario::next_tx(&mut scenario, USER);
        {
            let mut idx = test_scenario::take_shared<Index>(
                &scenario,
            );
            index::remove(&mut idx, polygon_id, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(idx);
        };
        test_scenario::end(scenario);
    }

    #[test]
    fun broadphase_candidates_include_neighbor() {
        let mut scenario: Scenario = test_scenario::begin(
            DEPLOYER,
        );
        {
            create_shared_index(
                test_scenario::ctx(&mut scenario),
            );
        };

        let id_a: ID;
        let id_b: ID;
        test_scenario::next_tx(&mut scenario, DEPLOYER);
        {
            let mut idx = test_scenario::take_shared<Index>(
                &scenario,
            );
            id_a =
                index::register(
                    &mut idx,
                    vector[vector[0u64, 1_000_000u64, 1_000_000u64, 0u64]],
                    vector[vector[0u64, 0u64, 1_000_000u64, 1_000_000u64]],
                    test_scenario::ctx(&mut scenario),
                );
            id_b =
                index::register(
                    &mut idx,
                    vector[vector[1_000_000u64, 2_000_000u64, 2_000_000u64, 1_000_000u64]],
                    vector[vector[0u64, 0u64, 1_000_000u64, 1_000_000u64]],
                    test_scenario::ctx(&mut scenario),
                );
            test_scenario::return_shared(idx);
        };

        test_scenario::next_tx(&mut scenario, USER);
        {
            let idx = test_scenario::take_shared<Index>(
                &scenario,
            );
            let candidates = index::candidates(&idx, id_a);
            assert!(vector_contains(&candidates, id_b), 0);
            test_scenario::return_shared(idx);
        };
        test_scenario::end(scenario);
    }

    #[test]
    fun geometry_setters_roundtrip() {
        use mercator::polygon::{Self};
        use mercator::aabb;

        let mut scenario: Scenario = test_scenario::begin(
            DEPLOYER,
        );
        {
            let ctx = test_scenario::ctx(&mut scenario);

            // Create initial 1-part polygon: 1m x 1m square at origin
            let part1 = polygon::part(
                vector[0u64, 1_000_000u64, 1_000_000u64, 0u64],
                vector[0u64, 0u64, 1_000_000u64, 1_000_000u64],
            );
            let mut poly = polygon::new(
                vector[part1],
                ctx,
            );

            // Verify initial state: 1 part, 4 vertices
            assert!(polygon::parts(&poly) == 1, 0);
            assert!(polygon::vertices(&poly) == 4, 0);

            // Create 2 new parts: two 1m x 1m squares
            let part_a = polygon::part(
                vector[0u64, 1_000_000u64, 1_000_000u64, 0u64],
                vector[0u64, 0u64, 1_000_000u64, 1_000_000u64],
            );
            let part_b = polygon::part(
                vector[2_000_000u64, 3_000_000u64, 3_000_000u64, 2_000_000u64],
                vector[0u64, 0u64, 1_000_000u64, 1_000_000u64],
            );

            // Call set_parts with 2 parts
            polygon::set_parts(
                &mut poly,
                vector[part_a, part_b],
            );

            // Verify updated state: 2 parts, 8 vertices
            assert!(polygon::parts(&poly) == 2, 0);
            assert!(polygon::vertices(&poly) == 8, 0);

            // Verify bounds encompass both parts
            let bounds = polygon::bounds(&poly);
            assert!(aabb::min_x(&bounds) == 0u64, 0);
            assert!(aabb::min_y(&bounds) == 0u64, 0);
            assert!(aabb::max_x(&bounds) == 3_000_000u64, 0);
            assert!(aabb::max_y(&bounds) == 1_000_000u64, 0);

            // Destroy polygon to clean up
            polygon::destroy(poly);
        };
        test_scenario::end(scenario);
    }
}
