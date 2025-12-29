import os
import argparse
import subprocess
import sys
from pathlib import Path
from datetime import datetime
import zipfile

INCLUDES = [
    "README.md",
    "collect_metrics.sh",
    "jwt_helper.py",
    "edb_health_workflow.json",
    ".env.example",
    "sample_metrics.json"
]

def build_zip(include_env: bool = False) -> Path:
    root = Path(__file__).parent
    dist = root / "dist"
    dist.mkdir(exist_ok=True)

    files_to_include = list(INCLUDES)
    if include_env:
        env_path = root / ".env"
        if env_path.exists():
            files_to_include.append(".env")
        else:
            print("[WARN] .env file requested but not found.")

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    zip_path = dist / f"edb-monitoring-deploy-{timestamp}.zip"

    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for rel in files_to_include:
            src = root / rel
            if src.exists():
                zf.write(src, arcname=rel)
                print(f"[INFO] Added: {rel}")
            else:
                print(f"[WARN] Missing file, skipping: {rel}")

    return zip_path

def deploy_package(zip_path: Path, target: str, remote_path: str = "/tmp", identity_file: str = None):
    """
    Deploy the package to a remote server using scp.
    target: user@host
    identity_file: Path to SSH private key file
    """
    print(f"\n[INFO] Deploying {zip_path.name} to {target}:{remote_path}...")
    
    # Check for scp
    scp_cmd = "scp"
    if os.name == 'nt':
        # On Windows, scp might be available if OpenSSH is installed
        # Verify if scp is in path
        pass 

    try:
        cmd = [scp_cmd]
        if identity_file:
            cmd.extend(["-i", identity_file])
        
        cmd.extend([str(zip_path), f"{target}:{remote_path}"])
        
        print(f"[DEBUG] Running command: {' '.join(cmd)}")
        subprocess.check_call(cmd)
        print(f"[SUCCESS] Deployed to {target}")
        
        ssh_cmd = f"ssh"
        if identity_file:
            ssh_cmd += f" -i {identity_file}"
        
        print(f"Run on remote: {ssh_cmd} {target} 'cd {remote_path} && unzip {zip_path.name} && chmod +x collect_metrics.sh'")
    except subprocess.CalledProcessError as e:
        print(f"[ERROR] Deployment failed: {e}")
        sys.exit(1)
    except FileNotFoundError:
        print("[ERROR] 'scp' command not found. Please ensure OpenSSH Client is installed.")
        sys.exit(1)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Build and optionally deploy EDB monitoring package")
    parser.add_argument("--include-env", action="store_true", help="Include .env file in the package (WARNING: Sensitive data)")
    parser.add_argument("--deploy", metavar="USER@HOST", help="Deploy the package to a remote server via SCP")
    parser.add_argument("--remote-path", default="/tmp", help="Remote path to deploy to (default: /tmp)")
    parser.add_argument("-i", "--identity-file", help="Path to SSH private key file for authentication")
    
    args = parser.parse_args()

    zip_file = build_zip(include_env=args.include_env)
    print(f"\nDeployment package created: {zip_file}")

    if args.deploy:
        deploy_package(zip_file, args.deploy, args.remote_path, args.identity_file)
