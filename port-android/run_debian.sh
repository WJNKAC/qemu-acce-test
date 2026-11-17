#!/bin/bash
# 已迁移到 ../output/scripts/run-debian.sh（部署脚本都在 output/ 里）。
exec "$(cd "$(dirname "$0")/.." && pwd)/output/scripts/run-debian.sh" "$@"
