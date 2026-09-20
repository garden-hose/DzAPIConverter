import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

/** Finds the lib/ directory and KKAPI.txt relative to the running application. */
final class ResourceLocator {

    private ResourceLocator() {}

    static Path resolveLibDir() throws IOException {
        // 1) lib/ next to the running JAR / class directory
        try {
            Path codePath = Paths.get(
                ResourceLocator.class.getProtectionDomain()
                    .getCodeSource().getLocation().toURI());
            Path candidate;
            if (Files.isRegularFile(codePath)) {
                // running from a JAR
                candidate = codePath.getParent().resolve("lib");
            } else {
                // running from classes/ or src/
                candidate = codePath.resolveSibling("lib");
                if (!Files.isDirectory(candidate)) {
                    candidate = codePath.getParent().resolve("lib");
                }
            }
            if (Files.isDirectory(candidate)) return candidate;
        } catch (Exception ignored) {}

        // 2) lib/ relative to current working directory
        Path cwdLib = Paths.get("lib");
        if (Files.isDirectory(cwdLib)) return cwdLib;

        // 3) Fall back to looking next to the source tree we know about
        Path known = Paths.get("/home/workdir/artifacts/DzApiConverter/lib");
        if (Files.isDirectory(known)) return known;

        throw new IOException("Cannot locate lib/ directory containing the DzCompat_*.j files.");
    }

    static Path resolveKkapiPath() throws IOException {
        // 1) KKAPI.txt next to the running JAR / class directory
        try {
            Path codePath = Paths.get(
                ResourceLocator.class.getProtectionDomain()
                    .getCodeSource().getLocation().toURI());
            Path candidate;
            if (Files.isRegularFile(codePath)) {
                candidate = codePath.getParent().resolve("KKAPI.txt");
            } else {
                candidate = codePath.resolveSibling("KKAPI.txt");
                if (!Files.isRegularFile(candidate)) {
                    candidate = codePath.getParent().resolve("KKAPI.txt");
                }
            }
            if (Files.isRegularFile(candidate)) return candidate;
        } catch (Exception ignored) {}

        // 2) cwd
        Path cwd = Paths.get("KKAPI.txt");
        if (Files.isRegularFile(cwd)) return cwd;

        // 3) Known project locations
        for (String p : new String[]{
            "/home/workdir/artifacts/DzApiConverter/KKAPI.txt",
            "/home/workdir/attachments/KKAPI.txt",
            "lib/../KKAPI.txt"
        }) {
            Path known = Paths.get(p);
            if (Files.isRegularFile(known)) return known;
        }

        throw new IOException(
            "Cannot locate KKAPI.txt (needed for Reverse Natives).\n" +
            "Place KKAPI.txt in the working directory of the app, or in the lib folder."
        );
    }
}
