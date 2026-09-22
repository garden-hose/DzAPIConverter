import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * The names Reforged's common.j already declares (lib/ReforgedCommonNames.txt, generated
 * from the jassdoc copy of common.j). A map script that declares one of these again
 * fails to compile in Reforged, so the converter drops or renames such declarations.
 *
 * File format: one "native NAME" or "global NAME" per line; '#' starts a comment line.
 */
final class ReforgedCommonNames {

    static final String FILE_NAME = "ReforgedCommonNames.txt";

    final Set<String> natives = new HashSet<>();
    final Set<String> globals = new HashSet<>();

    /** @return the names, or null when the file is not in the lib folder */
    static ReforgedCommonNames load(Path libDir) throws IOException {
        Path file = libDir.resolve(FILE_NAME);
        if (!Files.isRegularFile(file)) return null;
        ReforgedCommonNames names = new ReforgedCommonNames();
        List<String> lines = Files.readAllLines(file, StandardCharsets.UTF_8);
        for (String raw : lines) {
            String line = raw.trim();
            if (line.isEmpty() || line.startsWith("#")) continue;
            String[] parts = line.split("\\s+");
            if (parts.length != 2) continue;
            if (parts[0].equals("native")) names.natives.add(parts[1]);
            else if (parts[0].equals("global")) names.globals.add(parts[1]);
        }
        return names;
    }
}
