#!/bin/sh
# scan.sh <png> -> white px counts in the 8px edge strips
f="$1"
read W H <<EOF
$(identify -format '%w %h' "$f")
EOF
r=$(convert "$f" -crop 8x${H}+$((W-8))+0 -depth 8 txt:- 2>/dev/null | tail -n +2 | awk -F'[(),]' '{if($2>240&&$3>240&&$4>240)n++}END{print n+0}')
b=$(convert "$f" -crop ${W}x8+0+$((H-8)) -depth 8 txt:- 2>/dev/null | tail -n +2 | awk -F'[(),]' '{if($2>240&&$3>240&&$4>240)n++}END{print n+0}')
l=$(convert "$f" -crop 8x${H}+0+0 -depth 8 txt:- 2>/dev/null | tail -n +2 | awk -F'[(),]' '{if($2>240&&$3>240&&$4>240)n++}END{print n+0}')
t=$(convert "$f" -crop ${W}x8+0+0 -depth 8 txt:- 2>/dev/null | tail -n +2 | awk -F'[(),]' '{if($2>240&&$3>240&&$4>240)n++}END{print n+0}')
echo "${W}x${H} whitepx right=$r bottom=$b left=$l top=$t"
