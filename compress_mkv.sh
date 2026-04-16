#!/usr/bin/env bash

# Script to compress MKV files to 10 Mbps MP4 using ffmpeg
# Supports both SDR and HDR output, including batch processing directories

set -e

# Check if a filename was provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <input> [--sdr] [--gpu vaapi|qsv]"
    echo ""
    echo "Options:"
    echo "  <input>       Path to input MKV file or directory"
    echo "  --sdr         Force SDR output (tone mapping from HDR input)"
    echo "                If not specified, outputs HDR10 (10-bit color)"
    echo "  --gpu <type>  Use GPU hardware acceleration (vaapi, qsv, amf, or vulkan)"
    echo ""
    echo "Note: Output is always in MKV format to preserve multiple audio tracks"
    echo ""
    echo "Examples:"
    echo "  $0 movie.mkv                           # Compress to HDR10"
    echo "  $0 movie.mkv --sdr                      # Compress to SDR (tone mapped)"
    echo "  $0 movie.mkv --gpu vaapi                # Use AMD GPU"
    echo "  $0 movie.mkv --gpu qsv                  # Use Intel GPU"
    echo "  $0 movie.mkv --overwrite               # Skip backup, overwrite existing output"
    echo "  $0 /path/to/show/                      # Compress all MKV files in directory"
    exit 1
fi

output_sdr=false
overwrite=false
gpu=""
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
        --gpu)
            shift
            gpu="$1"
            if [[ "$gpu" != "vaapi" && "$gpu" != "qsv" && "$gpu" != "amf" && "$gpu" != "vulkan" ]]; then
                echo "Error: --gpu must be 'vaapi', 'qsv', 'amf', or 'vulkan'"
                exit 1
            fi
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

# Detect if a file has interlaced video
is_interlaced() {
    local field_order
    field_order=$(ffprobe -v error -select_streams v:0 -show_entries stream=field_order -of csv=s=x:p=0 "$1" 2>/dev/null)
    [[ "$field_order" == "tt" || "$field_order" == "bb" || "$field_order" == "tb" || "$field_order" == "bt" ]]
}

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
    elif [ "$width" -ge 1280 ]; then
        echo "8M"   # 720p
    else
        echo "3M"   # DVD (480p/576p)
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

    # Get bitrate based on resolution
    bitrate=$(get_bitrate "$input_file")

    # Skip if file bitrate is already at or near target
    target_bps=$(echo "$bitrate" | sed 's/M//' | awk '{printf "%.0f", $1 * 1000000}')
    file_bitrate=$(ffprobe -v error -show_entries format=bit_rate -of csv=p=0 "$input_file" 2>/dev/null)
    if [ -n "$file_bitrate" ] && [ "$file_bitrate" -le $((target_bps + target_bps / 2)) ]; then
        echo "Skipping $input_file (bitrate ${file_bitrate} bps already within 50% of target ${bitrate})"
        success_count=$((success_count + 1))
        continue
    fi

    echo "Starting compression..."

    # Write to a local temp file to avoid NFS write latency during encoding
    tmp_output=$(mktemp "/tmp/compress_mkv_XXXXXX.mkv")
    rm "$tmp_output"

    # Detect if input is HDR
    input_is_hdr=false
    if is_hdr "$input_file"; then
        input_is_hdr=true
    fi

    # Detect if input is interlaced
    input_is_interlaced=false
    if is_interlaced "$input_file"; then
        input_is_interlaced=true
        echo "Interlaced input detected, will deinterlace"
    fi

    # Set encoder and hw options based on GPU flag
    hw_init=""
    encoder="libx265"
    deinterlace="yadif"
    sdr_vf="zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"
    hdr_vf=""
    sdr_plain_vf=""
    hdr_extra=(-pix_fmt yuv420p10le -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc")

    if [ "$gpu" = "vaapi" ]; then
        hw_init="-vaapi_device /dev/dri/renderD128"
        encoder="hevc_vaapi"
        deinterlace="yadif"
        sdr_vf="zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=nv12,hwupload"
        hdr_vf="format=p010,hwupload"
        sdr_plain_vf="format=nv12,hwupload"
        hdr_extra=()
    elif [ "$gpu" = "qsv" ]; then
        hw_init="-vaapi_device /dev/dri/renderD128"
        encoder="hevc_vaapi"
        deinterlace="yadif"
        sdr_vf="zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=nv12,hwupload"
        hdr_vf="format=p010,hwupload"
        sdr_plain_vf="format=nv12,hwupload"
        hdr_extra=(-low_power 1)
    elif [ "$gpu" = "amf" ]; then
        hw_init=""
        encoder="hevc_amf"
        deinterlace="yadif"
        sdr_vf="zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"
        hdr_vf=""
        sdr_plain_vf=""
        hdr_extra=(-pix_fmt yuv420p10le)
    elif [ "$gpu" = "vulkan" ]; then
        hw_init="-init_hw_device vulkan"
        encoder="hevc_vulkan"
        deinterlace="yadif"
        sdr_vf="zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"
        hdr_vf=""
        sdr_plain_vf=""
        hdr_extra=()
    fi

    # Prepend deinterlace filter if needed
    if $input_is_interlaced; then
        sdr_vf="$deinterlace,$sdr_vf"
        if [ -n "$hdr_vf" ]; then
            hdr_vf="$deinterlace,$hdr_vf"
        else
            hdr_vf="$deinterlace"
        fi
        if [ -n "$sdr_plain_vf" ]; then
            sdr_plain_vf="$deinterlace,$sdr_plain_vf"
        else
            sdr_plain_vf="$deinterlace"
        fi
    fi

    # Determine output mode
    if $output_sdr && $input_is_hdr; then
        echo "Mode: SDR output (HDR→SDR tone mapping)"
        ffmpeg $hw_init -i "$input_file" \
            -map 0:v -map 0:a:m:language:eng -map 0:s:m:language:eng \
            -b:v "$bitrate" -maxrate "$bitrate" -bufsize "$bitrate" \
            -vf "$sdr_vf" \
            -c:v "$encoder" \
            -c:a copy -c:s copy \
            "$tmp_output"
    elif $input_is_hdr; then
        echo "Mode: HDR10 passthrough (preserving HDR metadata)"
        ffmpeg $hw_init -i "$input_file" \
            -map 0:v -map 0:a:m:language:eng -map 0:s:m:language:eng \
            -b:v "$bitrate" -maxrate "$bitrate" -bufsize "$bitrate" \
            ${hdr_vf:+-vf "$hdr_vf"} \
            -c:v "$encoder" \
            "${hdr_extra[@]}" \
            -color_primaries bt2020 \
            -color_trc smpte2084 \
            -colorspace bt2020nc \
            -c:a copy -c:s copy \
            "$tmp_output"
    else
        echo "Mode: SDR output"
        ffmpeg $hw_init -i "$input_file" -map 0:v -map 0:a:m:language:eng -map 0:s:m:language:eng -b:v "$bitrate" -maxrate "$bitrate" -bufsize "$bitrate" ${sdr_plain_vf:+-vf "$sdr_plain_vf"} -c:v "$encoder" -c:a copy -c:s copy "$tmp_output"
    fi

    # Copy compressed file to final location, preserving original creation timestamp
    original_ts=$(stat -c '%Y' "$input_file" 2>/dev/null || stat -f '%m' "$input_file")
    if [ "$overwrite" = true ]; then
        echo "Copying to final location..."
        rsync --progress "$tmp_output" "$input_file" && rm "$tmp_output"
        touch -r /dev/stdin "$input_file" <<< "" 2>/dev/null || true
        touch -d "@$original_ts" "$input_file" 2>/dev/null || touch -t "$(date -r "$original_ts" '+%Y%m%d%H%M.%S')" "$input_file"
    else
        output_file="${input_file%.mkv}_compressed.mkv"
        echo "Copying to final location..."
        rsync --progress "$tmp_output" "$output_file" && rm "$tmp_output"
        touch -d "@$original_ts" "$output_file" 2>/dev/null || touch -t "$(date -r "$original_ts" '+%Y%m%d%H%M.%S')" "$output_file"
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
