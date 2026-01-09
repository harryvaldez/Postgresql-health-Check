import json
import sys

def validate_workflow(file_path):
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            workflow = json.load(f)
        
        print("✅ Workflow JSON syntax is valid")
        
        # Basic workflow validation
        if 'name' not in workflow:
            print("❌ Missing workflow name")
        else:
            print(f"📋 Workflow name: {workflow['name']}")
        
        # Node validation
        if 'nodes' not in workflow:
            print("❌ No nodes found in workflow")
            return False
        
        print(f"🔢 Total nodes: {len(workflow['nodes'])}")
        
        # Check for disabled nodes
        disabled_nodes = [node for node in workflow['nodes'] if node.get('disabled')]
        if disabled_nodes:
            print(f"⚠️  Found {len(disabled_nodes)} disabled nodes:")
            for node in disabled_nodes:
                print(f"   - {node.get('name', 'Unnamed')} ({node.get('type')})")
        
        # Connections validation
        if 'connections' not in workflow:
            print("❌ No connections found in workflow")
            return False
        
        # Check for nodes without connections
        connected_nodes = set()
        for source_node, connections in workflow['connections'].items():
            connected_nodes.add(source_node)
            for connection_type, connection_list in connections.items():
                for connection in connection_list:
                    for target in connection:
                        if 'node' in target:
                            connected_nodes.add(target['node'])
        
        all_node_names = {node.get('name') for node in workflow['nodes'] if node.get('name')}
        unconnected_nodes = all_node_names - connected_nodes
        
        if unconnected_nodes:
            print(f"⚠️  Found {len(unconnected_nodes)} potentially unconnected nodes:")
            for node_name in unconnected_nodes:
                print(f"   - {node_name}")
        
        # Check AI agent configurations
        ai_agents = [node for node in workflow['nodes'] if 'agent' in node.get('type', '').lower()]
        print(f"🤖 Found {len(ai_agents)} AI agent nodes:")
        for agent in ai_agents:
            print(f"   - {agent.get('name')} ({agent.get('type')})")
            
            # Check for output parser configuration
            params = agent.get('parameters', {})
            if params.get('hasOutputParser'):
                print(f"     ✅ Has output parser configured")
            else:
                print(f"     ⚠️  No output parser configured")
        
        # Check for empty connections
        empty_connections = []
        for source_node, connections in workflow['connections'].items():
            for connection_type, connection_list in connections.items():
                for connection in connection_list:
                    if not connection:
                        empty_connections.append((source_node, connection_type))
        
        if empty_connections:
            print(f"⚠️  Found {len(empty_connections)} empty connections:")
            for source, conn_type in empty_connections:
                print(f"   - {source} -> {conn_type} (empty)")
        
        print("✅ Workflow validation completed")
        return True
        
    except json.JSONDecodeError as e:
        print(f"❌ JSON syntax error: {e}")
        return False
    except Exception as e:
        print(f"❌ Error reading workflow: {e}")
        return False

if __name__ == "__main__":
    if len(sys.argv) > 1:
        file_path = sys.argv[1]
    else:
        file_path = "edb_health_workflow.json"
    
    success = validate_workflow(file_path)
    sys.exit(0 if success else 1)