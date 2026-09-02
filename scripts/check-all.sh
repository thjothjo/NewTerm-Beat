#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/check-login-helper.sh
bash scripts/check-ssh.sh
bash scripts/check-io.sh
bash scripts/check-storage.sh
bash scripts/check-data-models.sh

while IFS= read -r file; do
	plutil -lint "$file" >/dev/null
done < <(find Resources -type f \( -name '*.strings' -o -name '*.stringsdict' \) -print)

echo "all regression checks passed"
