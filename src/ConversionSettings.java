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

    /** When true, the local archive save system is stubbed out: the save/load natives
     *  (DzAPI_Map_SaveServerValue, GetServerValue, Store*, GetStored*, and the archive-backed
     *  GetMapLevel/HasMallItem/GetGuildName) become neutral stubs, and the archive's entry points
     *  used by RequestExtra*Data do nothing. Nothing is saved and no file is written to the
     *  user's system. Off by default (and in CLI mode). */
    boolean removeLocalSave = false;

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

    /** When true, and the map writes ability DATA_A..I via EXSetAbilityDataReal/Integer,
     *  UnitAddAbility calls are routed through DzCompat_UnitAddAbility so new ability
     *  instances receive those values (YDWE writes object data; Reforged only the instance). */
    boolean convertAbilityAddData = true;

    /** When true, and a map table folder is given, item.ini is scanned for objects that inherit a
     *  stock item and set no Requires field; a copy with an empty Requires added is written to
     *  item_patched.ini next to item.ini (Reforged's built-in requirements, such as 'oslo' needing
     *  a Castle, otherwise apply). item.ini itself is never modified. Needs lib/ReforgedStockItemIds.txt. */
    boolean patchItemRequirements = true;

    /** When true, DestroyTimer call sites are rewritten to DzCompat_DestroyTimer, which
     *  null-checks and pauses before destroy. Prevents Reforged crashes from double-destroy
     *  of the same timer handle (callback + cleanup paths). On by default. */
    boolean convertSafeTimerDestroy = true;
}
