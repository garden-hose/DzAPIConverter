Java tool to convert Warcraft III JASS map scripts (war3map.j) from KKAPI/DzAPI environment to reforged

Description:
- Open Source
- ~330/650 Natives implemented
- Only KKAPI, DzAPI, EX* natives are covered. M16 not included (for now?)
- Frames positioning might require manual fine-tuning, depending on the map
- A local save/load system similar to emulator tools is wired in, but needs adjustment
- Some natives such as DzSetUnitModel, ExExecuteScript are semi-automated and require user interaction (see notes below)
- Not an universal one click solution to any map, but a starting point. Some maps still need extra work
- Natives that rely on engine modifications that reforged does not support, such as extended attack speed, stats, HP/Mana and memory hacks remain massive roadblocks in the conversion of maps

Usage:
- To open the program, run the run.bat
- Input field - Choose war3map.j input
- Output field - Choose converter output path
- Map table field - Choose the map's table field path (used for ExExecuteScript)
- Override checkbox - Enables HasMallItem, GetMapLevel and GetGuildName overrides
- HasMallItem - Returns true or false for Mall Item calls
- GetMapLevel - Returns a number for Map Level calls
- GetGuildName - Returns a string for Guild Name calls
- Convert - Runs the conversion process
- Reverse Functions - Returns converted "function"(s) back to "native"(s)

Notes about DzSetUnitModel and ExExecuteScript (frequently used natives with no exact reforged equivalent):

DzSetUnitModel workaround uses BlzSetUnitSkin with a skin ID registry to bridge the integer to string:
- During conversion a window will popup asking if the user wants to populate the skin ID registry
- If the user chooses yes, a window to select a file will popup
- The user should select unit.ini or UnitString.txt files, then the registry gets populated according to the selected file
- If the user chooses no, the registry entries will be written with empty ID, then the user has to populate them manually

ExExecuteScript workaround uses your map tables (item.ini, ability.ini, etc), to create a registry and rewrite all calls to a format reforged supports
- Set your map table path and add the map's tables used by the native
- Place your map's tables (unit.ini, item.ini, ability.ini, etc) in the table path folder
- During conversion, if your map uses ExExecuteScript, it will automatically scan the script and rewrite the lines based on the map tables

Notes about the save and load archive system
- Emulates KK server save in your local machine
- Saves are written to a .pld file
- The save file is located at Documents\Warcraft III\CustomMapData\DzCompat_Archive\Map Name\
- The system is partially working, still need to adjust a few values that aren't saving and loading

For more info and discussions join the discord - https://discord.gg/nVz2frA7Y7


