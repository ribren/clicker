#!/bin/zsh
# Freeze pyatv + Python into vendor/atvbridge with PyInstaller, so the app
# bundle is self-contained (no system pyatv needed). Output: vendor/atvbridge/.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -x .venv/bin/python ]; then
    echo "==> Creating build venv (needs python3.13; pyatv breaks on 3.14)..."
    python3.13 -m venv .venv
    .venv/bin/pip install --quiet pyatv
fi
.venv/bin/pip show pyinstaller >/dev/null 2>&1 || .venv/bin/pip install --quiet pyinstaller

echo "==> Freezing pyatv bridge..."
rm -rf vendor/atvbridge
.venv/bin/pyinstaller --noconfirm --onedir --console --name atvbridge \
    --collect-all pyatv \
    --distpath vendor --workpath .pybuild/work --specpath .pybuild \
    tools/atvbridge.py >/dev/null

echo "==> Smoke test..."
vendor/atvbridge/atvbridge atvremote --version
echo "==> Bridge ready at vendor/atvbridge"
