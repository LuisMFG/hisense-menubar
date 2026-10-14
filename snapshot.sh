#!/bin/bash
# Gera as imagens do README (docs/*.png) com dados fictícios — não fala com o ar de verdade.
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-docs}"; mkdir -p "$OUT" .build
swiftc -O -parse-as-library -o .build/snapshot \
  Sources/ArCondicionado/{ACStore,ConnectLifeAPI,Views,Effects}.swift Snapshot/Snapshot.swift
.build/snapshot "$OUT"
