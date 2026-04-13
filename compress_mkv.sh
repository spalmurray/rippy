#!/usr/bin/env bash

# Script to compress MKV files to 10 Mbps MP4 using ffmpeg
# Supports both SDR and HDR output, including batch processing directories

set -e

# Check if a filename was provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <input> [--sdr]"
    echo ""
    echo "Options:"
    echo "  <input>       Path to input MKV file or directory"
    echo "  --sdr         Force SDR output (tone mapping from HDR input)"
    echo "                If not specified, outputs HDR10 (10-bit color)"
    echo ""
    echo "Note: Output is always in MKV format to preserve multiple audio tracks"
    echo ""
    echo "Examples:"
    echo "  $0 movie.mkv                           # Compress to HDR10"
    echo "  $0 movie.mkv --sdr                      # Compress to SDR (tone mapped)"
    echo "  $0 movie.mkv --overwrite               # Skip backup, overwrite existing output"
    echo "  $0 /path/to/show/                      # Compress all MKV files in directory"
    exit 1
fi

input_path="$1"
output_sdr=false
overwrite=false
shifted=false

# Check for --sdr and --overwrite flags
while [ $# -gt 0 ]; do
    case "$1" in
        --sdr)
            output_sdr=true
            shift
            ;;
        --overwrite)
            overwrite=true
            shift
            ;;
        *)
            input_path="$1"
            shift
            ;;
    esac
done

if [ -z "$input_path" ]; then
    echo "Error: No input path provided."
    exit 1
fi

# Check if the input exists
if [ ! -e "$input_path" ]; then
    echo "Error: Input path '$input_path' does not exist."
    exit 1
fi

# Get list of MKV files
if [ -d "$input_path" ]; then
    echo "======================================"
    echo "MKV Compression Tool"
    echo "======================================"
    echo "Directory mode detected"
    echo "Input:  $input_path"
    echo "Traversing up to 2 levels deep for MKV files..."

    # Find all .mkv files up to 2 levels deep
    mkv_files=()
    while IFS= read -r -d '' file; do
        mkv_files+=("$file")
    done < <(find "$input_path" -type f -name "*.mkv" -maxdepth 2 -print0)

    # Check if any files were found
    if [ ${#mkv_files[@]} -eq 0 ]; then
        echo "Error: No MKV files found in directory '$input_path'."
        exit 1
    fi

    echo "Found ${#mkv_files[@]} MKV file(s)"
    echo ""
    echo "Files to process:"
    for file in "${mkv_files[@]}"; do
        echo "  - $file"
    done
    echo ""

    # Ask for confirmation
    echo "Do you want to convert these files? (y/n)"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
    echo ""
    echo "Starting batch compression..."
    echo ""
else
    # Single file mode
    if [ ! -f "$input_path" ]; then
        echo "Error: Path '$input_path' is not a file."
        exit 1
    fi
    mkv_files=("$input_path")
fi

# Get the directory and filename
input_dir=$(dirname "$input_path")
input_name=$(basename "$input_path")

# Check if input file is actually an MKV
if [[ ! "$input_file" =~ \.mkv$ ]]; then
    echo "Warning: Input file doesn't have .mkv extension. Proceeding anyway..."
fi

# Output file path
output_file="${input_dir}/${input_name}.mkv"

# Handle existing output file
if [ -f "$output_file" ]; then
    if [ "$overwrite" = true ]; then
        echo "Overwriting existing file: $output_file"
    else
        old_output="${output_file}.old"
        echo "Warning: Output file already exists: $output_file"
        echo "Moving to: $old_output"
        mv "$output_file" "$old_output"
        echo ""
    fi
fi

# Determine bitrate based on resolution
get_bitrate() {
    local resolution
    resolution=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$1" 2>/dev/null)

    if [ -z "$resolution" ]; then
        echo "10M"
        return
    fi

    local width height
    IFS='x' read -r width height <<< "$resolution"

    # Determine bitrate based on resolution
    if [ "$width" -ge 3840 ]; then
        echo "40M"  # 4K
    elif [ "$width" -ge 1920 ]; then
        echo "15M"  # 1080p
    else
        echo "10M"  # Lower resolutions
    fi
}

# Display compression info (for single file)
if [ ${#mkv_files[@]} -eq 1 ]; then
    bitrate=$(get_bitrate "$input_path")

    if $output_sdr; then
        mode_text="SDR output"
    else
        mode_text="HDR10 output"
    fi

    echo "======================================"
    echo "MKV Compression Tool"
    echo "======================================"
    echo "Input:  $input_path"
    echo "Output: $output_file"
    echo "Mode:   $mode_text"
    echo "Bitrate: $bitrate"
    echo "======================================"
    echo "Starting compression..."
fi

# Check if ffmpeg is installed
if ! command -v ffmpeg &> /dev/null; then
    echo "Error: ffmpeg is not installed. Please install it first."
    exit 1
fi

# Process files
total_files=${#mkv_files[@]}
success_count=0

for input_file in "${mkv_files[@]}"; do
    if [ ${#mkv_files[@]} -gt 1 ]; then
        echo ""
        echo "Processing file $((success_count + 1)) of $total_files:"
        echo "  $input_file"

        # Get output path
        input_dir=$(dirname "$input_file")
        input_name=$(basename "$input_file" .mkv)
        output_file="${input_dir}/${input_name}.mkv"
    fi

    echo "Starting compression..."

    # Get bitrate based on resolution
    bitrate=$(get_bitrate "$input_file")

    # Get resolution to determine HDR/SDR
    resolution=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$input_file" 2>/dev/null)

    if [ -z "$resolution" ]; then
        # Fallback to default if can't detect resolution
        resolution="1920x1080"
    fi

    local width height
    IFS='x' read -r width height <<< "$resolution"

    is_4k=false
    if [ "$width" -ge 3840 ]; then
        is_4k=true
    fi

    # Determine output mode
    if $output_sdr; then
        echo "Mode: SDR output (tone mapping enabled)"
        if $is_4k; then
            echo "Detected 4K input - applying HDR→SDR tone mapping"
            ffmpeg -i "$input_file" \
                -b:v "$bitrate" \
                -vf tonemap=tonemapping=reinhard:desat=0:peak=1.0 \
                -pix_fmt yuv420p \
                -c:v libx265 \
                "$output_file"
        else
            echo "Detected 1080p input - standard SDR compression"
            ffmpeg -i "$input_file" -b:v "$bitrate" -c:v libx265 "$output_file"
        fi
    else
        # No --sdr flag: assume 4K is HDR, 1080p is SDR
        if $is_4k; then
            echo "Mode: HDR10 output (4K input, 10-bit color)"
            ffmpeg -i "$input_file" \
                -b:v "$bitrate" \
                -c:v libx265 \
                -pix_fmt yuv420p10le \
                -color_primaries bt2020 \
                -color_trc smpte2084 \
                -colorspace bt2020nc \
                -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc" \
                "$output_file"
        else
            echo "Mode: SDR output (1080p input)"
            ffmpeg -i "$input_file" -b:v "$bitrate" -c:v libx265 "$output_file"
        fi
    fi

    success_count=$((success_count + 1))
    echo ""
done

echo ""
echo "======================================"
if [ ${#mkv_files[@]} -gt 1 ]; then
    echo "Batch compression complete!"
    echo "Processed: $success_count / $total_files files"
else
    echo "Compression complete!"
    echo "Output: $output_file"
fi
echo "======================================"