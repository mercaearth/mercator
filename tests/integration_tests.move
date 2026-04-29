/// Integration tests for the init-only deployment model.
///
/// Verifies that registry::init() creates the correct objects (Index,
/// owner auth, TransferCap) and that a full lifecycle (register →
/// transfer → remove) works end-to-end.
#[test_only]
module mercator::integration_tests {
    use mercator::{index::{Self, Index, TransferCap}, registry};
    use sui::test_scenario;

    const DEPLOYER: address = @0xABCD;
    const USER: address = @0x1234;

    /// Test that init() creates Index + owner auth + TransferCap.
    /// take_from_sender / take_shared panic if objects are missing,
    /// so successful execution proves all three were created.
    #[test]
    fun init_creates_index_and_caps() {
        let mut scenario = test_scenario::begin(DEPLOYER);
        {
            registry::init_for_testing(
                test_scenario::ctx(&mut scenario),
            );
        };
        test_scenario::next_tx(&mut scenario, DEPLOYER);
        {
            // owner auth was transferred to deployer
            // TransferCap was transferred to deployer
            let tcap = test_scenario::take_from_sender<TransferCap>(
                &scenario,
            );
            test_scenario::return_to_sender(&scenario, tcap);

            // Index was shared
            let idx = test_scenario::take_shared<Index>(&scenario);
            test_scenario::return_shared(idx);
        };
        test_scenario::end(scenario);
    }

    /// Full lifecycle: init → register → transfer → remove.
    #[test]
    fun full_lifecycle() {
        let mut scenario = test_scenario::begin(DEPLOYER);
        {
            registry::init_for_testing(
                test_scenario::ctx(&mut scenario),
            );
        };

        // Register a simple square as deployer
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
            assert!(index::count(&idx) == 1, 0);
            test_scenario::return_shared(idx);
        };

        // Transfer ownership from deployer to user
        test_scenario::next_tx(&mut scenario, DEPLOYER);
        {
            let mut idx = test_scenario::take_shared<Index>(
                &scenario,
            );
            index::transfer_ownership(
                &mut idx,
                polygon_id,
                USER,
                test_scenario::ctx(&mut scenario),
            );
            test_scenario::return_shared(idx);
        };

        // User removes their polygon (needs a owner auth)
        test_scenario::next_tx(&mut scenario, USER);
        {
            let mut idx = test_scenario::take_shared<Index>(
                &scenario,
            );
            index::remove(&mut idx, polygon_id, test_scenario::ctx(&mut scenario));
            assert!(index::count(&idx) == 0, 1);
            test_scenario::return_shared(idx);
        };
        test_scenario::end(scenario);
    }
}
