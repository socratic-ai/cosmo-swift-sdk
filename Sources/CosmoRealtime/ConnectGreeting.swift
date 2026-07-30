/// The shared first-turn instruction that asks Cosmo to introduce itself on
/// connect. Free-standing (not on the availability-gated ``VoiceSessionModel``)
/// so any host app can send the same opener.
public enum ConnectGreeting {
    public static let base =
        "Greet in 2-4 words, naming yourself Cosmo — like \"Cosmo here!\" or \"Hey, it's Cosmo.\" Then stop and wait."
}
