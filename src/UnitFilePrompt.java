import java.nio.file.Path;

/**
 * Asks the user for an optional unit.ini / UnitStrings.txt file used to look up
 * skin ids for DzSetUnitModel paths. The converter engine is UI-agnostic: in CLI
 * mode no prompt is supplied and skin ids are written as 0.
 */
interface UnitFilePrompt {

    /** @return the chosen unit data file, or null if the user declined / cancelled. */
    Path requestUnitDataFile();
}
