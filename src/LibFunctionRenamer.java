import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Keeps the library functions that get injected from clashing with functions the map
 * defines itself.
 *
 * Some maps define their own wrappers with the very names the library uses - for example
 * a map's own {@code function DzAPI_Map_ContinuousCount takes player, integer} that calls
 * {@code RequestExtraIntegerData}. The library's RequestExtra dispatcher needs its own
 * {@code DzAPI_Map_ContinuousCount} to answer the request, and two functions with one
 * name do not compile. The map's function is left exactly as it is (the map's calls keep
 * resolving to it); the library's copy is renamed, everywhere it is emitted, to
 * {@code DzCompat_lib_<name>}, so the dispatcher still reaches it.
 */
final class LibFunctionRenamer {

    private LibFunctionRenamer() {}

    static final String PREFIX = "DzCompat_lib_";

    private static final Pattern FUNCTION_DEF = Pattern.compile("^\\s*function\\s+(\\w+)\\s+takes\\b");

    /** The names of the functions the script defines. */
    static Set<String> definedFunctions(List<String> lines) {
        Set<String> names = new LinkedHashSet<>();
        for (String line : lines) {
            if (line.indexOf("function") < 0) continue;
            Matcher m = FUNCTION_DEF.matcher(JassText.codeOnly(line));
            if (m.find()) names.add(m.group(1));
        }
        return names;
    }

    /**
     * @param emittedNames   the names of the library functions that will be emitted
     * @param mapFunctions   the functions the map defines
     * @return old name -> new name for every emitted library function the map also defines
     */
    static Map<String, String> renamesFor(Set<String> emittedNames, Set<String> mapFunctions) {
        Map<String, String> renames = new LinkedHashMap<>();
        for (String n : emittedNames) {
            if (mapFunctions.contains(n)) renames.put(n, PREFIX + n);
        }
        return renames;
    }

    /** Applies the renames to the emitted library lines (definitions, calls and function references). */
    static void apply(List<String> libLines, Map<String, String> renames) {
        if (renames.isEmpty()) return;
        for (int i = 0; i < libLines.size(); i++) {
            String line = libLines.get(i);
            if (line.isEmpty()) continue;
            libLines.set(i, NameCollisionFixer.renameIdentifiers(line, renames));
        }
    }
}
