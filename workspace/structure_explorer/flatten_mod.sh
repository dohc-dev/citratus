#!/bin/bash
# Simple script to flatten a mod directory

mod_dir="$1"

if [[ ! -d "$mod_dir" ]]; then
    echo "Usage: $0 <mod_directory>"
    exit 1
fi

# Find all NBT files that aren't in root and move them
find "$mod_dir" -type f -name "*.nbt" | while read file; do
    # Skip if already in root
    if [[ "$(dirname "$file")" == "$mod_dir" ]]; then
        continue
    fi
    
    filename=$(basename "$file")
    target="$mod_dir/$filename"
    
    # Handle conflicts
    if [[ -f "$target" ]]; then
        base="${target%.nbt}"
        counter=2
        while [[ -f "${base}_$counter.nbt" ]]; do
            ((counter++))
        done
        mv "$file" "${base}_$counter.nbt"
    else
        mv "$file" "$target"
    fi
done

# Remove empty directories
find "$mod_dir" -type d -mindepth 1 -empty -delete

echo "Flattened $mod_dir"
echo "File count: $(find "$mod_dir" -type f -name "*.nbt" | wc -l)"
