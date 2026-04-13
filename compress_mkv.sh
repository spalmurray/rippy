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

output_sdr=false
overwrite=false
input_path=""

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --sdr)
            output_sdr=true
            ;;
        --overwrite)
            overwrite=true
            ;;
        *)
            if [ -z "$input_path" ]; then
                input_path="$1"
            else
                echo "Error: Unexpected argument '$1'"
                exit 1
            fi
            ;;
    esac
    shift
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
    done < <(find "$input_path" -maxdepth 2 -type f -name "*.mkv" -print0)

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

# Check if input file is actually an MKV (single file mode only)
if [ -f "$input_path" ] && [[ ! "$input_path" =~ \.mkv$ ]]; then
    echo "Warning: Input file doesn't have .mkv extension. Proceeding anyway..."
fi

# Detect if a file has HDR color transfer characteristics
is_hdr() {
    local transfer
    transfer=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of csv=s=x:p=0 "$1" 2>/dev/null)
    # smpte2084 = PQ (HDR10), arib-std-b67 = HLG
    [[ "$transfer" == "smpte2084" || "$transfer" == "arib-std-b67" ]]
}

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

    if $output_sdr && is_hdr "$input_path"; then
        mode_text="SDR output (HDR→SDR tone mapping)"
    elif is_hdr "$input_path"; then
        mode_text="HDR10 passthrough"
    else
        mode_text="SDR output"
    fi

    echo "======================================"
    echo "MKV Compression Tool"
    echo "======================================"
    echo "Input:  $input_path"
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
    fi

    echo "Starting compression..."

    # Write to a temp file, then replace the original
    input_dir=$(dirname "$input_file")
    tmp_output=$(mktemp "${input_dir}/compress_mkv_XXXXXX.mkv")
    rm "$tmp_output"

    # Get bitrate based on resolution
    bitrate=$(get_bitrate "$input_file")

    # Detect if input is HDR
    input_is_hdr=false
    if is_hdr "$input_file"; then
        input_is_hdr=true
    fi

    # Determine output mode
    if $output_sdr && $input_is_hdr; then
        echo "Mode: SDR output (HDR→SDR tone mapping)"
        ffmpeg -i "$input_file" \
            -map 0 \
            -b:v "$bitrate" \
            -vf "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p" \
            -c:v libx265 \
            -c:a copy \
            "$tmp_output"
    elif $input_is_hdr; then
        echo "Mode: HDR10 passthrough (preserving HDR metadata)"
        ffmpeg -i "$input_file" \
            -map 0 \
            -b:v "$bitrate" \
            -c:v libx265 \
            -pix_fmt yuv420p10le \
            -color_primaries bt2020 \
            -color_trc smpte2084 \
            -colorspace bt2020nc \
            -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc" \
            -c:a copy \
            "$tmp_output"
    else
        echo "Mode: SDR output"
        ffmpeg -i "$input_file" -map 0 -b:v "$bitrate" -c:v libx265 -c:a copy "$tmp_output"
    fi

    # Move compressed file to final location
    if [ "$overwrite" = true ]; then
        mv "$tmp_output" "$input_file"
    else
        output_file="${input_file%.mkv}_compressed.mkv"
        mv "$tmp_output" "$output_file"
        echo "Output: $output_file"
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
fi
echo "======================================"