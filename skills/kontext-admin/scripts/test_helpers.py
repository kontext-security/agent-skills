"""Use the helper's own cache context in both regression scripts."""
from pathlib import Path
import subprocess


def token_path(env):
    script = Path(__file__).with_name("kontext-context.sh")
    result = subprocess.run(["bash", "-c", 'source "$1"; printf "%s" "$TOKEN_FILE"', "bash", str(script)], env=env, check=True, capture_output=True, text=True)
    return Path(result.stdout)
