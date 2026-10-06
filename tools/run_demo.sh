#!/bin/zsh
# The AI-actor demo, end to end, on the CPU: for every <emotion>.mp4 in a clip folder, run the
# real engine (affect-replay) with and without the FER+ expert, score the readings against the
# prompted emotion, chart the confusion matrices and render the side-by-side videos.
#   tools/run_demo.sh <clips-dir> <out-dir> [FERPlus.mlpackage]
set -eu
root=${0:A:h:h}; clips=${1:A}; out=${2:A}; model=${3:-$root/Models/FERPlus.mlpackage}
mkdir -p $out/fused $out/geometry $out/video
swift build -c release --package-path $root >/dev/null
bin=$root/.build/release/affect-replay
for f in $clips/*.mp4; do
  emo=${f:t:r}
  [[ -f $model || -d $model ]] && $bin run $f --label $emo --model $model --out $out/fused/$emo.json
  $bin run $f --label $emo --out $out/geometry/$emo.json
done
args=(--geometry $out/geometry)
[[ -n $(ls $out/fused 2>/dev/null) ]] && args=(--fused $out/fused $args)
python3 $root/tools/score_clips.py $args -o $out/results.json
$root/tools/charts.py confusion $out/results.json $out
for f in $clips/*.mp4; do
  emo=${f:t:r}; r=$out/fused/$emo.json; [[ -f $r ]] || r=$out/geometry/$emo.json
  nice -n 10 $root/tools/render_demo.py $r $f $out/video/$emo.mp4
done
