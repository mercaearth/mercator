/// Tests for mercator::metadata — string metadata ownership-gated by region owner.
#[test_only, allow(unused_variable, duplicate_alias, unused_function)]
module mercator::metadata_tests {
    use mercator::{index::{Self, Index}, metadata, mutations};
    use std::string;
    use sui::{object, test_scenario, tx_context};

    const ADMIN: address = @0xCAFE;
    const USER: address = @0xBEEF;
    const OTHER: address = @0xC0FFEE;
    const SCALE: u64 = 1_000_000;

    fun test_index(ctx: &mut tx_context::TxContext): Index {
        index::with_config(SCALE, 6, 64, 10, 1024, 64, 2_000_000, ctx)
    }

    fun register_square(
        idx: &mut Index,
        x0: u64,
        y0: u64,
        x1: u64,
        y1: u64,
        ctx: &mut tx_context::TxContext,
    ): object::ID {
        index::register(idx, vector[vector[x0, x1, x1, x0]], vector[vector[y0, y0, y1, y1]], ctx)
    }

    #[test]
    fun set_metadata_new() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);

        metadata::set_metadata(&mut idx, id, string::utf8(b"QmTestCid123"), &ctx);

        assert!(metadata::has_metadata(&idx, id), 0);
        let (value, _epoch) = metadata::get_metadata(&idx, id);
        assert!(value == string::utf8(b"QmTestCid123"), 1);
        std::unit_test::destroy(idx);
    }

    #[test]
    fun set_metadata_overwrite() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);

        metadata::set_metadata(&mut idx, id, string::utf8(b"QmFirst"), &ctx);
        metadata::set_metadata(&mut idx, id, string::utf8(b"QmSecond"), &ctx);

        let (value, _epoch) = metadata::get_metadata(&idx, id);
        assert!(value == string::utf8(b"QmSecond"), 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = mercator::metadata::ENotOwner)]
    fun set_metadata_not_owner_rejected() {
        let mut scenario = test_scenario::begin(ADMIN);
        let polygon_id: object::ID;
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let mut idx = test_index(ctx);
            polygon_id = register_square(&mut idx, 0, 0, SCALE, SCALE, ctx);
            index::share_existing(idx);
        };
        test_scenario::next_tx(&mut scenario, OTHER);
        {
            let mut idx = test_scenario::take_shared<Index>(&scenario);
            metadata::set_metadata(
                &mut idx,
                polygon_id,
                string::utf8(b"QmHack"),
                test_scenario::ctx(&mut scenario),
            );
            test_scenario::return_shared(idx);
        };
        test_scenario::end(scenario);
    }

    #[test]
    fun remove_metadata_succeeds() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);

        metadata::set_metadata(&mut idx, id, string::utf8(b"QmToRemove"), &ctx);
        assert!(metadata::has_metadata(&idx, id), 0);

        metadata::remove_metadata(&mut idx, id, &ctx);
        assert!(!metadata::has_metadata(&idx, id), 1);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = mercator::metadata::EMetadataNotFound)]
    fun remove_metadata_not_found() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);

        metadata::remove_metadata(&mut idx, id, &ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = mercator::metadata::EMetadataNotFound)]
    fun get_metadata_not_found() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);

        let (_value, _epoch) = metadata::get_metadata(&idx, id);
        std::unit_test::destroy(idx);
    }

    #[test]
    fun ptb_register_then_set_metadata() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        metadata::set_metadata(&mut idx, id, string::utf8(b"QmPTBCid"), &ctx);

        assert!(metadata::has_metadata(&idx, id), 0);
        let (value, _epoch) = metadata::get_metadata(&idx, id);
        assert!(value == string::utf8(b"QmPTBCid"), 1);
        std::unit_test::destroy(idx);
    }

    #[test]
    fun new_owner_can_update_after_transfer() {
        let mut scenario = test_scenario::begin(ADMIN);
        let polygon_id: object::ID;
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let mut idx = test_index(ctx);
            polygon_id = register_square(&mut idx, 0, 0, SCALE, SCALE, ctx);
            metadata::set_metadata(&mut idx, polygon_id, string::utf8(b"QmOriginal"), ctx);
            index::transfer_ownership(&mut idx, polygon_id, USER, ctx);
            index::share_existing(idx);
        };
        test_scenario::next_tx(&mut scenario, USER);
        {
            let mut idx = test_scenario::take_shared<Index>(&scenario);
            metadata::set_metadata(
                &mut idx,
                polygon_id,
                string::utf8(b"QmUpdated"),
                test_scenario::ctx(&mut scenario),
            );
            let (value, _epoch) = metadata::get_metadata(&idx, polygon_id);
            assert!(value == string::utf8(b"QmUpdated"), 0);
            test_scenario::return_shared(idx);
        };
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = mercator::metadata::ENotOwner)]
    fun old_owner_rejected_after_transfer() {
        let mut scenario = test_scenario::begin(ADMIN);
        let polygon_id: object::ID;
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let mut idx = test_index(ctx);
            polygon_id = register_square(&mut idx, 0, 0, SCALE, SCALE, ctx);
            index::transfer_ownership(&mut idx, polygon_id, USER, ctx);
            index::share_existing(idx);
        };
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut idx = test_scenario::take_shared<Index>(&scenario);
            metadata::set_metadata(
                &mut idx,
                polygon_id,
                string::utf8(b"QmOldOwner"),
                test_scenario::ctx(&mut scenario),
            );
            test_scenario::return_shared(idx);
        };
        test_scenario::end(scenario);
    }

    // ========================================================================
    // META-01 regression tests: metadata cleanup on polygon destruction
    // ========================================================================

    /// Helper: register two adjacent 1×1 squares at (0,0)-(S,S) and (S,0)-(2S,S).
    fun register_adjacent_pair(
        idx: &mut Index,
        ctx: &mut tx_context::TxContext,
    ): (object::ID, object::ID) {
        let left = register_square(idx, 0, 0, SCALE, SCALE, ctx);
        let right = register_square(idx, SCALE, 0, 2 * SCALE, SCALE, ctx);
        (left, right)
    }

    /// mutations::remove_polygon cleans up metadata (covers index::remove path).
    #[test]
    fun remove_polygon_cleans_metadata() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);

        metadata::set_metadata(&mut idx, id, string::utf8(b"QmWillBeRemoved"), &ctx);
        assert!(metadata::has_metadata(&idx, id), 0);

        mutations::remove_polygon(&mut idx, id, &mut ctx);
        // Metadata must be gone — no orphaned dynamic field
        assert!(!metadata::has_metadata(&idx, id), 1);
        std::unit_test::destroy(idx);
    }

    /// mutations::remove_polygon on a polygon WITHOUT metadata does not abort.
    #[test]
    fun remove_polygon_without_metadata_succeeds() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);

        assert!(!metadata::has_metadata(&idx, id), 0);
        mutations::remove_polygon(&mut idx, id, &mut ctx);
        // No abort — force_remove_metadata is a no-op when metadata absent
        std::unit_test::destroy(idx);
    }

    /// merge_keep cleans up metadata on the absorbed polygon; keeper metadata survives.
    #[test]
    fun merge_keep_cleans_absorbed_metadata() {
        let mut scenario = test_scenario::begin(ADMIN);
        let mut idx = index::new(test_scenario::ctx(&mut scenario));
        let (keep_id, absorb_id) = register_adjacent_pair(
            &mut idx,
            test_scenario::ctx(&mut scenario),
        );

        // Set metadata on both polygons
        let ctx = test_scenario::ctx(&mut scenario);
        metadata::set_metadata(&mut idx, keep_id, string::utf8(b"QmKeep"), ctx);
        metadata::set_metadata(&mut idx, absorb_id, string::utf8(b"QmAbsorb"), ctx);
        assert!(metadata::has_metadata(&idx, keep_id), 0);
        assert!(metadata::has_metadata(&idx, absorb_id), 1);

        // Merged shape: [0, 2S] × [0, S]
        mutations::merge_keep(
            &mut idx,
            keep_id,
            absorb_id,
            vector[vector[0, 2 * SCALE, 2 * SCALE, 0]],
            vector[vector[0, 0, SCALE, SCALE]],
            test_scenario::ctx(&mut scenario),
        );

        // Absorbed metadata cleaned up, keeper metadata survives
        assert!(metadata::has_metadata(&idx, keep_id), 2);
        assert!(!metadata::has_metadata(&idx, absorb_id), 3);
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    /// split_replace cleans up metadata on the parent polygon.
    #[test]
    fun split_replace_cleans_parent_metadata() {
        let mut scenario = test_scenario::begin(ADMIN);
        let mut idx = test_index(test_scenario::ctx(&mut scenario));
        let parent_id = index::register(
            &mut idx,
            vector[vector[0, 2 * SCALE, 2 * SCALE, 0]],
            vector[vector[0, 0, 2 * SCALE, 2 * SCALE]],
            test_scenario::ctx(&mut scenario),
        );

        let ctx = test_scenario::ctx(&mut scenario);
        metadata::set_metadata(&mut idx, parent_id, string::utf8(b"QmParent"), ctx);
        assert!(metadata::has_metadata(&idx, parent_id), 0);

        // Split into two 1×2 children
        let child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[
                vector[vector[0, SCALE, SCALE, 0]],
                vector[vector[SCALE, 2 * SCALE, 2 * SCALE, SCALE]],
            ],
            vector[
                vector[vector[0, 0, 2 * SCALE, 2 * SCALE]],
                vector[vector[0, 0, 2 * SCALE, 2 * SCALE]],
            ],
            test_scenario::ctx(&mut scenario),
        );

        // Parent metadata cleaned up
        assert!(!metadata::has_metadata(&idx, parent_id), 1);
        // Children have no metadata (fresh polygons)
        assert!(!metadata::has_metadata(&idx, *vector::borrow(&child_ids, 0)), 2);
        assert!(!metadata::has_metadata(&idx, *vector::borrow(&child_ids, 1)), 3);
        std::unit_test::destroy(idx);
        test_scenario::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // F-06: Dynamic field orphaning — FIXED
    // ═════════════════════════════════════════════════════════════════════════════
    //
    // FIXED: index::remove_unchecked() now calls metadata_store::force_remove_metadata().
    // Metadata is properly cleaned up when index::remove() is called directly.

    #[test]
    /// F-06 regression: direct `index::remove()` must clean metadata too.
    fun f06_metadata_orphaned_after_direct_remove() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let s = SCALE;

        // 1. Register polygon and set metadata
        let id = register_square(&mut idx, 0, 0, s, s, &mut ctx);
        metadata::set_metadata(
            &mut idx,
            id,
            std::string::utf8(b"QmTestCID12345"),
            &ctx,
        );
        assert!(metadata::has_metadata(&idx, id) == true);

        // 2. Remove polygon via index::remove() — NOT mutations::remove_polygon()
        //    index::remove does NOT call force_remove_metadata
        index::remove(&mut idx, id, &mut ctx);

        // 3. Polygon is gone
        assert!(index::count(&idx) == 0);

        // 4. Metadata is now cleaned up inside index::remove_unchecked().
        assert!(!metadata::has_metadata(&idx, id));
        std::unit_test::destroy(idx);
    }
}
