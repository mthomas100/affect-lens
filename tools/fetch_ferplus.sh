#!/bin/zsh
# Builds the optional FER+ appearance expert locally: downloads Microsoft's emotion-ferplus-8
# ONNX model from the ONNX Model Zoo (MIT per its model card) and converts it to
# Models/FERPlus.mlpackage with tools/convert_ferplus.py. The model is not shipped in this
# repo because it was trained on FER2013 images, whose redistribution terms are unclear;
# see README "Credits and licences". Needs uv; downloads ~35 MB plus the Python deps.
set -eu
root=${0:A:h:h}
work=$(mktemp -d)
trap 'rm -rf $work' EXIT
# Pinned to the ONNX Model Zoo commit that last changed the file, and checked by hash.
commit=4c46cd00fbdb7cd30b6c1c17ab54f2e1f4f7b177
sha256=a2a2ba6a335a3b29c21acb6272f962bd3d47f84952aaffa03b60986e04efa61c
curl -fL -o $work/emotion-ferplus-8.onnx \
  https://github.com/onnx/models/raw/$commit/validated/vision/body_analysis/emotion_ferplus/model/emotion-ferplus-8.onnx
echo "$sha256  $work/emotion-ferplus-8.onnx" | shasum -a 256 -c -
cd $work
uv run --python 3.12 --with numpy --with onnx --with torch --with coremltools --with onnx2torch \
  python $root/tools/convert_ferplus.py
mkdir -p $root/Models
rm -rf $root/Models/FERPlus.mlpackage
mv FERPlus.mlpackage $root/Models/
echo "wrote $root/Models/FERPlus.mlpackage (rerun xcodegen generate so the app bundles it)"
