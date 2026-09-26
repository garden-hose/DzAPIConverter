# Java tool to convert Warcraft III JASS map scripts (war3map.j) from KKAPI/DzAPI environment to Reforged

## Description:
- Open Source
- ~350/650 Natives implemented
- Only KKAPI, DzAPI, EX* natives are covered. M16 natives not included (for now?)
- Frames positioning might require manual fine-tuning, depending on the map
- A local save/load system similar to emulator tools is wired in, but needs adjustment
- Some natives such as DzSetUnitModel, EXExecuteScript are semi-automated and require user interaction (see notes below)
- Not an universal one click solution to any map, but a starting point. Some maps still need extra work
- Natives that rely on engine modifications that Reforged does not support, such as memory hacks, remain massive roadblocks in the conversion of maps

## Usage:
- To open the program, run the run.bat
- Input field - Choose war3map.j input
- Output field - Choose converter output path
- Map table field - Choose the map's table field path (used for EXExecuteScript,DzSetUnitModel, etc)
- Override checkbox - Enables HasMallItem, GetMapLevel and GetGuildName overrides
- HasMallItem - Returns true or false for Mall Item calls
- GetMapLevel - Returns a number for Map Level calls
- GetGuildName - Returns a string for Guild Name calls
- Convert - Runs the conversion process
- Reverse Functions - Returns converted "function"(s) back to "native"(s)
- Clear unused natives - Removes natives that are declared but never used
- Remove indentation - Self-explanatory

# Notes about the frequently used natives DzSetUnitModel, EXExecuteScript, etc:
- These require the user to extract the map tables (unit.ini, item.ini, ability.ini, etc) and convert them to .ini using w3x2lni
- Place them in the "map table path" folder.

## DzSetUnitModel workaround uses BlzSetUnitSkin with a skin ID registry to bridge the integer to string gap:
- During conversion, skin registry is populated according to unit.ini or UnitString.txt files, read from map table path

## EXExecuteScript workaround uses your map tables to create a registry and rewrite all calls to a format Reforged supports
- During conversion, reads the tables in the map table path folder and automatically rewrite the necessary lines

## Notes about the save and load archive system
- Emulates KK server save in your local machine
- Saves are written to a .pld file
- The save file is located at Documents\Warcraft III\CustomMapData\DzCompat_Archive\Map Name\
- The system is partially working, still need to adjust a few values that aren't saving and loading

## Compiling
- Compiling is only needed when Java code is edited or new natives added
- When a native is already declared in ConverterConstants, any edits are automatically picked up, no compile needed 


For more info and discussions join the discord - https://discord.gg/nVz2frA7Y7
