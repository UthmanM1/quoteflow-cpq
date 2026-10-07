/**
 * Business-rule violation that is safe to show to the end user.
 * Anything that is NOT a QuoteFlowException is treated as unexpected by the controllers
 * and is replaced with a generic message plus a correlation id for support.
 */
public class QuoteFlowException extends Exception {
}
