#!/bin/bash
# Script to flatten a mod directory - move all .nbt files to root

mod_dir="$1"

if [[ ! -d "$mod_dir" ]]; then
    echo "Usage: $0 <mod_directory>"
    exit 1
fi

# Process all NBT files using while loop without piping (avoid subshell issues)
processed=0
while IFS= read -r -d '' file; do
    # Skip if already in root
    dirpath="$(dirname "$file")"
    if [[ "$dirpath" == "$mod_dir" ]]; then
        continue
    fi
    
    filename=$(basename "$file")
    target="$mod_dir/$filename"
    
    # Handle conflicts by appending counter
    if [[ -f "$target" ]]; then
        base="${target%.nbt}"
        counter=2
        while [[ -f "${base}_$counter.nbt" ]]; do
            ((counter++))
        done
        target="${base}_$counter.nbt"
    fi
    
    # Move file
    if mv "$file" "$target" 2>/dev/null; then
        ((processed++))
    fi
done < <(find "$mod_dir" -type f -name "*.nbt" -print0)

# Remove empty directories recursively
find "$mod_dir" -type d -empty -delete 2>/dev/null

total=$(find "$mod_dir" -type f -name "*.nbt" 2>/dev/null | wc -l)
echo "Flattened: $mod_dir - Moved: $processed files, Total in root: $total"
