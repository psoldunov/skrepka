import Foundation

/// A value an ``LWWRegister`` can hold.
///
/// The ordering exists for exactly one purpose: the last tie-break, when two
/// writes carry the same timestamp *and* name the same device but disagree
/// about the value. Without it, `merged(a, b)` returns `a` and `merged(b, a)`
/// returns `b` — the one remaining way for the merge to stop being commutative,
/// and a merge that is not commutative converges to whichever side spoke last.
///
/// Any strict total order will do. It carries no meaning and nothing reads it
/// except the tie-break; it only has to be the same order on both peers.
///
/// Declared here rather than reusing `Comparable` because `Bool` — the only
/// value this protocol has today — is not `Comparable` in the standard library,
/// and conforming it retroactively would put an ordering on `Bool` for the
/// whole program to see in order to settle one tie inside this file.
public protocol LWWValue: Sendable, Hashable, Codable {
    static func lwwPrecedes(_ lhs: Self, _ rhs: Self) -> Bool
}

extension Bool: LWWValue {
    /// `false` before `true`, arbitrarily.
    public static func lwwPrecedes(_ lhs: Bool, _ rhs: Bool) -> Bool { !lhs && rhs }
}

extension String: LWWValue {
    public static func lwwPrecedes(_ lhs: String, _ rhs: String) -> Bool { lhs < rhs }
}
