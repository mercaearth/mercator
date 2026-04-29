/// Low-level metadata storage helpers shared by index and metadata modules.
module mercator::metadata_store {
    use std::string::String;
    use sui::dynamic_field;

    /// Dynamic field key for attaching metadata to an Index, keyed by polygon ID.
    public struct MetadataKey has copy, drop, store {
        polygon_id: ID,
    }

    /// The metadata state stored as a dynamic field value.
    public struct MetadataState has drop, store {
        value: String,
        updated_epoch: u64,
    }

    public(package) fun upsert_metadata(uid: &mut UID, polygon_id: ID, value: String, epoch: u64) {
        let key = MetadataKey { polygon_id };

        if (dynamic_field::exists_(uid, key)) {
            dynamic_field::remove<MetadataKey, MetadataState>(
                uid,
                key,
            );
        };

        dynamic_field::add(
            uid,
            key,
            MetadataState {
                value,
                updated_epoch: epoch,
            },
        );
    }

    public(package) fun get_metadata(uid: &UID, polygon_id: ID): (String, u64) {
        let key = MetadataKey { polygon_id };
        let state = dynamic_field::borrow<MetadataKey, MetadataState>(uid, key);
        (state.value, state.updated_epoch)
    }

    public(package) fun has_metadata(uid: &UID, polygon_id: ID): bool {
        dynamic_field::exists_<MetadataKey>(
            uid,
            MetadataKey { polygon_id },
        )
    }

    /// Removes metadata dynamic field if present. No ownership check — caller is
    /// responsible for authorization.
    public(package) fun force_remove_metadata(uid: &mut UID, polygon_id: ID) {
        let key = MetadataKey { polygon_id };
        if (dynamic_field::exists_(uid, key)) {
            dynamic_field::remove<MetadataKey, MetadataState>(
                uid,
                key,
            );
        };
    }
}
