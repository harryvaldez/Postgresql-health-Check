import json

def validate_workflow():
    """Validate the complete workflow structure"""
    
    with open('edb_health_workflow.json', 'r') as f:
        workflow = json.load(f)
    
    print("=== Workflow Validation Report ===")
    print(f"Workflow Name: {workflow['name']}")
    print(f"Total Nodes: {len(workflow['nodes'])}")
    print(f"Total Connections: {len(workflow['connections'])}")
    print()
    
    # Get all node IDs
    node_ids = [node['id'] for node in workflow['nodes']]
    print("Node IDs found:")
    for i, node_id in enumerate(node_ids, 1):
        node_name = next((n['name'] for n in workflow['nodes'] if n['id'] == node_id), 'Unknown')
        print(f"  {i:2d}. {node_name} ({node_id})")
    print()
    
    # Check connections
    print("Connection Analysis:")
    connection_counts = {}
    for source, targets in workflow['connections'].items():
        connection_counts[source] = len(targets)
        print(f"  {source} -> {len(targets)} target(s)")
    print()
    
    # Check for orphaned nodes (nodes with no incoming connections)
    orphaned_nodes = []
    for node_id in node_ids:
        has_incoming = False
        for source, targets in workflow['connections'].items():
            if isinstance(targets, list):
                for target_list in targets:
                    if isinstance(target_list, list):
                        for connection in target_list:
                            if isinstance(connection, dict) and connection.get('node') == node_id:
                                has_incoming = True
                                break
                        if has_incoming:
                            break
                    elif isinstance(target_list, dict) and target_list.get('node') == node_id:
                        has_incoming = True
                        break
                if has_incoming:
                    break
            if has_incoming:
                break
        
        if not has_incoming and node_id != '31867f0b-0a3b-4e5c-8ad2-1ce103d69f2a':  # Webhook is expected to have no incoming
            orphaned_nodes.append(node_id)
    
    if orphaned_nodes:
        print("⚠️  Orphaned nodes (no incoming connections):")
        for node_id in orphaned_nodes:
            node_name = next((n['name'] for n in workflow['nodes'] if n['id'] == node_id), 'Unknown')
            print(f"    - {node_name} ({node_id})")
    else:
        print("✓ No orphaned nodes found")
    print()
    
    # Check for nodes with no outgoing connections
    dead_end_nodes = []
    for node_id in node_ids:
        if node_id not in workflow['connections']:
            dead_end_nodes.append(node_id)
    
    if dead_end_nodes:
        print("⚠️  Dead-end nodes (no outgoing connections):")
        for node_id in dead_end_nodes:
            node_name = next((n['name'] for n in workflow['nodes'] if n['id'] == node_id), 'Unknown')
            print(f"    - {node_name} ({node_id})")
    else:
        print("✓ No dead-end nodes found")
    print()
    
    # Special validation for our new architecture
    expected_nodes = [
        'System Health Splitter',
        'DB Performance Splitter', 
        'Backup Recovery Splitter',
        'Security Compliance Splitter',
        'Storage Capacity Splitter',
        'System Health Agent',
        'DB Performance Agent',
        'Backup Recovery Agent',
        'Security Compliance Agent',
        'Storage Capacity Agent',
        'Consolidation Aggregator',
        'Consolidation AI Agent'
    ]
    
    missing_nodes = []
    for expected in expected_nodes:
        found = any(node['name'] == expected for node in workflow['nodes'])
        if not found:
            missing_nodes.append(expected)
    
    if missing_nodes:
        print("❌ Missing expected nodes:")
        for missing in missing_nodes:
            print(f"    - {missing}")
    else:
        print("✓ All expected nodes found")
    print()
    
    # Check data flow path
    print("Data Flow Path Validation:")
    try:
        # Check if Parse Metric Data feeds into all splitters
        parse_metric_data = workflow['connections'].get('Parse Metric Data', [])
        expected_splitters = [
            'System Health Splitter',
            'DB Performance Splitter',
            'Backup Recovery Splitter', 
            'Security Compliance Splitter',
            'Storage Capacity Splitter'
        ]
        
        splitter_connections = []
        for target_list in parse_metric_data:
            if isinstance(target_list, list):
                for connection in target_list:
                    if isinstance(connection, dict):
                        target_name = next((n['name'] for n in workflow['nodes'] if n['id'] == connection.get('node')), 'Unknown')
                        splitter_connections.append(target_name)
            elif isinstance(target_list, dict):
                target_name = next((n['name'] for n in workflow['nodes'] if n['id'] == target_list.get('node')), 'Unknown')
                splitter_connections.append(target_name)
        
        missing_splitters = [s for s in expected_splitters if s not in splitter_connections]
        if missing_splitters:
            print(f"⚠️  Missing splitter connections: {missing_splitters}")
        else:
            print("✓ All data splitters connected")
            
        # Check if all agents feed into consolidation
        consolidation_connections = []
        expected_agents = [
            'System Health Agent',
            'DB Performance Agent', 
            'Backup Recovery Agent',
            'Security Compliance Agent',
            'Storage Capacity Agent'
        ]
        
        for agent in expected_agents:
            agent_id = next((n['id'] for n in workflow['nodes'] if n['name'] == agent), None)
            if agent_id and agent_id in workflow['connections']:
                for target_list in workflow['connections'][agent_id]:
                    if isinstance(target_list, list):
                        for connection in target_list:
                            if isinstance(connection, dict) and connection.get('node') == 'consolidation-aggregator':
                                consolidation_connections.append(agent)
                                break
                    elif isinstance(target_list, dict) and target_list.get('node') == 'consolidation-aggregator':
                        consolidation_connections.append(agent)
        
        missing_agents = [a for a in expected_agents if a not in consolidation_connections]
        if missing_agents:
            print(f"⚠️  Missing agent consolidation connections: {missing_agents}")
        else:
            print("✓ All agents connected to consolidation")
            
    except Exception as e:
        print(f"⚠️  Error validating data flow: {e}")
    
    print()
    print("=== Validation Complete ===")

if __name__ == "__main__":
    validate_workflow()