/// Per-region metadata storage for the spatial index.
/// Stores an arbitrary string value (URL, JSON reference, label, etc.)
/// per region, keyed by polygon ID. Metadata is a Sui dynamic field on the Index.
module mercator::metadata {
    use mercator::{index, metadata_store, polygon};
    use std::string::String;
    use sui::event;

    // === Errors ===

    const ENotOwner: u64 = 6000;
    const EMetadataNotFound: u64 = 6001;
    const EValueTooLong: u64 = 6002;

    /// Max metadata value length in bytes. Prevents unbounded storage per region.
    const MAX_VALUE_LENGTH: u64 = 128;

    // === Structs ===

    // === Events ===

    /// Emitted when metadata is set or updated on a region.
    public struct MetadataSet has copy, drop {
        polygon_id: ID,
        owner: address,
        value: String,
        epoch: u64,
    }

    /// Emitted when metadata is removed from a region.
    public struct MetadataRemoved has copy, drop {
        polygon_id: ID,
        owner: address,
    }

    // === Public Functions ===

    /// Set or update string metadata for a region. Caller must be the current owner.
    /// Idempotent: calling twice overwrites the previous value.
    /// Aborts with `EValueTooLong` (6002) if value exceeds 128 bytes.
    #[allow(lint(prefer_mut_tx_context))]
    public fun set_metadata(
        index: &mut index::Index,
        polygon_id: ID,
        value: String,
        ctx: &TxContext,
    ) {
        // CORE-03 fix: prevent unbounded storage inflation via oversized value.
        assert!(std::string::length(&value) <= MAX_VALUE_LENGTH, EValueTooLong);

        let owner = polygon::owner(
            index::get(index, polygon_id),
        );
        assert!(owner == tx_context::sender(ctx), ENotOwner);

        let epoch = tx_context::epoch(ctx);
        let emit_value = copy value;
        metadata_store::upsert_metadata(
            index::uid_mut(index),
            polygon_id,
            value,
            epoch,
        );

        event::emit(MetadataSet {
            polygon_id,
            owner,
            value: emit_value,
            epoch,
        });
    }

    /// Get the metadata value and updated epoch for a region. Aborts if no metadata set.
    public fun get_metadata(index: &index::Index, polygon_id: ID): (String, u64) {
        assert!(
            metadata_store::has_metadata(
                index::uid(index),
                polygon_id,
            ),
            EMetadataNotFound,
        );
        metadata_store::get_metadata(
            index::uid(index),
            polygon_id,
        )
    }

    /// Returns true iff metadata has been set for the given region.
    public fun has_metadata(index: &index::Index, polygon_id: ID): bool {
        metadata_store::has_metadata(
            index::uid(index),
            polygon_id,
        )
    }

    /// Package-internal metadata cleanup for polygon destruction paths.
    /// Removes metadata dynamic field if present. No ownership check —
    /// caller (index::remove_unchecked, mutations::split_replace) is
    /// responsible for authorization.
    public(package) fun force_remove_metadata(uid: &mut UID, polygon_id: ID) {
        metadata_store::force_remove_metadata(uid, polygon_id)
    }

    /// Remove metadata for a region. Caller must be the current owner.
    #[allow(lint(prefer_mut_tx_context))]
    public fun remove_metadata(index: &mut index::Index, polygon_id: ID, ctx: &TxContext) {
        let owner = polygon::owner(
            index::get(index, polygon_id),
        );
        assert!(owner == tx_context::sender(ctx), ENotOwner);

        assert!(
            metadata_store::has_metadata(
                index::uid(index),
                polygon_id,
            ),
            EMetadataNotFound,
        );
        metadata_store::force_remove_metadata(
            index::uid_mut(index),
            polygon_id,
        );

        event::emit(MetadataRemoved { polygon_id, owner });
    }
}
