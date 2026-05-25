#!/bin/bash

# Script to extract all .nbt files from JAR files sorted by mod
# Usage: ./extract_nbt.sh [source_directory] [output_directory]
# If source_directory is omitted, uses current script directory
# If output_directory is omitted, creates nbt_extracted in current directory

SOURCE_DIR="${1:-.}"
OUTPUT_DIR="${2:-.}/nbt_extracted"

# If SOURCE_DIR is relative, make it absolute
if [[ ! "$SOURCE_DIR" = /* ]]; then
    SOURCE_DIR="$(cd "$SOURCE_DIR" 2>/dev/null && pwd)" || {
        echo "Error: Source directory '$1' not found"
        exit 1
    }
fi

CURRENT_DIR="$SOURCE_DIR"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Counter for statistics
total_jars=0
total_nbt_files=0

# Find all JAR files in the current directory
for jar_file in "$CURRENT_DIR"/*.jar; do
    # Skip if no jar files found
    if [[ ! -f "$jar_file" ]]; then
        continue
    fi
    
    # Get the jar filename without path and extension
    jar_name=$(basename "$jar_file" .jar)
    
    # Create mod-specific output directory
    mod_dir="$OUTPUT_DIR/$jar_name"
    mkdir -p "$mod_dir"
    
    echo "Processing: $jar_name"
    
    # Extract all .nbt files from the jar
    nbt_count=$(unzip -l "$jar_file" 2>/dev/null | grep -i '\.nbt$' | wc -l)
    
    if [[ $nbt_count -gt 0 ]]; then
        unzip -q "$jar_file" "*.nbt" -d "$mod_dir" 2>/dev/null || true
        # Flatten directory structure - move all nested .nbt files to mod root
        find "$mod_dir" -type f -name "*.nbt" 2>/dev/null | while read -r file; do
            # Skip if already in root
            if [[ "$(dirname "$file")" == "$mod_dir" ]]; then
                continue
            fi
            
            filename=$(basename "$file")
            target="$mod_dir/$filename"
            
            # Handle naming conflicts
            if [[ -f "$target" ]]; then
                base="${target%.nbt}"
                counter=2
                while [[ -f "${base}_$counter.nbt" ]]; do
                    ((counter++))
                done
                mv "$file" "${base}_$counter.nbt" 2>/dev/null || true
            else
                mv "$file" "$target" 2>/dev/null || true
            fi
        done
        # Remove empty subdirectories
        find "$mod_dir" -type d -empty -delete 2>/dev/null || true
        echo "  ✓ Extracted $nbt_count .nbt files"
        ((total_nbt_files += nbt_count))
        ((total_jars++))
    else
        echo "  ✗ No .nbt files found"
        # Remove empty directory
        rmdir "$mod_dir" 2>/dev/null || true
    fi
done

echo ""
echo "================================================"
echo "Summary:"
echo "  Total JARs processed: $total_jars"
echo "  Total NBT files extracted: $total_nbt_files"
echo "  Output directory: $OUTPUT_DIR"
echo "================================================"

# Sort files by mod
echo ""
echo "NBT files organized by mod:"
find "$OUTPUT_DIR" -type d -mindepth 1 -maxdepth 1 2>/dev/null | sort | while read mod_dir; do
    mod_name=$(basename "$mod_dir")
    file_count=$(find "$mod_dir" -name "*.nbt" | wc -l)
    echo "  $mod_name: $file_count files"
done
