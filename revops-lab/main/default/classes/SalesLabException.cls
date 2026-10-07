/**
 * Business-rule violation in the Revenue Operations Lab whose message is safe to show to the user.
 * Anything else reaching a controller is treated as unexpected and replaced by a generic message (SalesAuraErrors).
 */
public class SalesLabException extends Exception {
}
