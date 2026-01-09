# Task Breakdown Tool Integration Guide

## Overview

The Task Breakdown tool enables multi-agent processing by allowing AI agents to decompose complex analysis tasks into smaller, manageable sub-tasks that can be processed by specialized agents.

## Configuration

### Step 1: Setup Task Breakdown MCP Server

The workflow includes a **"Postgres PGVector Store Retrieve"** node that can be used as a tool, and optionally a **Task Breakdown** MCP client tool.

### Step 2: Configure Task Breakdown Node

1. Locate the **"Task Breakdown"** node (if present, may be disabled)
2. Configure the endpoint URL:
   ```
   https://server.smithery.ai/@Parc-Dev/task-breakdown-server/mcp?api_key=YOUR_API_KEY&profile=YOUR_PROFILE
   ```
3. Update the API key and profile as needed
4. Enable the node if it's disabled

### Step 3: Connect to Consolidation Agent

1. Connect **"Task Breakdown"** node to **"Consolidation AI Agent"** via `ai_tool` connection
2. This allows the consolidation agent to use task breakdown when analyzing complex issues

## Usage Scenarios

### Scenario 1: Complex Multi-Domain Issues

When the Consolidation Agent identifies issues that span multiple domains, it can use the Task Breakdown tool to:
- Decompose the issue into domain-specific sub-tasks
- Assign sub-tasks to appropriate specialized agents
- Synthesize results

### Scenario 2: Large Analysis Tasks

For very large metric sets, the Consolidation Agent can:
- Break down analysis into phases
- Process each phase separately
- Combine results

## Tool Description

Update the tool description in the node to help the AI agent understand when to use it:

```
"Break down complex database health analysis tasks into smaller, manageable sub-tasks. 
Use this tool when analyzing issues that span multiple monitoring domains or when 
dealing with large, complex problems that require decomposition."
```

## Alternative: Knowledge Base Integration

The workflow also includes **"Postgres PGVector Store Retrieve"** which can:
- Store historical analysis results
- Retrieve similar past issues
- Provide context to AI agents

This is already connected to the Consolidation AI Agent and provides similar multi-agent processing capabilities.

## Best Practices

1. **Enable for Complex Workflows**: Use task breakdown for workflows with many interconnected issues
2. **Monitor Usage**: Track how often the tool is called
3. **Optimize Prompts**: Update agent prompts to guide when to use task breakdown
4. **Test Thoroughly**: Validate that task breakdown improves analysis quality

## Troubleshooting

### Tool Not Being Used

- Check that the tool is connected to the agent
- Verify the tool description is clear
- Review agent prompts to encourage tool usage
- Check API connectivity and credentials

### Tool Errors

- Verify MCP server endpoint is accessible
- Check API key validity
- Review error logs in n8n execution
- Test MCP server independently
