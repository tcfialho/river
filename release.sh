#!/usr/bin/env bash
# Script para compilação e instalação otimizada do River com suporte ao Xwayland

set -euo pipefail

echo "Iniciando compilação do River (ReleaseFast + Xwayland)..."
zig build -Dllvm -Doptimize=ReleaseFast -Dxwayland --prefix ~/.local install --summary all
echo "River instalado com sucesso em ~/.local/bin/river"
