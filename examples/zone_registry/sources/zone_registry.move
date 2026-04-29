/// Zone registry — non-overlapping administrative zones with metadata.
/// Demonstrates: register, metadata attachment, and metadata reads.
module 0x0::zone_registry;

use mercator::index::{Self, Index};
use mercator::metadata;
use std::string;
/// Register a new zone with a label.
public fun create_zone(
    index: &mut Index,
    parts_xs: vector<vector<u64>>,
    parts_ys: vector<vector<u64>>,
    label: string::String,
    ctx: &mut sui::tx_context::TxContext,
): sui::object::ID {
    let zone_id = index::register(index, parts_xs, parts_ys, ctx);
    metadata::set_metadata(index, zone_id, label, ctx);
    zone_id
}

/// Read zone label.
public fun zone_label(index: &Index, zone_id: sui::object::ID): string::String {
    let (label, _) = metadata::get_metadata(index, zone_id);
    label
}

/// Check if a zone has metadata attached.
public fun has_label(index: &Index, zone_id: sui::object::ID): bool {
    metadata::has_metadata(index, zone_id)
}
