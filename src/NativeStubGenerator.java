import java.util.ArrayList;
import java.util.List;

/** Turns a "native ..." declaration that has no implementation into a dummy-returning function stub. */
final class NativeStubGenerator {

    private final ConversionSettings settings;

    NativeStubGenerator(ConversionSettings settings) {
        this.settings = settings;
    }

    List<String> convert(String line) {
        String line1 = line.replaceFirst("native", "function");
        String[] parts = line.trim().split("\\s+");
        String variableType = parts[parts.length - 1];

        String line2;
        switch (variableType) {
            case "integer":  line2 = "return 99"; break;
            case "boolean":  line2 = "return true"; break;
            case "nothing":  line2 = ""; break;
            case "real":     line2 = "return 0."; break;
            case "ability":
            case "unit":
            case "player":   line2 = "return null"; break;
            case "string":   line2 = "return \"1\""; break;
            default:         line2 = ""; break;
        }

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
