#!/usr/bin/env bash
# Forward to root deploy.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DEPLOY="$(cd "${SCRIPT_DIR}/../.." && pwd)/deploy.sh"
if [ -f "${ROOT_DEPLOY}" ]; then
  exec bash "${ROOT_DEPLOY}" "$@"
else
  echo "Error: deploy.sh not found at ${ROOT_DEPLOY}" >&2
  exit 1
fi
