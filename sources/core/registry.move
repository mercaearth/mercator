/// Package initializer — init-only model.
/// On deploy, creates a shared Index and transfers TransferCap to the deployer.
/// No governance. Fork and customize as needed.
module mercator::registry {
    use mercator::index;

    /// Called once at package publish time.
    /// Creates a shared Index and transfers TransferCap to the deployer.
    fun init(ctx: &mut tx_context::TxContext) {
        let index = index::new(ctx);
        let transfer_cap = index::mint_transfer_cap(&index, ctx);
        index::share_existing(index);
        transfer::public_transfer(transfer_cap, tx_context::sender(ctx));
    }

    /// Test-only wrapper so tests can call init() directly.
    #[test_only]
    public fun init_for_testing(ctx: &mut tx_context::TxContext) {
        init(ctx);
    }
}
