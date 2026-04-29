/// Spatial auction — demonstrates wrapping mercator with custom logic.
/// The spatial index ensures non-overlapping claims; this module adds bidding.
module 0x0::spatial_auction;

use mercator::index::{Self, Index};
use sui::coin::Coin;
use sui::sui::SUI;
/// Claim a region by paying a fee.
public fun claim_with_payment(
    index: &mut Index,
    parts_xs: vector<vector<u64>>,
    parts_ys: vector<vector<u64>>,
    payment: Coin<SUI>,
    treasury: address,
    ctx: &mut sui::tx_context::TxContext,
): sui::object::ID {
    sui::transfer::public_transfer(payment, treasury);
    index::register(index, parts_xs, parts_ys, ctx)
}

/// Query how many regions are in a viewport.
public fun density(
    index: &Index,
    min_x: u64,
    min_y: u64,
    max_x: u64,
    max_y: u64,
): u64 {
    let regions = index::query_viewport(index, min_x, min_y, max_x, max_y);
    std::vector::length(&regions)
}
