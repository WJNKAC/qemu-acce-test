#!/bin/bash
# 已迁移到 ../output/scripts/run-bench.sh（三方微基准的唯一版本）。
# 这里保留一层转发，免得旧习惯的路径失效。
exec "$(cd "$(dirname "$0")/.." && pwd)/output/scripts/run-bench.sh" "$@"
