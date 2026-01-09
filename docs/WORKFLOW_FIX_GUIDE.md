# n8n Workflow Connection Fix Guide

## Critical Issue: AI Agent Connections

The workflow has AI agents that require proper connections to language models and output parsers. These connections must be made in the n8n UI.

## Manual Fix Instructions

### Step 1: Connect Language Models to All AI Agents

1. Open the workflow in n8n
2. Locate the **"OpenAI Chat Model"** node
3. For each AI Agent node, you need to connect the language model:

**For each of these agents:**
- System Health Agent
- DB Performance Agent
- Backup Recovery Agent
- Security Compliance Agent
- Storage Capacity Agent
- Consolidation AI Agent

**Connection Steps:**
1. Click on **"OpenAI Chat Model"** node
2. Look for the **AI Language Model** output port (not the main output)
3. Drag a connection from this port to each AI Agent node
4. When connecting, ensure you're connecting to the **AI Language Model** input port (not main input)
5. The connection type should be `ai_languageModel`

### Step 2: Connect Output Parser to All AI Agents

1. Locate the **"format_final_json_response"** node
2. For each AI Agent node:

**Connection Steps:**
1. Click on **"format_final_json_response"** node
2. Look for the **AI Output Parser** output port
3. Drag a connection from this port to each AI Agent node
4. When connecting, ensure you're connecting to the **AI Output Parser** input port
5. The connection type should be `ai_outputParser`

### Step 3: Connect Memory to All AI Agents

1. Locate the **"Postgres Chat Memory"** node
2. Connect it to all AI Agent nodes via the **AI Memory** connection type

### Step 4: Connect Task Breakdown Tool (Optional)

1. Locate the **"Postgres PGVector Store Retrieve"** node
2. Connect it to **"Consolidation AI Agent"** via the **AI Tool** connection type
3. This enables the consolidation agent to use the knowledge base retriever

## Verification Checklist

After making connections, verify:

- [ ] OpenAI Chat Model → All 6 AI Agents (ai_languageModel)
- [ ] format_final_json_response → All 6 AI Agents (ai_outputParser)
- [ ] Postgres Chat Memory → All 6 AI Agents (ai_memory)
- [ ] Postgres PGVector Store Retrieve → Consolidation AI Agent (ai_tool)

## Testing Connections

1. Save the workflow
2. Click "Execute Workflow" with test data
3. Check execution logs:
   - Each AI agent should receive data
   - Each AI agent should produce output
   - No connection errors should appear

## Common Connection Issues

### Issue: "Missing language model connection"
**Solution**: Ensure OpenAI Chat Model is connected via `ai_languageModel` port, not `main` port

### Issue: "Missing output parser connection"
**Solution**: Ensure format_final_json_response is connected via `ai_outputParser` port, not `main` port

### Issue: Agents not executing
**Solution**: Check that connections are to the correct input ports (AI-specific ports, not main data ports)

## Automated Fix (Using n8n API)

If you have n8n API access, you can use the provided fix script or update the workflow programmatically using the n8n MCP tools.

## Connection Diagram

```
OpenAI Chat Model (ai_languageModel output)
    ├──→ System Health Agent (ai_languageModel input)
    ├──→ DB Performance Agent (ai_languageModel input)
    ├──→ Backup Recovery Agent (ai_languageModel input)
    ├──→ Security Compliance Agent (ai_languageModel input)
    ├──→ Storage Capacity Agent (ai_languageModel input)
    └──→ Consolidation AI Agent (ai_languageModel input)

format_final_json_response (ai_outputParser output)
    ├──→ System Health Agent (ai_outputParser input)
    ├──→ DB Performance Agent (ai_outputParser input)
    ├──→ Backup Recovery Agent (ai_outputParser input)
    ├──→ Security Compliance Agent (ai_outputParser input)
    ├──→ Storage Capacity Agent (ai_outputParser input)
    └──→ Consolidation AI Agent (ai_outputParser input)

Postgres Chat Memory (ai_memory output)
    ├──→ System Health Agent (ai_memory input)
    ├──→ DB Performance Agent (ai_memory input)
    ├──→ Backup Recovery Agent (ai_memory input)
    ├──→ Security Compliance Agent (ai_memory input)
    ├──→ Storage Capacity Agent (ai_memory input)
    └──→ Consolidation AI Agent (ai_memory input)

Postgres PGVector Store Retrieve (ai_tool output)
    └──→ Consolidation AI Agent (ai_tool input)
```

## Notes

- **DO NOT** connect via main data ports for AI connections
- AI connections use special port types: `ai_languageModel`, `ai_outputParser`, `ai_memory`, `ai_tool`
- Main data flow uses `main` ports
- These are separate connection types in n8n
