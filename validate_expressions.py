import json
import re

def validate_expressions(file_path):
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            workflow = json.load(f)
        
        print("🔍 Checking n8n expressions in workflow...")
        
        expression_pattern = r'\{\{[^}]*\}\}|=\{[^}]*\}'
        bracket_issues = []
        
        def check_expressions_in_text(text, context):
            if not isinstance(text, str):
                return
            
            # Check for unbalanced brackets
            open_brackets = text.count('{{')
            close_brackets = text.count('}}')
            
            if open_brackets != close_brackets:
                bracket_issues.append({
                    'context': context,
                    'text': text[:200] + '...' if len(text) > 200 else text,
                    'open_brackets': open_brackets,
                    'close_brackets': close_brackets
                })
            
            # Check for malformed expressions
            malformed_expressions = re.findall(r'\{[^{}]*(?:\{[^{}]*|[^}]*\})[^{}]*\}', text)
            if malformed_expressions:
                print(f"⚠️  Found potentially malformed expressions in {context}:")
                for expr in malformed_expressions[:3]:  # Show first 3
                    print(f"   - {expr}")
        
        # Check all nodes for expressions
        for node in workflow.get('nodes', []):
            node_name = node.get('name', 'Unnamed')
            node_type = node.get('type', 'Unknown')
            
            # Check parameters
            params = node.get('parameters', {})
            for param_key, param_value in params.items():
                if isinstance(param_value, str):
                    check_expressions_in_text(param_value, f"{node_name} -> {param_key}")
                elif isinstance(param_value, dict):
                    # Check nested objects
                    for nested_key, nested_value in param_value.items():
                        if isinstance(nested_value, str):
                            check_expressions_in_text(nested_value, f"{node_name} -> {param_key}.{nested_key}")
        
        if bracket_issues:
            print("❌ Found bracket imbalance issues:")
            for issue in bracket_issues:
                print(f"   - {issue['context']}: {issue['open_brackets']} opening vs {issue['close_brackets']} closing brackets")
                print(f"     Sample: {issue['text']}")
        else:
            print("✅ No bracket imbalance issues found")
        
        return len(bracket_issues) == 0
        
    except Exception as e:
        print(f"❌ Error validating expressions: {e}")
        return False

if __name__ == "__main__":
    import sys
    file_path = sys.argv[1] if len(sys.argv) > 1 else "edb_health_workflow.json"
    success = validate_expressions(file_path)
    sys.exit(0 if success else 1)