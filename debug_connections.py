import json

# Load the workflow
with open('edb_health_workflow.json', 'r') as f:
    workflow = json.load(f)

# Check the connection structure
print("=== Connection Structure Debug ===")
parse_metric_data_name = 'Parse Metric Data'
parse_metric_connections = workflow['connections'].get(parse_metric_data_name, [])

print(f"Parse Metric Data connections: {len(parse_metric_connections)}")
for i, target_list in enumerate(parse_metric_connections):
    print(f"  Target list {i}: {type(target_list)} - {target_list}")
    if isinstance(target_list, list):
        for j, connection in enumerate(target_list):
            print(f"    Connection {j}: {type(connection)} - {connection}")
            if isinstance(connection, dict):
                print(f"      Node: {connection.get('node')}")
                print(f"      Type: {connection.get('type')}")

# Check agent connections
print("\n=== Agent Connections Debug ===")
agent_name = 'System Health Agent'
agent_connections = workflow['connections'].get(agent_name, {})
print(f"System Health Agent connections: {type(agent_connections)} - {agent_connections}")

if isinstance(agent_connections, dict):
    ai_output_parser = agent_connections.get('ai_outputParser', [])
    print(f"AI Output Parser connections: {type(ai_output_parser)} - {ai_output_parser}")
    for i, target_list in enumerate(ai_output_parser):
        print(f"  Target list {i}: {type(target_list)} - {target_list}")
        if isinstance(target_list, list):
            for j, connection in enumerate(target_list):
                print(f"    Connection {j}: {type(connection)} - {connection}")
                if isinstance(connection, dict):
                    print(f"      Node: {connection.get('node')}")
                    print(f"      Type: {connection.get('type')}")