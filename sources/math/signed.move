/// Signed integer arithmetic for fixed-point SAT computation.
/// Move lacks native signed integers — this module emulates them
/// using (magnitude: u128, negative: bool) pairs.
module mercator::signed {
    use std::u128;

    // === Errors ===

    const EOverflow: u64 = 1008;

    // === Structs ===

    /// A signed integer represented as magnitude + sign.
    /// All cross-products and SAT projections use this type.
    public struct Signed has copy, drop, store {
        magnitude: u128,
        negative: bool,
    }

    fun pack_signed(magnitude: u128, negative: bool): Signed {
        Signed {
            magnitude,
            negative: magnitude != 0 && negative,
        }
    }

    fun checked_add_or_abort(a: u128, b: u128): u128 {
        let sum = u128::checked_add(a, b);
        assert!(option::is_some(&sum), EOverflow);
        option::destroy_some(sum)
    }

    fun checked_mul_or_abort(a: u128, b: u128): u128 {
        let product = u128::checked_mul(a, b);
        assert!(option::is_some(&product), EOverflow);
        option::destroy_some(product)
    }

    // === Public Functions ===

    /// Construct a Signed value from magnitude and sign.
    public fun new(magnitude: u128, negative: bool): Signed {
        pack_signed(magnitude, negative)
    }

    /// Lift a u64 to a non-negative Signed value.
    public fun from_u64(value: u64): Signed {
        pack_signed((value as u128), false)
    }

    /// Compute a - b with signed result.
    public fun sub_u64(a: u64, b: u64): Signed {
        if (a >= b) {
            pack_signed(((a - b) as u128), false)
        } else {
            pack_signed(((b - a) as u128), true)
        }
    }

    /// Multiply two signed values.
    public fun mul(a: &Signed, b: &Signed): Signed {
        if (a.magnitude == 0 || b.magnitude == 0) {
            return pack_signed(0, false)
        };

        let magnitude = checked_mul_or_abort(
            a.magnitude,
            b.magnitude,
        );
        pack_signed(magnitude, a.negative != b.negative)
    }

    /// Add two signed values.
    public fun add(a: &Signed, b: &Signed): Signed {
        if (a.negative == b.negative) {
            let magnitude = checked_add_or_abort(
                a.magnitude,
                b.magnitude,
            );
            pack_signed(magnitude, a.negative)
        } else {
            if (a.magnitude >= b.magnitude) {
                pack_signed(
                    a.magnitude - b.magnitude,
                    a.negative,
                )
            } else {
                pack_signed(
                    b.magnitude - a.magnitude,
                    b.negative,
                )
            }
        }
    }

    /// True iff a < b.
    public fun lt(a: &Signed, b: &Signed): bool {
        if (eq(a, b)) {
            false
        } else if (a.negative != b.negative) {
            a.negative
        } else if (a.negative) {
            a.magnitude > b.magnitude
        } else {
            a.magnitude < b.magnitude
        }
    }

    /// True iff a <= b.
    public fun le(a: &Signed, b: &Signed): bool {
        lt(a, b) || eq(a, b)
    }

    /// True iff a > b.
    public fun gt(a: &Signed, b: &Signed): bool {
        !le(a, b)
    }

    /// True iff a >= b.
    public fun ge(a: &Signed, b: &Signed): bool {
        !lt(a, b)
    }

    /// True iff a == b.
    public fun eq(a: &Signed, b: &Signed): bool {
        if (a.magnitude == 0 && b.magnitude == 0) {
            true
        } else {
            a.magnitude == b.magnitude && a.negative == b.negative
        }
    }

    /// Return the magnitude component.
    public fun magnitude(s: &Signed): u128 {
        s.magnitude
    }

    /// Return true if the value is negative.
    public fun is_negative(s: &Signed): bool {
        s.negative
    }

    /// Cross product sign for three 2D points A, B, C.
    /// Returns (B−A) × (C−A). Used for convexity verification.
    public fun cross_sign(ax: u64, ay: u64, bx: u64, by: u64, cx: u64, cy: u64): Signed {
        let dx1 = sub_u64(bx, ax);
        let dy2 = sub_u64(cy, ay);
        let prod1 = mul(&dx1, &dy2);

        let dy1 = sub_u64(by, ay);
        let dx2 = sub_u64(cx, ax);
        let prod2 = mul(&dy1, &dx2);

        if (prod1.negative == prod2.negative) {
            if (prod1.magnitude >= prod2.magnitude) {
                pack_signed(
                    prod1.magnitude - prod2.magnitude,
                    prod1.negative,
                )
            } else {
                pack_signed(
                    prod2.magnitude - prod1.magnitude,
                    !prod2.negative,
                )
            }
        } else {
            let magnitude = checked_add_or_abort(
                prod1.magnitude,
                prod2.magnitude,
            );
            pack_signed(magnitude, prod1.negative)
        }
    }

    #[test]
    fun signed_sub_handles_positive_negative_and_zero() {
        let pos = sub_u64(10, 5);
        assert!(magnitude(&pos) == 5 && !is_negative(&pos), 0);

        let neg = sub_u64(5, 10);
        assert!(magnitude(&neg) == 5 && is_negative(&neg), 1);

        let zero = sub_u64(7, 7);
        assert!(magnitude(&zero) == 0 && !is_negative(&zero), 2);
    }

    #[test]
    fun signed_comparison_orders_values_correctly() {
        let pos5 = from_u64(5);
        let pos10 = from_u64(10);
        let neg5 = new(5, true);

        assert!(lt(&pos5, &pos10), 0);
        assert!(lt(&neg5, &pos5), 1);
        assert!(gt(&pos10, &pos5), 2);
        assert!(le(&pos5, &pos5), 3);
        assert!(ge(&pos10, &pos5), 4);
        assert!(eq(&pos5, &from_u64(5)), 5);
    }

    #[test]
    fun signed_multiply_preserves_magnitude_and_sign() {
        let pos5 = from_u64(5);
        let pos3 = from_u64(3);
        let neg2 = new(2, true);

        let result = mul(&pos5, &pos3);
        assert!(magnitude(&result) == 15 && !is_negative(&result), 0);

        let result_neg = mul(&pos5, &neg2);
        assert!(magnitude(&result_neg) == 10 && is_negative(&result_neg), 1);
    }

    #[test]
    fun signed_new_canonicalizes_zero() {
        let zero = new(0, true);
        assert!(magnitude(&zero) == 0 && !is_negative(&zero), 0);
    }

    #[test]
    fun signed_add_canonicalizes_zero_and_comparisons() {
        let neg5 = new(5, true);
        let pos5 = from_u64(5);
        let zero = add(&neg5, &pos5);
        let canonical_zero = from_u64(0);

        assert!(magnitude(&zero) == 0 && !is_negative(&zero), 0);
        assert!(eq(&zero, &canonical_zero), 1);
        assert!(!lt(&zero, &canonical_zero), 2);
        assert!(!gt(&zero, &canonical_zero), 3);
    }

    #[test]
    fun signed_comparisons_treat_legacy_negative_zero_as_zero() {
        let legacy_negative_zero = Signed {
            magnitude: 0,
            negative: true,
        };
        let zero = from_u64(0);

        assert!(eq(&legacy_negative_zero, &zero), 0);
        assert!(!lt(&legacy_negative_zero, &zero), 1);
        assert!(!gt(&legacy_negative_zero, &zero), 2);
    }

    #[test]
    fun cross_sign_canonicalizes_zero() {
        let zero = cross_sign(0, 2, 1, 1, 2, 0);
        assert!(magnitude(&zero) == 0 && !is_negative(&zero), 0);
    }

    #[test]
    #[expected_failure(abort_code = EOverflow)]
    fun signed_mul_overflow_aborts_with_eoverflow() {
        let max = new(
            0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF,
            false,
        );
        let two = from_u64(2);
        let _overflow = mul(&max, &two);
    }

    #[test]
    fun cross_sign_detects_turn_orientation() {
        let left_turn = cross_sign(0, 0, 2, 0, 2, 2);
        assert!(magnitude(&left_turn) == 4 && !is_negative(&left_turn), 0);

        let right_turn = cross_sign(0, 0, 2, 2, 4, 0);
        assert!(is_negative(&right_turn), 1);
    }
}
