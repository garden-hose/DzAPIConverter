import java.io.IOException;
import java.util.Locale;

/** Shared input sanity checks for both conversion directions. */
final class InputValidator {

    private InputValidator() {}

    /** Reject obvious binary map archives (.w3x / .w3m) early with a clear message. */
    static void rejectMapArchive(String inputPath) throws IOException {
        String lower = inputPath.toLowerCase(Locale.ROOT);
        if (lower.endsWith(".mpq") || lower.endsWith(".w3x") || lower.endsWith(".w3m") || lower.endsWith(".w3n")) {
            throw new IOException(
                "You selected a map archive (" + inputPath + ").\n" +
                "This tool needs the extracted JASS script (usually war3map.j),\n" +
                "not the .w3x/.w3m file itself.\n" +
                "Extract the war3map.j with a MPQ Editor."
            );
        }
    }
}
