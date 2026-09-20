/**
 * Options that influence how forward conversion stubs the DzAPI_Map_* natives.
 * Populated from the UI in GUI mode; defaults are used in CLI mode.
 */
final class ConversionSettings {

    // Stub return values (used by conversion; set from UI or defaults for CLI)
    boolean stubHasMallItem = true;
    int stubGetMapLevel = 99;
    String stubGetGuildName = "Warcraft III";

    /** When false, GetMapLevel/HasMallItem/GetGuildName
     *  route to their real implementations instead of UI-supplied stubs. */
    boolean unlockStubs = false;

    /** When true, the first step of a conversion removes every "native dz..." declaration
     *  that the script declares but never uses. Off by default (and in CLI mode). */
    boolean clearUnusedNatives = true;
}
