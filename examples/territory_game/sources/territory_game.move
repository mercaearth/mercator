/// Territory control game — players claim non-overlapping regions.
/// Demonstrates: register, viewport queries, ownership transfer.
module 0x0::territory_game;

use mercator::index::{Self, Index};
/// Claim a rectangular territory on the game board.
public fun claim_territory(
    index: &mut Index,
    x: u64,
    y: u64,
    width: u64,
    height: u64,
    ctx: &mut sui::tx_context::TxContext,
): sui::object::ID {
    let xs = vector[x, x + width, x + width, x];
    let ys = vector[y, y, y + height, y + height];
    index::register(index, vector[xs], vector[ys], ctx)
}

/// Check which territories touch a viewport.
public fun territories_in_area(
    index: &Index,
    min_x: u64,
    min_y: u64,
    max_x: u64,
    max_y: u64,
): vector<ID> {
    index::query_viewport(index, min_x, min_y, max_x, max_y)
}

/// Transfer territory to another player.
public fun give_territory(
    index: &mut Index,
    territory_id: ID,
    new_owner: address,
    ctx: &sui::tx_context::TxContext,
) {
    index::transfer_ownership(index, territory_id, new_owner, ctx)
}
