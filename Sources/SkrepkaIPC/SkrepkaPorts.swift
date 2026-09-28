/// Skrepka's own TCP ports on Linux: what `skrepkad` listens on unless
/// `--port` says otherwise, and what the NixOS module's `openFirewall` opens.
///
/// Here rather than in the daemon because every client says them. A firewall
/// is the one obstacle the daemon cannot see past, so `skrepka pair`, Settings
/// and `skrepka doctor` all name the ports a rule has to allow — and each
/// naming its own copy is how the three would drift apart. `nix/nixos-module.nix`
/// repeats them for `openFirewall`; change both together.
public enum SkrepkaPorts {
    /// The pinned listener, which paired devices dial to sync.
    public static let sync = 27182

    /// The pairing listener, open only while a pairing window is. Always the
    /// port after ``sync``, so one range covers both.
    public static let pairing = sync + 1

    /// Both, lowest first — the rule that lets every other device in.
    public static let all = [sync, pairing]
}
