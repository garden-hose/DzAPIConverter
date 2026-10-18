import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;

/** Finds the lib/ directory and KKAPI.txt relative to the running application. */
final class ResourceLocator {

    private ResourceLocator() {}

    /** The jar (or class directory) the application runs from, or null when it cannot be told. */
    private static Path codeLocation() {
        try {
            return Paths.get(ResourceLocator.class.getProtectionDomain().getCodeSource().getLocation().toURI());
        } catch (Exception e) {
            return null;
        }
    }

    static Path resolveLibDir() throws IOException {
        // 1) lib/ next to the running JAR / class directory
        Path codePath = codeLocation();
        if (codePath != null) {
            Path candidate;
            if (Files.isRegularFile(codePath)) {
                // running from a JAR
                candidate = codePath.getParent().resolve("lib");
            } else {
                // running from classes/ or src/
                candidate = codePath.resolveSibling("lib");
                if (!Files.isDirectory(candidate) && codePath.getParent() != null) {
                    candidate = codePath.getParent().resolve("lib");
                }
            }
            if (Files.isDirectory(candidate)) return candidate;
        }

        // 2) lib/ relative to current working directory
        Path cwdLib = Paths.get("lib");
        if (Files.isDirectory(cwdLib)) return cwdLib;

        throw new IOException("Cannot locate lib/ directory containing the DzCompat_*.j files.");
    }

    /**
     * KKAPI.txt ships inside lib/, so lib/ is searched first; the folder the app runs from and
     * the working directory (with or without a lib/ subfolder) are accepted as well.
     */
    static Path resolveKkapiPath() throws IOException {
        List<Path> candidates = new ArrayList<>();

        try {
            candidates.add(resolveLibDir().resolve("KKAPI.txt"));
        } catch (IOException ignored) {
            // no lib/ found: the other locations below may still hold the file
        }

        Path codePath = codeLocation();
        if (codePath != null) {
            Path base = Files.isRegularFile(codePath) ? codePath.getParent() : codePath;
            if (base != null) {
                candidates.add(base.resolve("KKAPI.txt"));
                candidates.add(base.resolve("lib").resolve("KKAPI.txt"));
                if (base.getParent() != null) {
                    candidates.add(base.getParent().resolve("KKAPI.txt"));
                    candidates.add(base.getParent().resolve("lib").resolve("KKAPI.txt"));
                }
            }
        }

        candidates.add(Paths.get("KKAPI.txt"));
        candidates.add(Paths.get("lib", "KKAPI.txt"));

        for (Path p : candidates) {
            if (Files.isRegularFile(p)) return p;
        }

        throw new IOException(
            "Cannot locate KKAPI.txt (needed to reverse a script made by an older version of this tool).\n" +
            "It normally sits in the lib folder next to the app; place it there, or in the app's folder."
        );
    }
}
