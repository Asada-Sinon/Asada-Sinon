#!/usr/bin/env bash
#
# Snapshot the remote stat cards into assets/ as self-contained SVGs.
#
# Why: GitHub proxies external README images through camo.githubusercontent.com,
# which gives up after a few seconds. streak-stats.demolab.com runs on a Heroku
# dyno that sleeps and needs ~25s to wake, so the card intermittently rendered
# as a broken image. Images referenced by a relative repo path are served
# directly from /raw/ and never touch camo, so committing the SVGs makes the
# profile render deterministically.
#
# A card is only overwritten when the download both parses as SVG and contains
# the marker text that a successful render always produces -- an error card or a
# truncated response leaves the previously committed (stale but valid) file in
# place.

set -uo pipefail

cd "$(dirname "$0")/.."
mkdir -p assets

# name | marker text that must appear in a successful render | url
CARDS=(
  "typing|Weibin|https://readme-typing-svg.demolab.com?font=Fira+Code&weight=500&size=28&pause=1000&color=58A6FF&vCenter=true&width=435&lines=I'm+Weibin+Kong"
  "stats|GitHub Stats|https://github-readme-stats-ins.vercel.app/api?username=Asada-Sinon&show_icons=true&hide_border=true&theme=tokyonight"
  "streak|Total Contributions|https://streak-stats.demolab.com?user=Asada-Sinon&theme=tokyonight&hide_border=true"
)

missing=0
refreshed=0
degraded=0

for card in "${CARDS[@]}"; do
  name="${card%%|*}"
  rest="${card#*|}"
  marker="${rest%%|*}"
  url="${rest#*|}"
  dest="assets/${name}.svg"
  tmp="$(mktemp)"

  # Generous budget on purpose: a cold Heroku dyno takes ~25s to answer, and
  # unlike camo we can afford to wait.
  code="$(curl -sS -L \
    --connect-timeout 20 --max-time 90 \
    --retry 3 --retry-delay 5 --retry-all-errors \
    -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null)"

  size="$(wc -c < "$tmp")"

  if [[ "$code" != "200" ]]; then
    reason="HTTP $code"
  elif (( size < 500 )); then
    reason="response too small (${size}B)"
  elif ! grep -qi '<svg' "$tmp"; then
    reason="not an SVG"
  elif ! grep -qF "$marker" "$tmp"; then
    reason="missing marker '$marker' (error card?)"
  else
    reason=""
  fi

  if [[ -z "$reason" ]]; then
    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
      echo "unchanged  $dest (${size}B)"
    else
      mv "$tmp" "$dest"
      chmod 644 "$dest"
      echo "refreshed  $dest (${size}B)"
      refreshed=$((refreshed + 1))
    fi
  elif [[ -f "$dest" ]]; then
    echo "KEPT OLD   $dest -- fetch failed: $reason"
    degraded=$((degraded + 1))
  else
    echo "MISSING    $dest -- fetch failed: $reason, and no committed copy exists"
    missing=$((missing + 1))
  fi

  rm -f "$tmp"
done

echo "---"
echo "refreshed=$refreshed degraded=$degraded missing=$missing"

# A failed fetch is tolerable -- the committed card just goes stale, and the
# profile still renders. Having no card at all is not.
if (( missing > 0 )); then
  echo "FAIL: $missing card(s) have no usable file" >&2
  exit 1
fi
