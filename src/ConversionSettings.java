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

    /** When true, the last step of a conversion strips leading spaces and tabs from
     *  every line of the converted map script. Off by default (and in CLI mode). */
    boolean removeIndentation = false;

    /** When true, right after "Clear unused natives" the script is checked against the names
     *  Reforged's common.j already declares: native declarations of natives that exist in
     *  Reforged are dropped, and globals the map declares under a common.j name are removed
     *  (unused) or renamed (used). Needs lib/ReforgedCommonNames.txt; skipped when it is missing. */
    boolean fixReforgedNameCollisions = true;

    /** When true, GetUnitState/SetUnitState call sites that read an extended
     *  (non-stock) index via ConvertUnitState(N) - kkapi/YDWE's UnitState.cpp hook -
     *  are rewritten to route through DzCompat_GetExtUnitState/SetExtUnitState
     *  (lib/DzCompat_ExtendedUnitState.j) instead of silently returning 0 in Reforged. */
    boolean convertExtendedUnitState = true;
}
