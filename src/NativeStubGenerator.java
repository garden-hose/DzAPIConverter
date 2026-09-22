import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Turns a "native ..." declaration that has no implementation into a stub function that
 * does nothing and returns a neutral value: 0, false, "", 0. or null (handle types).
 * A neutral value is the one that least changes how the map behaves - the map logic keeps
 * working as if the feature simply were not there, instead of being told that something
 * happened (a "true" or a made-up number).
 */
final class NativeStubGenerator {

    private static final Pattern RETURN_TYPE = Pattern.compile("\\breturns\\s+(\\w+)\\s*$");

    private final ConversionSettings settings;

    NativeStubGenerator(ConversionSettings settings) {
        this.settings = settings;
    }

    /** The statement a stub returns for a native with the given JASS return type ("" for nothing). */
    static String neutralReturn(String returnType) {
        switch (returnType) {
            case "nothing": return "";
            case "integer": return "return 0";
            case "real":    return "return 0.";
            case "boolean": return "return false";
            case "string":  return "return \"\"";
            // every handle type. (A native returning "code" is not something KKAPI has; null is
            // the closest neutral value, though a strict checker such as pjass rejects it there.)
            default:        return "return null";
        }
    }

    List<String> convert(String line) {
        // Only the code part matters: a trailing // comment must not be mistaken for the return type.
        String code = JassText.codeOnly(line).replaceAll("\\s+$", "");
        Matcher rt = RETURN_TYPE.matcher(code);
        String returnType = rt.find() ? rt.group(1) : "nothing";
        String line1 = code.replaceFirst("native", "function");

        String line2 = neutralReturn(returnType);

        // Configurable / special-cased DzAPI_Map_* stubs
        if (settings.unlockStubs) {
            if (line.contains("DzAPI_Map_HasMallItem")) {
                line2 = "return " + (settings.stubHasMallItem ? "true" : "false");
            } else if (line.contains("DzAPI_Map_GetMapLevel")) {
                // Prefer exact GetMapLevel over GetMapLevelRank
                if (line.matches("(?s).*\\bDzAPI_Map_GetMapLevel\\b.*")
                        && !line.contains("DzAPI_Map_GetMapLevelRank")) {
                    line2 = "return " + settings.stubGetMapLevel;
                }
            } else if (line.contains("DzAPI_Map_GetGuildName")) {
                line2 = "return \"" + JassStrings.escape(settings.stubGetGuildName) + "\"";
            }
        }

        List<String> result = new ArrayList<>();
        result.add(line1);
        if (!line2.isEmpty()) result.add(line2);
        result.add("endfunction");
        return result;
    }
}
