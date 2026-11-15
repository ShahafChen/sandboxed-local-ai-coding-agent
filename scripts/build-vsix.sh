#!/bin/bash
# Package the extension as a .vsix with plain zip (no npm/vsce, so nothing is fetched).
set -euo pipefail
src=$(cd "$1" && pwd); out=$(python3 -c 'import os,sys;print(os.path.abspath(sys.argv[1]))' "$2")
ver=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$src/package.json")
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/extension"; cp "$src"/package.json "$src"/extension.js "$tmp/extension/"
cat > "$tmp/[Content_Types].xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension=".json" ContentType="application/json"/><Default Extension=".js" ContentType="application/javascript"/><Default Extension=".vsixmanifest" ContentType="text/xml"/></Types>
XML
cat > "$tmp/extension.vsixmanifest" <<XML
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id="local-agent-chat" Version="$ver" Publisher="local"/>
    <DisplayName>Local Agent Chat</DisplayName>
    <Description xml:space="preserve">Read-only chat with the sandboxed local Ollama agent.</Description>
    <Properties><Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.80.0"/></Properties>
  </Metadata>
  <Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation>
  <Dependencies/>
  <Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/></Assets>
</PackageManifest>
XML
rm -f "$out"; (cd "$tmp" && zip -qr "$out" '[Content_Types].xml' extension.vsixmanifest extension)
echo "built $out"
