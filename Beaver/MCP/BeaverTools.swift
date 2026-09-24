//
//  BeaverTools.swift
//  Beaver
//
//  Every tool the MCP server offers. A user-facing capability added to
//  Beaver gets its tool here (see CLAUDE.md → MCP), and a row in
//  Beaver/Resources/MCP.md; MCPDocDriftTests keeps the two equal.

public enum BeaverTools {
    public static var all: [MCPTool] {
        StatusTools.all + SessionTools.all + LogTools.all + NetworkTools.all + StorageTools.all
            + StateTools.all + CommandTools.all + [GuideTool.tool]
    }
}
