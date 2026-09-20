import java.nio.file.Path;

/**
 * Supplies the folder holding the map's object-data tables (W3x2lni's
 * table/*.ini), used to bake the values EXExecuteScript reads through jass.slk.
 * The GUI answers from its "Map table path" field; in CLI mode the folder comes from the third
 * argument. With no folder (or a folder holding no table .ini files) EXExecuteScript is not
 * converted at all.
 */
interface SlkTablePrompt {

    /**
     * @param suggested a folder named "table" found next to the script, or null; a prompt is free
     *                  to ignore it (the GUI does, so an empty field means no conversion)
     * @return the table folder to use, or null for none
     */
    Path requestTableFolder(Path suggested);
}
