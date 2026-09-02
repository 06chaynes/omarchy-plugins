#!/bin/bash

shopt -s nullglob

for hwmon in /sys/class/hwmon/hwmon*; do
  [[ -r "$hwmon/name" ]] || continue
  IFS= read -r name <"$hwmon/name"
  [[ "$name" == "coretemp" || "$name" == "k10temp" || "$name" == "zenpower" ]] || continue

  selected=""
  for label_file in "$hwmon"/temp*_label; do
    IFS= read -r label <"$label_file"
    if [[ "$label" == "Package id 0" || "$label" == "Tctl" ]]; then
      candidate="${label_file%_label}_input"
      [[ -r "$candidate" ]] && selected="$candidate"
      break
    fi
  done

  if [[ -z "$selected" ]]; then
    for candidate in "$hwmon"/temp*_input; do
      [[ -r "$candidate" ]] && selected="$candidate" && break
    done
  fi

  if [[ -n "$selected" ]]; then
    printf 'cpu_temp\t%s\n' "$selected"
    break
  fi
done

for block_path in /sys/class/block/*; do
  device="${block_path##*/}"
  [[ -e "$block_path/partition" ]] && continue
  [[ -e "$block_path/device" ]] || continue
  case "$device" in
    loop*|ram*|zram*|fd*|sr*) continue ;;
  esac
  printf 'disk\t%s\n' "$device"
done

# GPU: pick the card with the most VRAM so a discrete card wins over an
# integrated one on hybrid systems. gpu_busy_percent is amdgpu-only; other
# drivers simply yield no lines and the panel hides the section.
best_vram=0
best_card=""
for card in /sys/class/drm/card*/device; do
  [[ -r "$card/gpu_busy_percent" ]] || continue
  vram=0
  [[ -r "$card/mem_info_vram_total" ]] && IFS= read -r vram <"$card/mem_info_vram_total"
  [[ "$vram" =~ ^[0-9]+$ ]] || vram=0
  if (( vram > best_vram )); then
    best_vram=$vram
    best_card=$card
  fi
done

if [[ -n "$best_card" ]]; then
  printf 'gpu_busy\t%s\n' "$best_card/gpu_busy_percent"
  [[ -r "$best_card/mem_info_vram_used" ]] && printf 'gpu_vram_used\t%s\n' "$best_card/mem_info_vram_used"
  [[ -r "$best_card/mem_info_vram_total" ]] && printf 'gpu_vram_total\t%s\n' "$best_card/mem_info_vram_total"
  for hwmon in "$best_card"/hwmon/hwmon*; do
    [[ -r "$hwmon/temp1_input" ]] && printf 'gpu_temp\t%s\n' "$hwmon/temp1_input"
    [[ -r "$hwmon/power1_average" ]] && printf 'gpu_power\t%s\n' "$hwmon/power1_average"
    break
  done
  # Marketing name if lspci is present; the driver name is the fallback.
  slot="$(basename "$(readlink -f "$best_card")")"
  name=""
  if command -v lspci >/dev/null 2>&1; then
    name="$(lspci -s "$slot" 2>/dev/null | sed -E 's/^[^ ]+ [^:]+: //; s/ \(rev [^)]*\)$//' | head -1)"
  fi
  [[ -z "$name" && -r "$best_card/uevent" ]] && name="$(sed -n 's/^DRIVER=//p' "$best_card/uevent")"
  [[ -n "$name" ]] && printf 'gpu_name\t%s\n' "$name"
fi
